## Tests for the click-to-target flow added to Q/W/E ability casting for
## UNIT_TARGET abilities (see Main._try_cast_or_target()/
## _resolve_pending_ability_target(), SelectionManager.cast_ability_at_target()).
## Previously a UNIT_TARGET ability could only auto-target whatever the
## caster's target_enemy already was; a NO_TARGET/PASSIVE/AURA ability
## still casts immediately, unchanged.
extends GutTest

const TANK_STATS: UnitStats = preload("res://Resources/Units/TankStats.tres")
const FIGHTER_STATS: UnitStats = preload("res://Resources/Units/FighterStats.tres")
const ARCHER_STATS: UnitStats = preload("res://Resources/Units/ArcherStats.tres")

var _main: Node3D


func before_each() -> void:
	GameManager.reset_battle()
	GameManager.current_mode = ClassicEliminationMode.new()
	_main = load("res://Scenes/Main.tscn").instantiate()
	add_child_autofree(_main)
	await wait_physics_frames(2)


func test_pressing_q_for_a_unit_target_ability_enters_pending_target_mode_instead_of_casting() -> void:
	var blue := GameManager.get_player(GameManager.BLUE_TEAM_ID)
	var red := GameManager.get_player(GameManager.RED_TEAM_ID)
	var archer := GameManager.spawn_unit(ARCHER_STATS, blue, Vector3.ZERO) # Frost Bolt is slot 0, UNIT_TARGET
	GameManager.spawn_unit(TANK_STATS, red, Vector3(10, 0, 0))
	GameManager.start_battle()
	SelectionManager.select_single(archer)

	var key_event := InputEventKey.new()
	key_event.keycode = KEY_Q
	key_event.pressed = true
	_main._handle_key(key_event)

	assert_eq(_main._pending_ability_target, 0)
	assert_eq(archer.get_ability_cooldown_remaining(0), 0.0, "entering targeting mode should not have cast anything yet")


func test_clicking_a_unit_while_pending_casts_at_that_explicit_target_not_the_auto_target() -> void:
	var blue := GameManager.get_player(GameManager.BLUE_TEAM_ID)
	var red := GameManager.get_player(GameManager.RED_TEAM_ID)
	var archer := GameManager.spawn_unit(ARCHER_STATS, blue, Vector3.ZERO)
	var decoy := GameManager.spawn_unit(TANK_STATS, red, Vector3(1, 0, 0)) # closest -- would be archer.target_enemy
	var explicit_target := GameManager.spawn_unit(TANK_STATS, red, Vector3(4, 0, 0)) # farther, but within Frost Bolt's 6m range
	GameManager.start_battle()
	await wait_physics_frames(2) # let _update_target() actually settle target_enemy onto the decoy
	SelectionManager.select_single(archer)

	_main._pending_ability_target = 0 # simulate having pressed Q already
	var camera: Camera3D = _main.get_node("Camera3D")
	await wait_physics_frames(1) # let the physics server register the new collision shapes before raycasting them

	_main._resolve_pending_ability_target(camera.unproject_position(explicit_target.global_position))

	assert_eq(_main._pending_ability_target, -1, "resolving should clear the pending state")
	assert_not_null(explicit_target.get_effect("Frost Bolt"), "the explicitly clicked target should be hit")
	assert_null(decoy.get_effect("Frost Bolt"), "only the explicitly clicked target should be hit, not whichever enemy the archer happened to already be fighting")


func test_right_click_cancels_a_pending_target_without_casting() -> void:
	var blue := GameManager.get_player(GameManager.BLUE_TEAM_ID)
	var red := GameManager.get_player(GameManager.RED_TEAM_ID)
	var archer := GameManager.spawn_unit(ARCHER_STATS, blue, Vector3.ZERO)
	GameManager.spawn_unit(TANK_STATS, red, Vector3(10, 0, 0))
	GameManager.start_battle()
	SelectionManager.select_single(archer)
	_main._pending_ability_target = 0

	var right_click := InputEventMouseButton.new()
	right_click.button_index = MOUSE_BUTTON_RIGHT
	right_click.pressed = true
	_main._handle_mouse_button(right_click)

	assert_eq(_main._pending_ability_target, -1)
	assert_eq(archer.get_ability_cooldown_remaining(0), 0.0, "cancelling must not cast anything")


func test_escape_cancels_a_pending_target() -> void:
	_main._pending_ability_target = 0

	var esc := InputEventKey.new()
	esc.keycode = KEY_ESCAPE
	esc.pressed = true
	_main._handle_key(esc)

	assert_eq(_main._pending_ability_target, -1)


func test_no_target_ability_still_casts_immediately_without_entering_pending_mode() -> void:
	var blue := GameManager.get_player(GameManager.BLUE_TEAM_ID)
	var red := GameManager.get_player(GameManager.RED_TEAM_ID)
	var tank := GameManager.spawn_unit(TANK_STATS, blue, Vector3.ZERO) # War Stomp is slot 0, NO_TARGET
	GameManager.spawn_unit(FIGHTER_STATS, red, Vector3(10, 0, 0))
	GameManager.start_battle()
	SelectionManager.select_single(tank)

	var key_event := InputEventKey.new()
	key_event.keycode = KEY_Q
	key_event.pressed = true
	_main._handle_key(key_event)

	assert_eq(_main._pending_ability_target, -1, "a NO_TARGET ability must cast immediately, not enter targeting mode")
	assert_true(tank.get_ability_cooldown_remaining(0) > 0.0, "War Stomp should be on cooldown after an immediate cast")
