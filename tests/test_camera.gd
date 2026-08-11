## Tests for Scripts/Core/OrbitCamera.gd's jump-to-hero (Space) -- roadmap
## Phase 1's "jump-to-hero" item. Arrow-key/edge-pan movement itself isn't
## covered here (no clean way to simulate a held key or a real cursor
## position under GUT's headless run without a lot of input-simulation
## machinery for a small, low-risk feature) -- verified instead by the
## full suite staying green, since a broken pan would corrupt the many
## existing tests' _camera.project_ray_origin()/project_ray_normal() calls.
extends GutTest

const TANK_STATS: UnitStats = preload("res://Resources/Units/TankStats.tres")
const HERO_STATS: UnitStats = preload("res://Resources/Units/HeroStats.tres")

var _main: Node3D
var _camera: Camera3D


func before_each() -> void:
	GameManager.reset_battle()
	GameManager.current_mode = ClassicEliminationMode.new() # don't let an earlier test's mode leak in
	_main = load("res://Scenes/Main.tscn").instantiate()
	add_child_autofree(_main)
	await wait_physics_frames(2)
	_camera = _main.get_node("Camera3D")


func test_jump_to_hero_centers_the_focus_point_on_the_local_players_hero() -> void:
	var blue := GameManager.get_player(GameManager.BLUE_TEAM_ID)
	SelectionManager.local_player = blue
	GameManager.spawn_unit(HERO_STATS, blue, Vector3(12, 0, -7))

	var event := InputEventKey.new()
	event.keycode = KEY_SPACE
	event.pressed = true
	_camera._unhandled_input(event)

	assert_almost_eq(_camera._focus_point.x, 12.0, 0.01)
	assert_almost_eq(_camera._focus_point.z, -7.0, 0.01)


func test_jump_to_hero_ignores_a_non_hero_unit() -> void:
	var blue := GameManager.get_player(GameManager.BLUE_TEAM_ID)
	SelectionManager.local_player = blue
	GameManager.spawn_unit(TANK_STATS, blue, Vector3(12, 0, -7))
	var focus_before: Vector3 = _camera._focus_point

	var event := InputEventKey.new()
	event.keycode = KEY_SPACE
	event.pressed = true
	_camera._unhandled_input(event)

	assert_eq(_camera._focus_point, focus_before, "a non-hero unit should never move the camera")


func test_jump_to_hero_ignores_another_teams_hero() -> void:
	var blue := GameManager.get_player(GameManager.BLUE_TEAM_ID)
	var red := GameManager.get_player(GameManager.RED_TEAM_ID)
	SelectionManager.local_player = blue
	GameManager.spawn_unit(HERO_STATS, red, Vector3(12, 0, -7))
	var focus_before: Vector3 = _camera._focus_point

	var event := InputEventKey.new()
	event.keycode = KEY_SPACE
	event.pressed = true
	_camera._unhandled_input(event)

	assert_eq(_camera._focus_point, focus_before, "Space should only ever jump to your OWN hero")


func test_jump_to_hero_is_a_harmless_noop_with_no_hero_owned() -> void:
	var blue := GameManager.get_player(GameManager.BLUE_TEAM_ID)
	SelectionManager.local_player = blue
	var focus_before: Vector3 = _camera._focus_point

	var event := InputEventKey.new()
	event.keycode = KEY_SPACE
	event.pressed = true
	_camera._unhandled_input(event)

	assert_eq(_camera._focus_point, focus_before)
