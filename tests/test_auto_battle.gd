## Tests for auto-battle mode behavior (roadmap §2's last item): Blood
## Tournament units fight entirely on their own during BATTLE -- an
## auto-move order toward the arena center on spawn (GameManager.spawn_unit()),
## auto-cast abilities (Unit._maybe_auto_cast_abilities()) -- and manual
## player commands (right-click orders, S/H, Q/W/E) become no-ops, while
## selection itself (for inspection) stays untouched. Classic mode is
## unaffected throughout (GameMode.is_auto_battle() defaults false).
extends GutTest

const TANK_STATS: UnitStats = preload("res://Resources/Units/TankStats.tres")
const FIGHTER_STATS: UnitStats = preload("res://Resources/Units/FighterStats.tres")

var _main: Node3D


func before_each() -> void:
	GameManager.reset_battle()
	GameManager.current_mode = ClassicEliminationMode.new() # don't let an earlier test's mode leak in
	var blue := GameManager.get_player(GameManager.BLUE_TEAM_ID)
	var red := GameManager.get_player(GameManager.RED_TEAM_ID)
	blue.resources = 0
	red.resources = 0
	blue.blood_points = 0
	red.blood_points = 0
	blue.roster.clear()
	red.roster.clear()
	blue.roster_upgrades.clear()
	red.roster_upgrades.clear()
	blue.archetype_upgrades.clear()
	red.archetype_upgrades.clear()
	_main = load("res://Scenes/Main.tscn").instantiate()
	add_child_autofree(_main)
	await wait_physics_frames(2)


func test_units_spawned_during_auto_battle_get_an_attack_move_order_toward_center() -> void:
	GameManager.set_mode(BloodTournamentMode.new())
	var blue := GameManager.get_player(GameManager.BLUE_TEAM_ID)
	var red := GameManager.get_player(GameManager.RED_TEAM_ID)
	blue.roster = [TANK_STATS]
	red.roster = [TANK_STATS]
	GameManager.start_battle()

	var unit := GameManager.spawn_unit(TANK_STATS, blue, Vector3(5, 0, 5))

	assert_not_null(unit.current_order)
	assert_eq(unit.current_order.type, Unit.OrderType.ATTACK_MOVE)
	assert_eq(unit.current_order.target_position, Vector3.ZERO)


func test_classic_mode_units_get_no_auto_order() -> void:
	var blue := GameManager.get_player(GameManager.BLUE_TEAM_ID)
	var red := GameManager.get_player(GameManager.RED_TEAM_ID)
	GameManager.spawn_unit(TANK_STATS, blue, Vector3(-3, 0, 0))
	GameManager.spawn_unit(FIGHTER_STATS, red, Vector3(3, 0, 0))
	GameManager.start_battle()

	var unit := GameManager.spawn_unit(TANK_STATS, blue, Vector3(5, 0, 5))

	assert_null(unit.current_order, "classic mode is manual RTS control -- no auto-move order")


func test_auto_battle_blocks_manual_right_click_orders() -> void:
	GameManager.set_mode(BloodTournamentMode.new())
	var blue := GameManager.get_player(GameManager.BLUE_TEAM_ID)
	var red := GameManager.get_player(GameManager.RED_TEAM_ID)
	blue.roster = [TANK_STATS]
	red.roster = [TANK_STATS]
	GameManager.start_battle()
	var unit := GameManager.spawn_unit(TANK_STATS, blue, Vector3(-3, 0, 0))
	SelectionManager.select_single(unit, false)
	unit.current_order = null # isolate the manual-order attempt from the auto-move order already issued at spawn

	var event := InputEventMouseButton.new()
	event.button_index = MOUSE_BUTTON_RIGHT
	event.pressed = true
	event.position = Vector2.ZERO
	_main._on_right_click(event)

	assert_null(unit.current_order, "right-click orders should be a no-op during auto-battle")


func test_auto_battle_blocks_manual_stop_and_hold_hotkeys() -> void:
	GameManager.set_mode(BloodTournamentMode.new())
	var blue := GameManager.get_player(GameManager.BLUE_TEAM_ID)
	var red := GameManager.get_player(GameManager.RED_TEAM_ID)
	blue.roster = [TANK_STATS]
	red.roster = [TANK_STATS]
	GameManager.start_battle()
	var unit := GameManager.spawn_unit(TANK_STATS, blue, Vector3(-3, 0, 0))
	SelectionManager.select_single(unit, false)
	unit.current_order = null

	var key_event := InputEventKey.new()
	key_event.keycode = KEY_X
	key_event.pressed = true
	_main._handle_key(key_event)

	assert_null(unit.current_order, "X (Stop) should be a no-op during auto-battle")


func test_auto_battle_blocks_manual_ability_casts() -> void:
	GameManager.set_mode(BloodTournamentMode.new())
	var blue := GameManager.get_player(GameManager.BLUE_TEAM_ID)
	var red := GameManager.get_player(GameManager.RED_TEAM_ID)
	blue.roster = [TANK_STATS] # abilities[0] == War Stomp
	red.roster = [TANK_STATS]
	GameManager.start_battle()
	var unit := GameManager.spawn_unit(TANK_STATS, blue, Vector3(-3, 0, 0))
	SelectionManager.select_single(unit, false)

	_main._try_cast_or_target(0)

	assert_eq(unit.get_ability_cooldown_remaining(0), 0.0, "Q should be a no-op during auto-battle -- no cast should have happened")


func test_auto_battle_still_allows_selection_for_inspection() -> void:
	GameManager.set_mode(BloodTournamentMode.new())
	var blue := GameManager.get_player(GameManager.BLUE_TEAM_ID)
	var red := GameManager.get_player(GameManager.RED_TEAM_ID)
	blue.roster = [TANK_STATS]
	red.roster = [TANK_STATS]
	GameManager.start_battle()
	var unit := GameManager.spawn_unit(TANK_STATS, blue, Vector3(-3, 0, 0))

	SelectionManager.select_single(unit, false)

	assert_eq(SelectionManager.selected_units, [unit], "inspecting via selection must still work during auto-battle, only commanding is blocked")


func test_auto_cast_fires_an_available_ability_without_any_player_input() -> void:
	GameManager.set_mode(BloodTournamentMode.new())
	var blue := GameManager.get_player(GameManager.BLUE_TEAM_ID)
	var red := GameManager.get_player(GameManager.RED_TEAM_ID)
	blue.roster = [TANK_STATS] # abilities[0] == War Stomp, a NO_TARGET AoE stun
	red.roster = [TANK_STATS]
	GameManager.start_battle()
	var tank := GameManager.spawn_unit(TANK_STATS, blue, Vector3(0, 0, 0))
	GameManager.spawn_unit(FIGHTER_STATS, red, Vector3(5, 0, 0)) # within acquisition_range so target_enemy gets set
	tank.current_order = null # isolate autonomous targeting/auto-cast from the auto-move order issued at spawn

	await wait_physics_frames(3)

	assert_gt(tank.get_ability_cooldown_remaining(0), 0.0, "War Stomp should have auto-cast on its own once an enemy was acquired")
