## Tests for Scripts/Effect.gd (timed/permanent CC and stat-modifier
## effects) and Scripts/Ability.gd (data-driven abilities cast via
## Unit.cast_ability()) -- the roadmap's "Ability & Effect system,"
## v1 scope: three concrete abilities (War Stomp on Tank, Frost Bolt on
## Archer, Toughness on Fighter) plus Giant's knockback ported in as a
## fourth (ON_HIT) ability. See test_flying_and_knockback.gd's existing
## knockback test for proof that port didn't change its behavior.
extends GutTest

const TANK_STATS: UnitStats = preload("res://Resources/TankStats.tres")
const FIGHTER_STATS: UnitStats = preload("res://Resources/FighterStats.tres")
const ARCHER_STATS: UnitStats = preload("res://Resources/ArcherStats.tres")

var _main: Node3D


func before_each() -> void:
	GameManager.reset_battle()
	_main = load("res://Scenes/Main.tscn").instantiate()
	add_child_autofree(_main)
	await wait_physics_frames(2)


# ---------------------------------------------------------------------
# Effect: CC flags
# ---------------------------------------------------------------------

func test_stun_disables_movement_and_attacking() -> void:
	var tank := GameManager.spawn_unit(TANK_STATS, GameManager.get_player(GameManager.BLUE_TEAM_ID), Vector3.ZERO)
	var fighter := GameManager.spawn_unit(FIGHTER_STATS, GameManager.get_player(GameManager.RED_TEAM_ID), Vector3(1, 0, 0))
	GameManager.start_battle()

	tank.apply_effect(Effect.new("test_stun", 5.0).with_cc(Effect.CCFlag.STUN))

	for i in range(90): # comfortably covers Tank's 1.2s attack_interval
		await wait_physics_frames(1)

	assert_eq(fighter.current_health, FIGHTER_STATS.max_health, "a stunned unit should never attack")
	assert_true(tank.is_stunned())


func test_root_blocks_movement_but_not_attacking() -> void:
	var tank := GameManager.spawn_unit(TANK_STATS, GameManager.get_player(GameManager.BLUE_TEAM_ID), Vector3.ZERO)
	var fighter := GameManager.spawn_unit(FIGHTER_STATS, GameManager.get_player(GameManager.RED_TEAM_ID), Vector3(1, 0, 0)) # already in range
	GameManager.start_battle()

	tank.apply_effect(Effect.new("test_root", 5.0).with_cc(Effect.CCFlag.ROOT))

	for i in range(90):
		await wait_physics_frames(1)

	assert_true(tank.is_rooted())
	assert_lt(fighter.current_health, FIGHTER_STATS.max_health, "a rooted unit should still attack something already in range")


func test_invulnerable_blocks_all_damage() -> void:
	var tank := GameManager.spawn_unit(TANK_STATS, GameManager.get_player(GameManager.BLUE_TEAM_ID), Vector3.ZERO)
	tank.apply_effect(Effect.new("test_invuln", 5.0).with_cc(Effect.CCFlag.INVULNERABLE))

	tank.take_damage(DamageInstance.new(1000.0, null, DamageInstance.DamageType.PURE))

	assert_eq(tank.current_health, TANK_STATS.max_health, "INVULNERABLE should block every damage type, including PURE")


func test_ethereal_blocks_attack_damage_but_not_spell_or_pure() -> void:
	var tank := GameManager.spawn_unit(TANK_STATS, GameManager.get_player(GameManager.BLUE_TEAM_ID), Vector3.ZERO)
	tank.apply_effect(Effect.new("test_ethereal", 5.0).with_cc(Effect.CCFlag.ETHEREAL))

	tank.take_damage(DamageInstance.new(20.0, null, DamageInstance.DamageType.ATTACK))
	assert_eq(tank.current_health, TANK_STATS.max_health, "ETHEREAL should block ATTACK damage")

	tank.take_damage(DamageInstance.new(20.0, null, DamageInstance.DamageType.SPELL))
	assert_eq(tank.current_health, TANK_STATS.max_health - 20.0, "ETHEREAL should not block SPELL damage")


func test_effect_expires_after_its_duration() -> void:
	var tank := GameManager.spawn_unit(TANK_STATS, GameManager.get_player(GameManager.BLUE_TEAM_ID), Vector3.ZERO)
	tank.apply_effect(Effect.new("test_stun", 0.1).with_cc(Effect.CCFlag.STUN))
	assert_true(tank.is_stunned())

	for i in range(30): # 0.5s, comfortably past the 0.1s duration
		await wait_physics_frames(1)

	assert_false(tank.is_stunned(), "a timed effect should clear itself once its duration elapses")


func test_permanent_effect_never_expires_on_its_own() -> void:
	var tank := GameManager.spawn_unit(TANK_STATS, GameManager.get_player(GameManager.BLUE_TEAM_ID), Vector3.ZERO)
	tank.apply_effect(Effect.new("test_permanent_root", 0.0).with_cc(Effect.CCFlag.ROOT)) # duration 0 == permanent

	for i in range(60):
		await wait_physics_frames(1)

	assert_true(tank.is_rooted(), "a duration-0 effect should be permanent, not expire")


func test_death_clears_all_active_effects() -> void:
	var tank := GameManager.spawn_unit(TANK_STATS, GameManager.get_player(GameManager.BLUE_TEAM_ID), Vector3.ZERO)
	tank.apply_effect(Effect.new("test_root", 0.0).with_cc(Effect.CCFlag.ROOT))
	assert_true(tank.is_rooted())

	tank.take_damage(DamageInstance.new(tank.stat_block.max_health() + 100.0))

	assert_false(tank.is_rooted(), "dying should clear every active effect")


# ---------------------------------------------------------------------
# Effect: stat modifiers + stacking rules
# ---------------------------------------------------------------------

func test_effect_with_stat_modifier_changes_stat_block_and_reverts_on_removal() -> void:
	var tank := GameManager.spawn_unit(TANK_STATS, GameManager.get_player(GameManager.BLUE_TEAM_ID), Vector3.ZERO)
	var original_speed := tank.stat_block.move_speed()

	var slow := Effect.new("test_slow", 5.0)
	slow.with_stat_modifier("move_speed", StatBlock.ModifierOp.MULTIPLY, 0.5)
	tank.apply_effect(slow)
	assert_almost_eq(tank.stat_block.move_speed(), original_speed * 0.5, 0.01)

	tank.remove_effects_from_source(slow.source)
	assert_almost_eq(tank.stat_block.move_speed(), original_speed, 0.01,
		"removing the effect should revert its StatBlock modifier too")


## Checks Effect.elapsed directly (via Unit.get_effect()) rather than
## inferring the timer state from a physics-frame count -- GUT's
## wait_physics_frames() budget doesn't map reliably 1:1 to simulated
## seconds (confirmed elsewhere this session with much larger frame
## counts; this test's original version used a margin small enough for
## that same slop to make it flaky even with just ~18 frames total).
func test_refresh_stacking_resets_elapsed_instead_of_adding_a_second_instance() -> void:
	var tank := GameManager.spawn_unit(TANK_STATS, GameManager.get_player(GameManager.BLUE_TEAM_ID), Vector3.ZERO)
	tank.apply_effect(Effect.new("test_root", 5.0).with_cc(Effect.CCFlag.ROOT).with_stack_rule(Effect.StackRule.REFRESH))

	for i in range(5):
		await wait_physics_frames(1)
	assert_gt(tank.get_effect("test_root").elapsed, 0.0, "sanity check: elapsed should have advanced from the initial wait")

	tank.apply_effect(Effect.new("test_root", 5.0).with_cc(Effect.CCFlag.ROOT).with_stack_rule(Effect.StackRule.REFRESH))

	assert_eq(tank.get_effect("test_root").elapsed, 0.0, "REFRESH should reset elapsed back to 0, not add a second instance")
	assert_true(tank.is_rooted())


func test_strongest_wins_keeps_the_larger_magnitude() -> void:
	var tank := GameManager.spawn_unit(TANK_STATS, GameManager.get_player(GameManager.BLUE_TEAM_ID), Vector3.ZERO)
	var original_speed := tank.stat_block.move_speed()

	var weak_slow := Effect.new("test_slow", 5.0).with_stat_modifier("move_speed", StatBlock.ModifierOp.MULTIPLY, 0.8).with_stack_rule(Effect.StackRule.STRONGEST_WINS, 0.2)
	var strong_slow := Effect.new("test_slow", 5.0).with_stat_modifier("move_speed", StatBlock.ModifierOp.MULTIPLY, 0.5).with_stack_rule(Effect.StackRule.STRONGEST_WINS, 0.5)

	tank.apply_effect(weak_slow)
	tank.apply_effect(strong_slow) # stronger -- should replace
	assert_almost_eq(tank.stat_block.move_speed(), original_speed * 0.5, 0.01)

	tank.apply_effect(weak_slow) # weaker than what's active -- should be dropped
	assert_almost_eq(tank.stat_block.move_speed(), original_speed * 0.5, 0.01,
		"a weaker STRONGEST_WINS reapplication should not replace the stronger active one")


func test_stack_rule_allows_multiple_simultaneous_instances() -> void:
	var tank := GameManager.spawn_unit(TANK_STATS, GameManager.get_player(GameManager.BLUE_TEAM_ID), Vector3.ZERO)
	var original_damage := tank.stat_block.damage()

	tank.apply_effect(Effect.new("test_stack_buff", 5.0, "a").with_stat_modifier("damage", StatBlock.ModifierOp.ADD, 5.0).with_stack_rule(Effect.StackRule.STACK))
	tank.apply_effect(Effect.new("test_stack_buff", 5.0, "b").with_stat_modifier("damage", StatBlock.ModifierOp.ADD, 5.0).with_stack_rule(Effect.StackRule.STACK))

	assert_almost_eq(tank.stat_block.damage(), original_damage + 10.0, 0.01,
		"STACK should let both instances' modifiers apply simultaneously")


func test_stun_immunity_blocks_a_new_stun_right_after_one_expires() -> void:
	var tank := GameManager.spawn_unit(TANK_STATS, GameManager.get_player(GameManager.BLUE_TEAM_ID), Vector3.ZERO)
	tank.apply_effect(Effect.new("stun_a", 0.1).with_cc(Effect.CCFlag.STUN))

	for i in range(15): # ~0.25s -- past the first stun's expiry
		await wait_physics_frames(1)
	assert_false(tank.is_stunned(), "sanity check: the first stun should have expired by now")

	tank.apply_effect(Effect.new("stun_b", 5.0).with_cc(Effect.CCFlag.STUN))
	assert_false(tank.is_stunned(),
		"a new stun landing right after one just expired should be blocked by the immunity window")


# ---------------------------------------------------------------------
# Ability casting
# ---------------------------------------------------------------------

func test_passive_ability_applies_automatically_at_spawn() -> void:
	var fighter := GameManager.spawn_unit(FIGHTER_STATS, GameManager.get_player(GameManager.BLUE_TEAM_ID), Vector3.ZERO)
	assert_almost_eq(fighter.stat_block.armor(), FIGHTER_STATS.armor + 5.0, 0.01,
		"Fighter's Toughness passive should apply the instant it spawns, with no cast needed")


func test_no_target_ability_hits_nearby_enemies_and_goes_on_cooldown() -> void:
	var tank := GameManager.spawn_unit(TANK_STATS, GameManager.get_player(GameManager.BLUE_TEAM_ID), Vector3.ZERO)
	var nearby := GameManager.spawn_unit(FIGHTER_STATS, GameManager.get_player(GameManager.RED_TEAM_ID), Vector3(2, 0, 0)) # within War Stomp's 4m radius
	var far := GameManager.spawn_unit(FIGHTER_STATS, GameManager.get_player(GameManager.RED_TEAM_ID), Vector3(10, 0, 0)) # outside it

	var cast := tank.cast_ability(0) # War Stomp

	assert_true(cast)
	assert_true(nearby.is_stunned(), "War Stomp should stun enemies within its AoE radius")
	assert_false(far.is_stunned(), "War Stomp should not affect enemies outside its AoE radius")
	assert_false(tank.cast_ability(0), "casting again immediately should fail -- War Stomp just went on cooldown")


func test_unit_target_ability_requires_range_and_deals_damage_plus_slow() -> void:
	var archer := GameManager.spawn_unit(ARCHER_STATS, GameManager.get_player(GameManager.BLUE_TEAM_ID), Vector3.ZERO)
	var close_target := GameManager.spawn_unit(TANK_STATS, GameManager.get_player(GameManager.RED_TEAM_ID), Vector3(4, 0, 0)) # within Frost Bolt's 6m range
	var far_target := GameManager.spawn_unit(TANK_STATS, GameManager.get_player(GameManager.RED_TEAM_ID), Vector3(20, 0, 0))

	assert_false(archer.cast_ability(0, far_target), "Frost Bolt should fail against a target out of range")

	var original_speed := close_target.stat_block.move_speed()
	var cast := archer.cast_ability(0, close_target) # Frost Bolt

	assert_true(cast)
	assert_lt(close_target.current_health, TANK_STATS.max_health, "Frost Bolt should deal its SPELL damage")
	assert_almost_eq(close_target.stat_block.move_speed(), original_speed * 0.5, 0.01, "Frost Bolt should slow its target")


func test_stunned_unit_cannot_cast_abilities() -> void:
	var tank := GameManager.spawn_unit(TANK_STATS, GameManager.get_player(GameManager.BLUE_TEAM_ID), Vector3.ZERO)
	GameManager.spawn_unit(FIGHTER_STATS, GameManager.get_player(GameManager.RED_TEAM_ID), Vector3(2, 0, 0))
	tank.apply_effect(Effect.new("test_stun", 5.0).with_cc(Effect.CCFlag.STUN))

	assert_false(tank.cast_ability(0), "a stunned unit should not be able to cast War Stomp")


func test_ability_cooldown_ticks_down_and_allows_recast() -> void:
	var tank := GameManager.spawn_unit(TANK_STATS, GameManager.get_player(GameManager.BLUE_TEAM_ID), Vector3.ZERO)
	GameManager.start_battle() # abilities tick down in _physics_process, which only runs meaningfully once ticking is happening either way

	assert_true(tank.cast_ability(0))
	assert_false(tank.cast_ability(0), "War Stomp's 8s cooldown should still be active")

	for i in range(600): # 10s -- comfortably past War Stomp's 8s cooldown
		await wait_physics_frames(1)

	assert_true(tank.cast_ability(0), "the cooldown should have fully ticked down by now")


# ---------------------------------------------------------------------
# Knockback ported to the ON_HIT ability framework (Giant Slam)
# ---------------------------------------------------------------------

# ---------------------------------------------------------------------
# Ability: AURA (continuous, see Unit._tick_aura()/Ability.apply_aura())
# ---------------------------------------------------------------------

## A throwaway UnitStats (not one of the shared preloaded archetypes --
## mutating TankStats.tres's own aura_ability field in a test would leak
## into every other test that preloads it) with `aura` wired up as its
## aura_ability.
func _aura_caster_stats(aura: Ability) -> UnitStats:
	var stats := UnitStats.new()
	stats.unit_name = "AuraTestCaster"
	stats.max_health = 100.0
	stats.damage = 5.0
	stats.attack_range = 1.0
	stats.attack_interval = 1.0
	stats.move_speed = 3.0
	stats.collision_radius = 0.5
	stats.aura_ability = aura
	return stats


func _build_test_aura(radius: float, duration: float = 1.0) -> Ability:
	var aura := Ability.new()
	aura.ability_name = "test_aura"
	aura.cast_type = Ability.CastType.AURA
	aura.aoe_radius = radius
	aura.effect_duration = duration
	aura.effect_stat = "armor"
	aura.effect_stat_op = StatBlock.ModifierOp.ADD
	aura.effect_stat_value = 4.0
	return aura


## Deliberately doesn't call GameManager.start_battle() -- _tick_effects()/
## _tick_ability_cooldowns()/_tick_aura() all run every physics frame
## regardless of battle_state (only gated by life_state != DEAD), same as
## test_ability_cooldown_ticks_down_and_allows_recast() above already
## relies on. Staying in PLACEMENT means _process_order()/_update_target()
## never run, so units simply never move -- sidesteps the whole "no
## acquisition-range cap" rough edge (units wandering toward the nearest
## enemy) that a multi-second battle-active test would otherwise risk.
func test_aura_buffs_the_caster_and_allies_within_radius_but_not_beyond_it() -> void:
	var aura := _build_test_aura(5.0)
	var blue := GameManager.get_player(GameManager.BLUE_TEAM_ID)
	var caster := GameManager.spawn_unit(_aura_caster_stats(aura), blue, Vector3.ZERO)
	var nearby_ally := GameManager.spawn_unit(TANK_STATS, blue, Vector3(2, 0, 0))
	var far_ally := GameManager.spawn_unit(TANK_STATS, blue, Vector3(20, 0, 0))

	for i in range(20): # comfortably past Unit._AURA_TICK_INTERVAL (0.25s)
		await wait_physics_frames(1)

	assert_almost_eq(caster.stat_block.armor(), 4.0, 0.01, "an aura should buff its own caster too, same as WC3's own aura convention")
	assert_almost_eq(nearby_ally.stat_block.armor(), TANK_STATS.armor + 4.0, 0.01, "an ally within aoe_radius should be buffed")
	assert_almost_eq(far_ally.stat_block.armor(), TANK_STATS.armor, 0.01, "an ally outside aoe_radius should not be buffed")


func test_aura_does_not_affect_hostile_units() -> void:
	var aura := _build_test_aura(10.0)
	var blue := GameManager.get_player(GameManager.BLUE_TEAM_ID)
	var caster := GameManager.spawn_unit(_aura_caster_stats(aura), blue, Vector3.ZERO)
	var enemy := GameManager.spawn_unit(FIGHTER_STATS, GameManager.get_player(GameManager.RED_TEAM_ID), Vector3(2, 0, 0))
	var enemy_baseline_armor := enemy.stat_block.armor() # Fighter's own Toughness passive already applies +5 at spawn -- capture the real baseline rather than assuming FIGHTER_STATS.armor alone

	for i in range(20):
		await wait_physics_frames(1)

	assert_almost_eq(caster.stat_block.armor(), 4.0, 0.01)
	assert_almost_eq(enemy.stat_block.armor(), enemy_baseline_armor, 0.01, "a hostile unit must never be buffed by an aura")


## effect_duration (1.0s) is deliberately shorter than the test's own
## observation window -- REFRESH stacking (Effect's default stack_rule)
## re-ticking every _AURA_TICK_INTERVAL (0.25s) should keep resetting
## elapsed back to 0 for as long as the ally stays in range, so the buff
## must never actually expire on its own.
func test_aura_effect_keeps_refreshing_so_it_never_expires_while_in_range() -> void:
	var aura := _build_test_aura(5.0, 1.0)
	var blue := GameManager.get_player(GameManager.BLUE_TEAM_ID)
	GameManager.spawn_unit(_aura_caster_stats(aura), blue, Vector3.ZERO)
	var ally := GameManager.spawn_unit(TANK_STATS, blue, Vector3(2, 0, 0))

	for i in range(200): # ~3.3s simulated, well past the 1.0s effect_duration
		await wait_physics_frames(1)

	assert_almost_eq(ally.stat_block.armor(), TANK_STATS.armor + 4.0, 0.01,
		"the aura buff should never expire while the ally stays in range")


# ---------------------------------------------------------------------
# In-world status indicator (see UnitStatusMarker.gd/Unit._refresh_status_indicator())
# ---------------------------------------------------------------------

func test_status_indicator_hidden_with_no_active_effects() -> void:
	var tank := GameManager.spawn_unit(TANK_STATS, GameManager.get_player(GameManager.BLUE_TEAM_ID), Vector3.ZERO)

	assert_false(tank._status_indicator._mesh_instance.visible)


func test_status_indicator_shows_stun_color() -> void:
	var tank := GameManager.spawn_unit(TANK_STATS, GameManager.get_player(GameManager.BLUE_TEAM_ID), Vector3.ZERO)

	tank.apply_effect(Effect.new("test_stun", 5.0).with_cc(Effect.CCFlag.STUN))
	tank._tick_effects(0.0) # _refresh_status_indicator() only runs as part of the tick

	assert_true(tank._status_indicator._mesh_instance.visible)
	assert_eq(tank._status_indicator._material.albedo_color, Unit._CC_STATUS_COLORS[Effect.CCFlag.STUN])


func test_status_indicator_shows_buff_color_for_a_positive_stat_modifier() -> void:
	var fighter := GameManager.spawn_unit(FIGHTER_STATS, GameManager.get_player(GameManager.BLUE_TEAM_ID), Vector3.ZERO)

	fighter._tick_effects(0.0) # Fighter's Toughness passive (+armor) already applied at spawn

	assert_true(fighter._status_indicator._mesh_instance.visible)
	assert_eq(fighter._status_indicator._material.albedo_color, Unit._BUFF_STATUS_COLOR)


func test_status_indicator_shows_debuff_color_for_a_slow() -> void:
	var archer := GameManager.spawn_unit(ARCHER_STATS, GameManager.get_player(GameManager.BLUE_TEAM_ID), Vector3.ZERO)
	var target := GameManager.spawn_unit(TANK_STATS, GameManager.get_player(GameManager.RED_TEAM_ID), Vector3(4, 0, 0))

	archer.cast_ability(0, target) # Frost Bolt: move_speed MULTIPLY 0.5, a debuff despite the positive number
	target._tick_effects(0.0)

	assert_true(target._status_indicator._mesh_instance.visible)
	assert_eq(target._status_indicator._material.albedo_color, Unit._DEBUFF_STATUS_COLOR)


func test_status_indicator_hides_on_death() -> void:
	var tank := GameManager.spawn_unit(TANK_STATS, GameManager.get_player(GameManager.BLUE_TEAM_ID), Vector3.ZERO)
	tank.apply_effect(Effect.new("test_stun", 5.0).with_cc(Effect.CCFlag.STUN))
	tank._tick_effects(0.0)
	assert_true(tank._status_indicator._mesh_instance.visible, "sanity check: the indicator should be showing before death")

	tank.die()

	assert_false(tank._status_indicator._mesh_instance.visible, "a corpse should not keep showing its last status color")


func test_on_hit_ability_is_not_player_triggerable() -> void:
	var giant := GameManager.spawn_unit(preload("res://Resources/GiantStats.tres"), GameManager.get_player(GameManager.BLUE_TEAM_ID), Vector3.ZERO)
	# Giant Slam lives on stats.on_hit_ability, not stats.abilities -- slot
	# 0 should be empty, so casting it should just fail cleanly.
	assert_false(giant.cast_ability(0), "an ON_HIT ability should never be reachable via cast_ability()")
