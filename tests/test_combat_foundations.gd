## Tests for: arena bounds, knockback stacking immunity, the stalemate
## draw, the per-instance StatBlock, the DamageInstance-based damage
## pipeline (armor mitigation + kill attribution), and the death/corpse
## lifecycle.
extends GutTest

const TANK_STATS: UnitStats = preload("res://Resources/Units/TankStats.tres")
const FIGHTER_STATS: UnitStats = preload("res://Resources/Units/FighterStats.tres")
const GIANT_STATS: UnitStats = preload("res://Resources/Units/GiantStats.tres")

var _main: Node3D
var _original_stalemate_timeout: float


func before_each() -> void:
	GameManager.reset_battle()
	GameManager.current_mode = ClassicEliminationMode.new() # don't let an earlier test's mode (and its cross-shaped arena) leak into this one
	_original_stalemate_timeout = GameManager.STALEMATE_TIMEOUT
	_main = load("res://Scenes/Main.tscn").instantiate()
	add_child_autofree(_main)
	await wait_physics_frames(2)


func after_each() -> void:
	GameManager.STALEMATE_TIMEOUT = _original_stalemate_timeout


# ---------------------------------------------------------------------
# Arena bounds
# ---------------------------------------------------------------------

func test_knockback_cannot_launch_unit_outside_arena_bounds() -> void:
	var target := GameManager.spawn_unit(FIGHTER_STATS, GameManager.get_player(GameManager.RED_TEAM_ID), Vector3(19.5, 0, 0))
	# Would land at x=49.5 if unclamped -- well past ARENA_HALF_EXTENT (20.0).
	target.apply_knockback(Vector3(1, 0, 0), 30.0, 3.0)

	for i in range(45): # comfortably covers the 0.6s knockback arc
		await wait_physics_frames(1)

	assert_lte(target.global_position.x, GameManager.ARENA_HALF_EXTENT + 0.01,
		"knockback should not carry a unit past the arena's X bound")


## Two units spawned overlapping right at the edge: move_and_slide()'s
## overlap resolution (see Unit._on_safe_velocity_computed, the same
## mechanic test_crowded_units_all_make_progress_not_just_the_front_one
## relies on) will push one of them outward -- proves the clamp applies
## to ordinary physics-driven movement too, not just the knockback arc.
func test_overlap_resolution_cannot_push_unit_outside_arena_bounds() -> void:
	var corner := Vector3(19.9, 0, 19.9)
	var tank_a := GameManager.spawn_unit(TANK_STATS, GameManager.get_player(GameManager.BLUE_TEAM_ID), corner)
	var tank_b := GameManager.spawn_unit(TANK_STATS, GameManager.get_player(GameManager.RED_TEAM_ID), corner)

	for i in range(10):
		await wait_physics_frames(1)

	for tank in [tank_a, tank_b]:
		assert_lte(tank.global_position.x, GameManager.ARENA_HALF_EXTENT + 0.01)
		assert_lte(tank.global_position.z, GameManager.ARENA_HALF_EXTENT + 0.01)


# ---------------------------------------------------------------------
# Knockback stacking immunity
# ---------------------------------------------------------------------

## Regression test for PR #4's "two Giants can juggle a unit indefinitely"
## review issue: a second apply_knockback() call while already airborne
## must be ignored, not restart the arc from the mid-air position.
func test_second_knockback_while_airborne_is_ignored() -> void:
	var target := GameManager.spawn_unit(FIGHTER_STATS, GameManager.get_player(GameManager.RED_TEAM_ID), Vector3.ZERO)

	target.apply_knockback(Vector3(1, 0, 0), 5.0, 2.0)
	target.apply_knockback(Vector3(0, 0, 1), 100.0, 50.0) # must be a no-op: already airborne

	for i in range(45): # comfortably covers the 0.6s knockback arc
		await wait_physics_frames(1)

	assert_almost_eq(target.global_position.x, 5.0, 0.2,
		"the first knockback's distance should be unaffected by the ignored second call")
	assert_almost_eq(target.global_position.z, 0.0, 0.2,
		"the second knockback's direction should have had no effect at all")


# ---------------------------------------------------------------------
# Stalemate draw
# ---------------------------------------------------------------------

## Regression test for PR #4's "stalemate soft-lock" review issue: if no
## damage gets dealt for STALEMATE_TIMEOUT, the battle must resolve as a
## draw instead of hanging in BATTLE forever. Shrinks STALEMATE_TIMEOUT to
## well under the ~2s it takes these two units to close distance and land
## a first hit, so the draw fires before any real combat -- proving the
## timeout mechanism itself, without needing an actual unreachable
## composition (e.g. all-flying vs. all-ground-melee) or 20s of simulated
## physics time.
func test_no_damage_for_stalemate_timeout_ends_battle_in_a_draw() -> void:
	GameManager.STALEMATE_TIMEOUT = 0.2

	GameManager.spawn_unit(TANK_STATS, GameManager.get_player(GameManager.BLUE_TEAM_ID), Vector3(-3, 0, 0))
	GameManager.spawn_unit(FIGHTER_STATS, GameManager.get_player(GameManager.RED_TEAM_ID), Vector3(3, 0, 0))

	watch_signals(GameManager)
	GameManager.start_battle()

	var resolved := await _wait_until(func(): return GameManager.battle_state == GameManager.BattleState.GAME_OVER, 300)

	assert_true(resolved, "battle should resolve once STALEMATE_TIMEOUT elapses")
	var params: Array = get_signal_parameters(GameManager, "battle_ended")
	assert_true(params != null and params[1] == true, "a stalemate should resolve as a draw, not a win")


# ---------------------------------------------------------------------
# StatBlock
# ---------------------------------------------------------------------

func test_stat_block_starts_at_archetype_base_values() -> void:
	var block := StatBlock.from_archetype(TANK_STATS)

	assert_eq(block.max_health(), TANK_STATS.max_health)
	assert_eq(block.damage(), TANK_STATS.damage)
	assert_eq(block.move_speed(), TANK_STATS.move_speed)


func test_stat_block_modifiers_do_not_affect_the_shared_archetype() -> void:
	var original_move_speed := TANK_STATS.move_speed
	var block := StatBlock.from_archetype(TANK_STATS)
	block.add_modifier("test_buff", "move_speed", StatBlock.ModifierOp.ADD, 100.0)

	assert_gt(block.move_speed(), TANK_STATS.move_speed,
		"the StatBlock's computed value should reflect the modifier")
	assert_eq(TANK_STATS.move_speed, original_move_speed,
		"the shared archetype Resource itself must never be mutated by a buff")


func test_stat_block_applies_additive_then_multiplicative() -> void:
	var block := StatBlock.from_archetype(TANK_STATS)
	block.base_damage = 10.0
	block.add_modifier("a", "damage", StatBlock.ModifierOp.ADD, 5.0)
	block.add_modifier("b", "damage", StatBlock.ModifierOp.MULTIPLY, 2.0)

	assert_eq(block.damage(), 30.0, "(base + additive) * multiplier, gathered per stat, not applied one at a time")


func test_stat_block_remove_modifiers_from_source() -> void:
	var block := StatBlock.from_archetype(TANK_STATS)
	block.base_damage = 10.0
	block.add_modifier("item_a", "damage", StatBlock.ModifierOp.ADD, 5.0)
	block.add_modifier("item_b", "damage", StatBlock.ModifierOp.ADD, 5.0)

	block.remove_modifiers_from_source("item_a")

	assert_eq(block.damage(), 15.0, "only item_a's modifier should have been removed")


# ---------------------------------------------------------------------
# Damage pipeline
# ---------------------------------------------------------------------

func test_armor_mitigates_attack_damage() -> void:
	var defender := GameManager.spawn_unit(TANK_STATS, GameManager.get_player(GameManager.BLUE_TEAM_ID), Vector3.ZERO)
	defender.stat_block.base_armor = 5.0

	defender.take_damage(DamageInstance.new(20.0, null, DamageInstance.DamageType.ATTACK))

	assert_eq(defender.current_health, TANK_STATS.max_health - 15.0,
		"armor should reduce incoming ATTACK damage flat")


func test_armor_mitigation_floors_at_one_damage() -> void:
	var defender := GameManager.spawn_unit(TANK_STATS, GameManager.get_player(GameManager.BLUE_TEAM_ID), Vector3.ZERO)
	defender.stat_block.base_armor = 999.0

	defender.take_damage(DamageInstance.new(20.0, null, DamageInstance.DamageType.ATTACK))

	assert_eq(defender.current_health, TANK_STATS.max_health - 1.0,
		"armor should never fully negate a hit -- at least 1 damage should get through")


func test_pure_damage_bypasses_armor() -> void:
	var defender := GameManager.spawn_unit(TANK_STATS, GameManager.get_player(GameManager.BLUE_TEAM_ID), Vector3.ZERO)
	defender.stat_block.base_armor = 999.0

	defender.take_damage(DamageInstance.new(20.0, null, DamageInstance.DamageType.PURE))

	assert_eq(defender.current_health, TANK_STATS.max_health - 20.0,
		"PURE damage type should ignore armor entirely")


# ---------------------------------------------------------------------
# Attack-type x armor-type multiplier (AttackArmorTable)
# ---------------------------------------------------------------------

## NORMAL x MEDIUM is every archetype's default pairing -- both existing
## armor tests above (null source, so the multiplier never even runs)
## and every pre-existing archetype .tres file rely on this being exactly
## 1.0, i.e. a complete no-op, to keep every prior test's damage numbers
## unchanged now that this table exists.
func test_normal_attack_type_against_medium_armor_type_is_a_full_multiplier_noop() -> void:
	assert_eq(AttackArmorTable.multiplier(UnitStats.AttackType.NORMAL, UnitStats.ArmorType.MEDIUM), 1.0)


func test_piercing_attack_type_deals_bonus_damage_to_light_armor_type() -> void:
	assert_gt(AttackArmorTable.multiplier(UnitStats.AttackType.PIERCING, UnitStats.ArmorType.LIGHT), 1.0)


func test_piercing_attack_type_deals_reduced_damage_to_heavy_armor_type() -> void:
	assert_lt(AttackArmorTable.multiplier(UnitStats.AttackType.PIERCING, UnitStats.ArmorType.HEAVY), 1.0)


func test_siege_attack_type_deals_bonus_damage_to_fortified_armor_type() -> void:
	assert_gt(AttackArmorTable.multiplier(UnitStats.AttackType.SIEGE, UnitStats.ArmorType.FORTIFIED), 1.0)


## Integration test through the real take_damage() pipeline, not just the
## table function directly -- confirms Unit.take_damage() actually reads
## the attacker's UnitStats.attack_type against the defender's own
## UnitStats.armor_type. Uses freshly-constructed UnitStats (not a shared
## archetype .tres) so this can set attack_type/armor_type in isolation
## without touching any resource other tests/archetypes rely on.
func test_take_damage_applies_the_attack_armor_multiplier_on_top_of_flat_armor_reduction() -> void:
	var piercing_attacker_stats := UnitStats.new()
	piercing_attacker_stats.attack_type = UnitStats.AttackType.PIERCING
	var attacker := GameManager.spawn_unit(piercing_attacker_stats, GameManager.get_player(GameManager.BLUE_TEAM_ID), Vector3.ZERO)

	var light_armor_defender_stats := UnitStats.new()
	light_armor_defender_stats.armor_type = UnitStats.ArmorType.LIGHT
	var defender := GameManager.spawn_unit(light_armor_defender_stats, GameManager.get_player(GameManager.RED_TEAM_ID), Vector3.ZERO)
	defender.stat_block.base_armor = 5.0

	defender.take_damage(DamageInstance.new(20.0, attacker, DamageInstance.DamageType.ATTACK))

	var expected_multiplier := AttackArmorTable.multiplier(UnitStats.AttackType.PIERCING, UnitStats.ArmorType.LIGHT)
	var expected_damage := (20.0 - 5.0) * expected_multiplier
	assert_eq(defender.current_health, light_armor_defender_stats.max_health - expected_damage,
		"PIERCING vs LIGHT should apply its table multiplier on top of the flat armor reduction")


## SPELL damage still only sees the flat armor reduction -- WC3's own
## "the type table doesn't apply to spells" convention, and the whole
## reason take_damage() gates the multiplier on damage_type == ATTACK.
func test_spell_damage_ignores_the_attack_armor_multiplier() -> void:
	var piercing_attacker_stats := UnitStats.new()
	piercing_attacker_stats.attack_type = UnitStats.AttackType.PIERCING
	var attacker := GameManager.spawn_unit(piercing_attacker_stats, GameManager.get_player(GameManager.BLUE_TEAM_ID), Vector3.ZERO)

	var light_armor_defender_stats := UnitStats.new()
	light_armor_defender_stats.armor_type = UnitStats.ArmorType.LIGHT
	var defender := GameManager.spawn_unit(light_armor_defender_stats, GameManager.get_player(GameManager.RED_TEAM_ID), Vector3.ZERO)
	defender.stat_block.base_armor = 5.0

	defender.take_damage(DamageInstance.new(20.0, attacker, DamageInstance.DamageType.SPELL))

	assert_eq(defender.current_health, light_armor_defender_stats.max_health - 15.0,
		"SPELL damage should only see the flat armor reduction, no attack/armor-type multiplier")


## Kill attribution falls out of the damage pipeline: the killing blow's
## DamageInstance.source is threaded through take_damage() -> die() ->
## the died signal, so anything downstream (bounty, XP, kill feed) can
## read who got the kill without another plumbing pass.
func test_killing_blow_attributes_the_killer_via_died_signal() -> void:
	var attacker := GameManager.spawn_unit(GIANT_STATS, GameManager.get_player(GameManager.BLUE_TEAM_ID), Vector3.ZERO)
	var victim := GameManager.spawn_unit(FIGHTER_STATS, GameManager.get_player(GameManager.RED_TEAM_ID), Vector3(5, 0, 0))

	watch_signals(victim)
	victim.take_damage(DamageInstance.new(victim.stat_block.max_health() + 100.0, attacker))

	var params: Array = get_signal_parameters(victim, "died")
	assert_true(params != null and params[1] == attacker,
		"died signal should report the DamageInstance.source as the killer")


# ---------------------------------------------------------------------
# Death lifecycle
# ---------------------------------------------------------------------

func test_lethal_damage_enters_dead_state_without_freeing_immediately() -> void:
	var victim := GameManager.spawn_unit(TANK_STATS, GameManager.get_player(GameManager.BLUE_TEAM_ID), Vector3.ZERO)

	victim.take_damage(DamageInstance.new(victim.stat_block.max_health() + 100.0))

	assert_eq(victim.life_state, Unit.LifeState.DEAD)
	assert_true(victim._collision_shape.disabled, "a corpse should no longer block movement or get targeted")
	assert_false(victim.is_queued_for_deletion(), "a corpse should linger, not free immediately on death")
	assert_true(is_instance_valid(victim))


func test_corpse_frees_itself_after_decay_duration() -> void:
	var victim := GameManager.spawn_unit(TANK_STATS, GameManager.get_player(GameManager.BLUE_TEAM_ID), Vector3.ZERO)
	victim.take_damage(DamageInstance.new(victim.stat_block.max_health() + 100.0))

	for i in range(200): # comfortably covers Unit._CORPSE_DECAY_DURATION (3s @ 60fps)
		await wait_physics_frames(1)

	assert_false(is_instance_valid(victim), "a corpse should free itself once its decay duration elapses")


func _channel_sum(color: Color) -> float:
	return color.r + color.g + color.b


## Asserts on direction/shape (darker, then fully black), not a precise
## fraction at a precise frame count -- a wait_physics_frames() loop's
## simulated-time-per-call isn't reliably 1/60s for larger N (confirmed
## elsewhere this project; pinning "exactly halfway at exactly 90 frames"
## is exactly the brittleness that's bitten tests here before).
func test_corpse_darkens_toward_black_as_it_decays() -> void:
	var victim := GameManager.spawn_unit(TANK_STATS, GameManager.get_player(GameManager.BLUE_TEAM_ID), Vector3.ZERO)
	var brightness_at_spawn := _channel_sum(victim._body_material.albedo_color)

	victim.take_damage(DamageInstance.new(victim.stat_block.max_health() + 100.0))
	assert_eq(_channel_sum(victim._body_material.albedo_color), brightness_at_spawn, "should still be full team color the instant it dies")

	for i in range(10): # short waits, well clear of the 3s decay actually finishing (and freeing the corpse out from under this test)
		await wait_physics_frames(1)
	var first_check := _channel_sum(victim._body_material.albedo_color)
	assert_lt(first_check, brightness_at_spawn, "should already be darker than spawn shortly after dying")
	assert_gt(first_check, 0.0, "should not already be fully black this early into decay")

	for i in range(10):
		await wait_physics_frames(1)
	assert_lt(_channel_sum(victim._body_material.albedo_color), first_check, "should keep getting darker as decay progresses")


func test_dead_unit_ignores_further_damage() -> void:
	var victim := GameManager.spawn_unit(TANK_STATS, GameManager.get_player(GameManager.BLUE_TEAM_ID), Vector3.ZERO)
	watch_signals(victim)

	victim.take_damage(DamageInstance.new(victim.stat_block.max_health() + 100.0))
	victim.take_damage(DamageInstance.new(50.0))

	assert_eq(get_signal_emit_count(victim, "died"), 1,
		"a second lethal hit on a corpse should not re-trigger death")


## The roster/win-condition check (GameManager._on_unit_died) must fire
## the instant a unit dies, not after its corpse finishes decaying --
## otherwise a battle would hang in BATTLE for _CORPSE_DECAY_DURATION
## after the last enemy unit is defeated.
func test_win_condition_resolves_immediately_on_death_not_after_decay() -> void:
	GameManager.spawn_unit(TANK_STATS, GameManager.get_player(GameManager.BLUE_TEAM_ID), Vector3(-3, 0, 0))
	var victim := GameManager.spawn_unit(FIGHTER_STATS, GameManager.get_player(GameManager.RED_TEAM_ID), Vector3(3, 0, 0))
	GameManager.start_battle()

	victim.take_damage(DamageInstance.new(victim.stat_block.max_health() + 100.0))

	assert_eq(GameManager.battle_state, GameManager.BattleState.GAME_OVER,
		"the battle should resolve in the same frame as the killing blow, not wait for the corpse to decay")


func test_reset_battle_frees_lingering_corpses() -> void:
	var victim := GameManager.spawn_unit(TANK_STATS, GameManager.get_player(GameManager.BLUE_TEAM_ID), Vector3.ZERO)
	victim.take_damage(DamageInstance.new(victim.stat_block.max_health() + 100.0))
	assert_true(is_instance_valid(victim), "sanity check: corpse should still be mid-decay")

	GameManager.reset_battle()

	assert_true(victim.is_queued_for_deletion(),
		"reset_battle should free a still-decaying corpse, not just units still in the roster")


## Polls `condition` once per physics frame (not a wall-clock timer, which
## doesn't map to simulated physics time under GUT). Returns true as soon
## as it's met, false if `timeout_physics_frames` elapses first.
func _wait_until(condition: Callable, timeout_physics_frames: int) -> bool:
	var frames := 0
	while not condition.call():
		if frames >= timeout_physics_frames:
			return false
		await wait_physics_frames(1)
		frames += 1
	return true
