## Tests for UI/MiniMap.gd -- roadmap Phase 1's minimap item. Only the
## pure coordinate-mapping/mode-switching logic is covered (_world_to_map(),
## _current_half_extent()); the actual dot rendering (_draw()) isn't
## asserted on directly (no pixel-inspection facility in GUT's headless
## run) -- verified instead by the full suite staying green, same
## reasoning test_camera.gd already documents for arrow-key pan.
extends GutTest

var _main: Node3D
var _minimap: MiniMap


func before_each() -> void:
	GameManager.reset_battle()
	GameManager.current_mode = ClassicEliminationMode.new() # don't let an earlier test's mode leak in
	_main = load("res://Scenes/Main.tscn").instantiate()
	add_child_autofree(_main)
	await wait_physics_frames(2)
	# MiniMap is built in code, not present in the scene tree by name --
	# find it by type among HUD's children instead.
	var hud := _main.get_node("HUDLayer/HUD")
	for child in hud.get_children():
		if child is MiniMap:
			_minimap = child
			break


func test_world_origin_maps_to_the_center_of_the_minimap_square() -> void:
	var mapped := _minimap._world_to_map(Vector3.ZERO, 20.0)
	assert_almost_eq(mapped.x, MiniMap._SIZE * 0.5, 0.01)
	assert_almost_eq(mapped.y, MiniMap._SIZE * 0.5, 0.01)


func test_a_point_at_the_positive_half_extent_maps_to_the_squares_far_edge() -> void:
	var mapped := _minimap._world_to_map(Vector3(20.0, 0, 20.0), 20.0)
	assert_almost_eq(mapped.x, MiniMap._SIZE, 0.01)
	assert_almost_eq(mapped.y, MiniMap._SIZE, 0.01)


func test_a_point_beyond_the_half_extent_clamps_to_the_squares_edge_instead_of_overshooting() -> void:
	var mapped := _minimap._world_to_map(Vector3(999.0, 0, -999.0), 20.0)
	assert_almost_eq(mapped.x, MiniMap._SIZE, 0.01)
	assert_almost_eq(mapped.y, 0.0, 0.01)


func test_half_extent_uses_the_plain_square_arena_bound_under_classic_mode() -> void:
	GameManager.current_mode = ClassicEliminationMode.new()
	assert_eq(_minimap._current_half_extent(), GameManager.ARENA_HALF_EXTENT)


func test_half_extent_uses_the_wider_cross_map_bound_under_blood_tournament() -> void:
	GameManager.current_mode = BloodTournamentMode.new()
	assert_eq(_minimap._current_half_extent(), GameManager.CROSS_ARM_OUTER_EXTENT)
