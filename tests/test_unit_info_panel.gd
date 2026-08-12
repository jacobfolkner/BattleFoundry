## Tests for UI/HUD.gd's bottom-left unit info panel (portrait/name/
## health/armor/status) -- gameplay feedback, 2026-08-11: "when selecting
## a unit you should be able to see a ui on the bottom.. notice the
## health and stats." Not exhaustive per-field coverage (this codebase's
## other HUD selection widgets -- the ability hotbar, unit action bar --
## have no direct visual tests either, relying on the full suite staying
## green plus manual screenshot verification); covers the shape of the
## behavior: hidden with nothing tracked, populated once a unit is
## tracked, hidden again once cleared.
extends GutTest

const TANK_STATS: UnitStats = preload("res://Resources/Units/TankStats.tres")

var _main: Node3D
var _hud: Control


func before_each() -> void:
	GameManager.reset_battle()
	GameManager.current_mode = ClassicEliminationMode.new()
	_main = load("res://Scenes/Main.tscn").instantiate()
	add_child_autofree(_main)
	await wait_physics_frames(2)
	_hud = _main._hud


func test_panel_is_hidden_with_nothing_tracked() -> void:
	_hud.track_unit(null)
	await wait_physics_frames(1)

	assert_false(_hud._unit_info_card.visible)


func test_tracking_a_unit_shows_its_name_health_and_armor() -> void:
	var unit := GameManager.spawn_unit(TANK_STATS, GameManager.get_player(GameManager.BLUE_TEAM_ID), Vector3(3, 0, 3))

	_hud.track_unit(unit)
	await wait_physics_frames(1)

	assert_true(_hud._unit_info_card.visible)
	assert_eq(_hud._unit_info_name_label.text, TANK_STATS.unit_name)
	assert_eq(_hud._unit_info_health_label.text, "%d / %d" % [int(unit.stat_block.max_health()), int(unit.stat_block.max_health())])
	assert_almost_eq(_hud._unit_info_health_bar.value, unit.stat_block.max_health(), 0.01)


func test_a_damaged_units_health_bar_and_label_reflect_the_loss() -> void:
	var unit := GameManager.spawn_unit(TANK_STATS, GameManager.get_player(GameManager.BLUE_TEAM_ID), Vector3(3, 0, 3))
	unit.take_damage(DamageInstance.new(20.0, null, DamageInstance.DamageType.PURE))

	_hud.track_unit(unit)
	await wait_physics_frames(1)

	assert_almost_eq(_hud._unit_info_health_bar.value, unit.current_health, 0.01)
	assert_eq(_hud._unit_info_health_label.text, "%d / %d" % [int(ceilf(unit.current_health)), int(unit.stat_block.max_health())])


func test_clearing_the_tracked_unit_hides_the_panel_again() -> void:
	var unit := GameManager.spawn_unit(TANK_STATS, GameManager.get_player(GameManager.BLUE_TEAM_ID), Vector3(3, 0, 3))
	_hud.track_unit(unit)
	await wait_physics_frames(1)
	assert_true(_hud._unit_info_card.visible, "sanity check -- should be visible before clearing")

	_hud.track_unit(null)
	await wait_physics_frames(1)

	assert_false(_hud._unit_info_card.visible)


func test_a_stunned_units_status_line_names_the_effect() -> void:
	var unit := GameManager.spawn_unit(TANK_STATS, GameManager.get_player(GameManager.BLUE_TEAM_ID), Vector3(3, 0, 3))
	unit.apply_effect(Effect.new("test_stun", 5.0).with_cc(Effect.CCFlag.STUN))

	_hud.track_unit(unit)
	await wait_physics_frames(1)

	assert_eq(_hud._unit_info_status_label.text, "Status: Stunned")


func test_an_unaffected_units_status_line_reads_as_a_dash() -> void:
	var unit := GameManager.spawn_unit(TANK_STATS, GameManager.get_player(GameManager.BLUE_TEAM_ID), Vector3(3, 0, 3))

	_hud.track_unit(unit)
	await wait_physics_frames(1)

	assert_eq(_hud._unit_info_status_label.text, "Status: -")
