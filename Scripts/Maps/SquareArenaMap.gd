## The default 40x40 flat square -- exactly what every pre-cross-map test
## and ClassicEliminationMode still assume. A single open rectangle,
## authored directly (NavigationMesh.vertices/add_polygon()) rather than
## baked from Ground's geometry -- deterministic and instant, and there's
## nothing to bake around: this shared arena has no static obstacles (see
## tests/test_pathfinding.gd for a *baked* NavigationMesh with a real
## wall to route around, built in an isolated scene rather than here,
## since a shared obstacle here would sit in the footsteps of dozens of
## existing tests that spawn/path units anywhere in the 40x40 plane,
## corners included). Units path against this via
## Unit._seek_position()/get_next_path_position() -- see its doc comment
## for why that's an actual navmesh query now, not just a straight-line
## direction fed to avoidance the way it was before this existed.
class_name SquareArenaMap
extends ArenaMap


func build(nav_region_parent: Node3D, ground_parent: Node3D) -> void:
	var half := GameManager.ARENA_HALF_EXTENT
	var nav_mesh := NavigationMesh.new()
	nav_mesh.vertices = PackedVector3Array([
		Vector3(-half, 0, -half),
		Vector3(half, 0, -half),
		Vector3(half, 0, half),
		Vector3(-half, 0, half),
	])
	nav_mesh.add_polygon(PackedInt32Array([0, 1, 2, 3]))

	_nav_region = NavigationRegion3D.new()
	_nav_region.navigation_mesh = nav_mesh
	nav_region_parent.add_child(_nav_region)

	_ground_pieces.append(build_ground_piece(ground_parent, Vector2(half * 2.0, half * 2.0), Vector3.ZERO))
