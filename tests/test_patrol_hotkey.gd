## Tests for the P/order_patrol hotkey (Scripts/Core/PlayerInputController.gd's
## begin_patrol_targeting()/resolve_pending_patrol()/cancel_pending_patrol()),
## closing the roadmap's long-standing "no PATROL hotkey" rough edge --
## Unit.order_patrol()/SelectionManager.order_patrol() were already complete
## and tested (see tests/test_orders_and_selection.gd), just never wired to
## input. Same two-step "press a key, then click" shape as the UNIT_TARGET
## ability click-to-target flow (tests/test_ability_targeting.gd), except
## the click resolves against the ground plane (a destination point), not a
## unit -- see resolve_pending_patrol()'s own doc comment.
extends GutTest

const TANK_STATS: UnitStats = preload("res://Resources/Units/TankStats.tres")

var _main: Node3D


func before_each() -> void:
	GameManager.reset_battle()
	GameManager.current_mode = ClassicEliminationMode.new()
	_main = load("res://Scenes/Main.tscn").instantiate()
	add_child_autofree(_main)
	await wait_physics_frames(2)


func _key_event(keycode: Key) -> InputEventKey:
	var event := InputEventKey.new()
	event.keycode = keycode
	event.pressed = true
	return event


func test_pressing_p_enters_pending_patrol_mode_without_issuing_an_order_yet() -> void:
	var tank := GameManager.spawn_unit(TANK_STATS, GameManager.get_player(GameManager.BLUE_TEAM_ID), Vector3.ZERO)
	GameManager.spawn_unit(TANK_STATS, GameManager.get_player(GameManager.RED_TEAM_ID), Vector3(10, 0, 0))
	GameManager.start_battle()
	SelectionManager.select_single(tank)

	_main._handle_key(_key_event(KEY_P))

	assert_true(_main._pending_patrol)
	assert_null(tank.current_order, "entering targeting mode shouldn't issue an order yet")


func test_clicking_ground_while_pending_issues_a_patrol_order_to_that_destination() -> void:
	var tank := GameManager.spawn_unit(TANK_STATS, GameManager.get_player(GameManager.BLUE_TEAM_ID), Vector3.ZERO)
	GameManager.spawn_unit(TANK_STATS, GameManager.get_player(GameManager.RED_TEAM_ID), Vector3(10, 0, 0))
	GameManager.start_battle()
	SelectionManager.select_single(tank)
	_main._pending_patrol = true

	var camera: Camera3D = _main.get_node("Camera3D")
	var destination := Vector3(3, 0, 3)
	_main._resolve_pending_patrol(camera.unproject_position(destination))
	await wait_physics_frames(1) # CommandQueue.DEFAULT_INPUT_DELAY_TICKS -- the order doesn't apply until a later tick now

	assert_false(_main._pending_patrol, "resolving should clear the pending state")
	assert_not_null(tank.current_order)
	assert_eq(tank.current_order.type, Unit.OrderType.PATROL)


func test_right_click_cancels_a_pending_patrol_without_issuing_an_order() -> void:
	var tank := GameManager.spawn_unit(TANK_STATS, GameManager.get_player(GameManager.BLUE_TEAM_ID), Vector3.ZERO)
	GameManager.spawn_unit(TANK_STATS, GameManager.get_player(GameManager.RED_TEAM_ID), Vector3(10, 0, 0))
	GameManager.start_battle()
	SelectionManager.select_single(tank)
	_main._pending_patrol = true

	var right_click := InputEventMouseButton.new()
	right_click.button_index = MOUSE_BUTTON_RIGHT
	right_click.pressed = true
	_main._handle_mouse_button(right_click)

	assert_false(_main._pending_patrol)
	assert_null(tank.current_order)


func test_escape_cancels_a_pending_patrol() -> void:
	_main._pending_patrol = true

	_main._handle_key(_key_event(KEY_ESCAPE))

	assert_false(_main._pending_patrol)


func test_patrol_hotkey_is_a_noop_during_auto_battle() -> void:
	var mode := BloodTournamentMode.new()
	GameManager.set_mode(mode)
	var blue := GameManager.get_player(GameManager.BLUE_TEAM_ID)
	blue.roster.append(TANK_STATS)
	GameManager.get_player(GameManager.RED_TEAM_ID).roster.append(TANK_STATS)
	_main._begin_patrol_targeting()

	assert_false(_main._pending_patrol, "manual orders (including Patrol) are disabled entirely under an auto-battle mode")
