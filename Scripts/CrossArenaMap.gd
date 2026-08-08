## The 8-team Blood Tournament map: a square center plus 4 arms of the
## same width extending outward, one per cardinal direction (see
## SPAWN_POINTS for where each team starts). Hand-authored as 5 quads
## sharing vertex indices at the center/arm junctions, the same "direct
## NavigationMesh.vertices/add_polygon(), not baked" approach
## SquareArenaMap uses and for the same reason (deterministic, instant,
## nothing to bake around) -- junction vertices are shared by index (not
## just coincident position) so Godot's navigation system definitely
## stitches the 5 polygons into one walkable region rather than relying
## on floating-point-exact edge matching between separately authored
## polygons.
class_name CrossArenaMap
extends ArenaMap

## Team_id -> spawn anchor, near the outer edge of one of the cross map's
## 4 arms (2 team_ids per arm). Used by Main._deploy_next_pending_slot()
## as the fallback anchor and by Main._assign_random_spawn_points() as
## the pool it shuffles across teams each round. Kept as a class-level
## const (not computed in build()) since spawn point values don't depend
## on the built scene nodes at all -- callers can read get_spawn_points()
## without this map ever having been built.
const SPAWN_POINTS: Array[Vector3] = [
	Vector3(-4, 0, -26), # 0 Blue -- North arm, west half
	Vector3(4, 0, -26),  # 1 Red -- North arm, east half
	Vector3(26, 0, -4),  # 2 Green -- East arm, north half
	Vector3(26, 0, 4),   # 3 Yellow -- East arm, south half
	Vector3(4, 0, 26),   # 4 Purple -- South arm, east half
	Vector3(-4, 0, 26),  # 5 Orange -- South arm, west half
	Vector3(-26, 0, 4),  # 6 Cyan -- West arm, south half
	Vector3(-26, 0, -4), # 7 Magenta -- West arm, north half
]


func build(nav_region_parent: Node3D, ground_parent: Node3D) -> void:
	var half := GameManager.CROSS_ARM_HALF_WIDTH
	var outer := GameManager.CROSS_ARM_OUTER_EXTENT

	var vertices := PackedVector3Array([
		Vector3(-half, 0, -half), # 0: center NW
		Vector3(half, 0, -half),  # 1: center NE
		Vector3(half, 0, half),   # 2: center SE
		Vector3(-half, 0, half),  # 3: center SW
		Vector3(-half, 0, -outer), # 4: north-arm outer NW
		Vector3(half, 0, -outer),  # 5: north-arm outer NE
		Vector3(outer, 0, -half),  # 6: east-arm outer NE
		Vector3(outer, 0, half),   # 7: east-arm outer SE
		Vector3(half, 0, outer),   # 8: south-arm outer SE
		Vector3(-half, 0, outer),  # 9: south-arm outer SW
		Vector3(-outer, 0, half),  # 10: west-arm outer SW
		Vector3(-outer, 0, -half), # 11: west-arm outer NW
	])

	var nav_mesh := NavigationMesh.new()
	nav_mesh.vertices = vertices
	nav_mesh.add_polygon(PackedInt32Array([0, 1, 2, 3])) # center
	nav_mesh.add_polygon(PackedInt32Array([4, 5, 1, 0])) # north arm
	nav_mesh.add_polygon(PackedInt32Array([1, 6, 7, 2])) # east arm
	nav_mesh.add_polygon(PackedInt32Array([2, 8, 9, 3])) # south arm
	nav_mesh.add_polygon(PackedInt32Array([3, 10, 11, 0])) # west arm

	_nav_region = NavigationRegion3D.new()
	_nav_region.navigation_mesh = nav_mesh
	nav_region_parent.add_child(_nav_region)

	var full := half * 2.0
	var arm_length := outer - half
	var arm_center := half + arm_length * 0.5
	_ground_pieces.append(build_ground_piece(ground_parent, Vector2(full, full), Vector3.ZERO)) # center
	_ground_pieces.append(build_ground_piece(ground_parent, Vector2(full, arm_length), Vector3(0, 0, -arm_center))) # north
	_ground_pieces.append(build_ground_piece(ground_parent, Vector2(arm_length, full), Vector3(arm_center, 0, 0))) # east
	_ground_pieces.append(build_ground_piece(ground_parent, Vector2(full, arm_length), Vector3(0, 0, arm_center))) # south
	_ground_pieces.append(build_ground_piece(ground_parent, Vector2(arm_length, full), Vector3(-arm_center, 0, 0))) # west


func get_spawn_points() -> Array[Vector3]:
	return SPAWN_POINTS
