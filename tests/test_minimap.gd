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


## The view-footprint overlay (drawn as an outline in _draw(), not
## directly pixel-inspectable, same reasoning this file's own header
## comment already gives for the dots) -- covered here at the level that
## IS testable: the 4 ground-intersection points its shape is built from.
func test_camera_view_corners_on_ground_returns_4_points_at_the_default_camera_pose() -> void:
	var corners := _minimap._camera_view_corners_on_ground()

	assert_eq(corners.size(), 4, "OrbitCamera's default pitch/distance should see ground on all 4 screen corners")


## The camera's own focus point (what it's actually centered on) should
## always land inside the quadrilateral its 4 corners describe -- a cheap,
## robust sanity check that the ground-intersection math isn't wildly
## wrong (e.g. corners on the wrong side of the camera), without needing
## real pixel inspection.
func test_camera_focus_point_falls_within_its_own_view_corners_bounding_box() -> void:
	var camera: Camera3D = _main.get_node("Camera3D")
	var corners := _minimap._camera_view_corners_on_ground()
	assert_eq(corners.size(), 4)

	var min_x := corners[0].x
	var max_x := corners[0].x
	var min_z := corners[0].z
	var max_z := corners[0].z
	for corner in corners:
		min_x = minf(min_x, corner.x)
		max_x = maxf(max_x, corner.x)
		min_z = minf(min_z, corner.z)
		max_z = maxf(max_z, corner.z)

	assert_true(camera._focus_point.x >= min_x and camera._focus_point.x <= max_x)
	assert_true(camera._focus_point.z >= min_z and camera._focus_point.z <= max_z)


## Before this fix, a single missed corner ray (e.g. a top-of-screen ray
## pointing above the horizon at OrbitCamera's shallowest pitch) made
## _camera_view_corners_on_ground() return [] entirely and the overlay
## vanish. Now a partial hit still produces something to draw a box from.
func test_camera_view_corners_on_ground_still_returns_something_at_shallow_pitch() -> void:
	var camera: Camera3D = _main.get_node("Camera3D")
	camera._pitch = deg_to_rad(15.0) # OrbitCamera's own _MIN_PITCH
	camera._update_transform()

	var corners := _minimap._camera_view_corners_on_ground()

	assert_false(corners.is_empty(), "a partial hit should still produce a usable box instead of vanishing")
