## Tests for roadmap Phase 9's first landed piece: floating combat text
## (Scripts/Indicators/DamagePopup.gd) and the hit flash (Unit._tick_hit_flash()) --
## both purely cosmetic, triggered from Unit.take_damage() whenever a hit
## actually lands.
extends GutTest

const TANK_STATS: UnitStats = preload("res://Resources/Units/TankStats.tres")

var _main: Node3D


func before_each() -> void:
	GameManager.reset_battle()
	GameManager.current_mode = ClassicEliminationMode.new()
	_main = load("res://Scenes/Main.tscn").instantiate()
	add_child_autofree(_main)
	await wait_physics_frames(2)


func _popups() -> Array:
	return GameManager.units_container.get_children().filter(func(c: Node) -> bool: return c is DamagePopup)


func test_a_landed_hit_spawns_a_damage_popup_with_the_mitigated_amount() -> void:
	var victim := GameManager.spawn_unit(TANK_STATS, GameManager.get_player(GameManager.BLUE_TEAM_ID), Vector3.ZERO)

	victim.take_damage(DamageInstance.new(20.0, null, DamageInstance.DamageType.PURE))

	var popups := _popups()
	assert_eq(popups.size(), 1)
	assert_eq(popups[0]._label.text, "20")


## Armor mitigation happens before the popup is spawned -- it should show
## the amount that actually landed, not the raw pre-mitigation instance.
func test_damage_popup_shows_the_mitigated_amount_not_the_raw_instance() -> void:
	var victim := GameManager.spawn_unit(TANK_STATS, GameManager.get_player(GameManager.BLUE_TEAM_ID), Vector3.ZERO)
	victim.stat_block.base_armor = 5.0

	victim.take_damage(DamageInstance.new(20.0, null, DamageInstance.DamageType.ATTACK))

	assert_eq(_popups()[0]._label.text, "15") # 20 - 5 armor, no attack-armor-table source to multiply


func test_an_evaded_hit_spawns_no_damage_popup() -> void:
	# A duplicate, not TANK_STATS directly -- Unit.stats is the actual
	# shared preloaded Resource (only stat_block is a per-instance copy,
	# see StatBlock.from_archetype()), so mutating it in place would leak
	# evasion = 1.0 into every other test in the suite that spawns a Tank
	# for the rest of this run.
	var evasive_stats: UnitStats = TANK_STATS.duplicate()
	evasive_stats.evasion = 1.0 # always evades
	var victim := GameManager.spawn_unit(evasive_stats, GameManager.get_player(GameManager.BLUE_TEAM_ID), Vector3.ZERO)

	var hit_landed := victim.take_damage(DamageInstance.new(20.0, null, DamageInstance.DamageType.ATTACK))

	assert_false(hit_landed)
	assert_eq(_popups().size(), 0)


func test_damage_popup_rises_and_frees_itself_after_its_lifetime() -> void:
	var victim := GameManager.spawn_unit(TANK_STATS, GameManager.get_player(GameManager.BLUE_TEAM_ID), Vector3.ZERO)
	victim.take_damage(DamageInstance.new(20.0, null, DamageInstance.DamageType.PURE))
	var popup: DamagePopup = _popups()[0]
	var start_y := popup.global_position.y

	popup._physics_process(0.2) # a direct call for an exact, incremental check -- not the freeing itself, see below
	assert_gt(popup.global_position.y, start_y, "should rise over time")
	assert_true(is_instance_valid(popup), "should still be alive well before its lifetime elapses")

	# queue_free() only marks a node for deletion at the next idle frame --
	# a direct _physics_process() call never crosses one, so this needs a
	# real wait_physics_frames() loop (same pattern test_projectiles.gd's
	# own "frees itself" tests use), not another direct call.
	for i in range(90): # comfortably past DamagePopup._LIFETIME (0.8s)
		if not is_instance_valid(popup):
			break
		await wait_physics_frames(1)
	assert_false(is_instance_valid(popup), "should free itself once its lifetime elapses")


func test_a_landed_hit_starts_a_hit_flash_that_eases_back_to_team_color() -> void:
	var victim := GameManager.spawn_unit(TANK_STATS, GameManager.get_player(GameManager.BLUE_TEAM_ID), Vector3.ZERO)
	var team_color := victim.player.color

	victim.take_damage(DamageInstance.new(20.0, null, DamageInstance.DamageType.PURE))
	victim._physics_process(0.01) # let the flash actually tint the material -- take_damage() itself only arms the timer

	assert_ne(victim._body_material.get_shader_parameter("team_color"), team_color, "should be visibly tinted right after a hit lands")

	victim._physics_process(10.0) # well past Unit._HIT_FLASH_DURATION
	assert_eq(victim._body_material.get_shader_parameter("team_color"), team_color, "should ease all the way back to team color once the flash ends")


func test_no_hit_flash_when_no_damage_has_landed() -> void:
	var victim := GameManager.spawn_unit(TANK_STATS, GameManager.get_player(GameManager.BLUE_TEAM_ID), Vector3.ZERO)
	var team_color := victim.player.color

	victim._physics_process(0.05)

	assert_eq(victim._body_material.get_shader_parameter("team_color"), team_color)
