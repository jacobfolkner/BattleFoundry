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
	Vector3(-5, 0, -32), # 0 Blue -- North arm, west half
	Vector3(5, 0, -32),  # 1 Red -- North arm, east half
	Vector3(32, 0, -5),  # 2 Green -- East arm, north half
	Vector3(32, 0, 5),   # 3 Yellow -- East arm, south half
	Vector3(5, 0, 32),   # 4 Purple -- South arm, east half
	Vector3(-5, 0, 32),  # 5 Orange -- South arm, west half
	Vector3(-32, 0, 5),  # 6 Cyan -- West arm, south half
	Vector3(-32, 0, -5), # 7 Magenta -- West arm, north half
]

## SPAWN_POINTS' index within an arm's pair -- entries 0/1 share the
## North arm, 2/3 East, 4/5 South, 6/7 West, so XOR-1 toggles within a
## pair regardless of which half of that pair `index` is. Used by
## BloodTournamentController.begin_march() to find which team_id
## currently shares a marching squad's arm (see round_spawn_points,
## which reassigns SPAWN_POINTS' 8 positions across team_ids each round
## -- the pairing is a property of the position values, not team_id).
static func arm_partner_index(index: int) -> int:
	return index ^ 1


## Subtle per-arm ground tints -- gameplay feedback, 2026-08-11: "the
## cross arena has no lane/landmark differentiation," every arm and the
## center hub being the exact same flat color. Deliberately small
## deviations from ArenaMap.DEFAULT_GROUND_COLOR (0.16, 0.18, 0.16), not
## saturated team-style colors -- this is a "which lane am I looking at"
## wayfinding cue, not a team-ownership signal (a team's own arm changes
## every round via round_spawn_points, so an arm's tint is fixed to its
## compass direction, never to whichever team currently holds it). The
## center hub itself stays untinted (see build()) -- it's the shared
## convergence point, not any one lane.
const _NORTH_ARM_COLOR := Color(0.14, 0.17, 0.20, 1)
const _EAST_ARM_COLOR := Color(0.20, 0.15, 0.14, 1)
const _SOUTH_ARM_COLOR := Color(0.14, 0.20, 0.15, 1)
const _WEST_ARM_COLOR := Color(0.20, 0.19, 0.13, 1)


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
	_ground_pieces.append(build_ground_piece(ground_parent, Vector2(full, full), Vector3.ZERO)) # center -- left at DEFAULT_GROUND_COLOR, neutral convergence point
	_ground_pieces.append(build_ground_piece(ground_parent, Vector2(full, arm_length), Vector3(0, 0, -arm_center), _NORTH_ARM_COLOR))
	_ground_pieces.append(build_ground_piece(ground_parent, Vector2(arm_length, full), Vector3(arm_center, 0, 0), _EAST_ARM_COLOR))
	_ground_pieces.append(build_ground_piece(ground_parent, Vector2(full, arm_length), Vector3(0, 0, arm_center), _SOUTH_ARM_COLOR))
	_ground_pieces.append(build_ground_piece(ground_parent, Vector2(arm_length, full), Vector3(-arm_center, 0, 0), _WEST_ARM_COLOR))

	# The 8 lineup courtyards, one per team, in the diagonal gaps between
	# arms -- deliberately separate ground pieces, not part of the 5
	# nav-mesh-connected polygons above (see _courtyard_center()'s own
	# doc comment for why no corridor geometry is needed).
	var courtyard_size := Vector2(COURTYARD_HALF_EXTENT, COURTYARD_HALF_EXTENT) * 2.0
	for team_id in GameManager.all_team_ids():
		_ground_pieces.append(build_ground_piece(ground_parent, courtyard_size, _courtyard_center(team_id)))


func get_spawn_points() -> Array[Vector3]:
	return SPAWN_POINTS


## Half-extent of each team's lineup-courtyard footprint -- must clear the
## widest existing squad spread (Fighter, squad_size 5, spacing
## collision_radius*2.5+0.3 ~= 1.55m -> ~6.2m across) plus the Builder
## standing apart from it (see _COURTYARD_BUILDER_OFFSET below), and
## leave room for a roster that grows over a long match. Needs real
## playtesting, not just this reasoning.
const COURTYARD_HALF_EXTENT := 6.5

## How far a courtyard sits from center along its own arm's dominant
## (depth) axis, and how far it's pushed along the lateral axis into the
## diagonal gap between two arms -- deliberately NOT equal (depth <
## lateral) so the two teams sharing one diagonal corner land well apart
## from each other (~17m center-to-center) rather than converging near
## the same point.
const _COURTYARD_ARM_DEPTH := 17.0
const _COURTYARD_LATERAL_REACH := 32.0

## How far the unit spawn anchor (get_courtyard_unit_anchor()) sits from
## the courtyard's own center, pushed toward the inner/front edge facing
## the arm -- the opposite direction from the Builder
## (_COURTYARD_BUILDER_OFFSET below). Comfortably inside
## COURTYARD_HALF_EXTENT so its own footprint (plus
## _COURTYARD_SLOT_LATERAL_SPACING's fan-out) never clips the courtyard's
## edge.
const _COURTYARD_UNIT_OFFSET := 3.0

## How far the Builder (get_courtyard_position()) sits from the
## courtyard's own center, pushed toward the outer/back wall -- distinct
## from _COURTYARD_UNIT_OFFSET (and pushed noticeably further) so the
## Builder reads as clearly outside the actual build/roster area, not
## just another few meters into the same footprint (gameplay feedback,
## 2026-08-11: "the builder should just be a stationary unit somewhere
## immediately outside the building area"). Bounded by the courtyard's
## own square footprint: with the outward direction's dominant axis
## component always ~0.883 (see _courtyard_center()'s LATERAL_REACH/
## ARM_DEPTH split, constant across all 8 teams since they're just
## axis-swapped), COURTYARD_HALF_EXTENT / 0.883 =~ 7.36 is the largest
## offset that still lands on the courtyard's own ground tile -- past
## that the Builder would visibly float off the tile into the plain
## default-colored ground beyond it. 6.0 stays safely under that with
## real margin while landing near the tile's own back edge.
const _COURTYARD_BUILDER_OFFSET := 6.0

## Lateral spacing between roster slots' squads within a courtyard --
## get_courtyard_unit_anchor()'s `slot_index` param. Previously every
## slot resolved to the exact same point (only ever noticeable once a
## roster had 2+ slots realized in the same sync_courtyard_to_roster()
## pass, e.g. a fresh round -- gameplay feedback, 2026-08-11: "between
## rounds some units disappear," actually still alive but physically
## coincident with another squad, with only one of the two visible
## squad[0]s winning the overlap). COURTYARD_HALF_EXTENT (6.5) already
## budgeted "room for a roster that grows" per its own doc comment, so
## the fix is purely this offset never having been wired in.
const _COURTYARD_SLOT_LATERAL_SPACING := 2.0


## The center of team_id's lineup courtyard -- one of 8, in the diagonal
## gaps between arms (verified outside all 5 nav-mesh polygons, with
## margin). Deliberately NOT nav-mesh-connected -- courtyard units are
## only ever teleport-positioned (GameManager.spawn_squad()'s existing
## direct positioning, and a direct reposition at battle start), never
## pathfound to/from, so no corridor geometry is needed to reach one.
## Derived from SPAWN_POINTS[team_id] rather than 8 hand-picked
## constants: reuses that point's own already-correct lateral sign
## (whichever axis has the smaller magnitude) instead of re-deriving arm
## orientation from scratch, and stays correct automatically if
## SPAWN_POINTS/GameManager.CROSS_ARM_* ever change.
static func _courtyard_center(team_id: int) -> Vector3:
	var anchor := SPAWN_POINTS[team_id]
	if absf(anchor.x) > absf(anchor.z):
		# East/West arm: X is the dominant (depth) axis, Z is lateral.
		return Vector3(signf(anchor.x) * _COURTYARD_ARM_DEPTH, 0, signf(anchor.z) * _COURTYARD_LATERAL_REACH)
	else:
		# North/South arm: Z is the dominant (depth) axis, X is lateral.
		return Vector3(signf(anchor.x) * _COURTYARD_LATERAL_REACH, 0, signf(anchor.z) * _COURTYARD_ARM_DEPTH)


## Direction from the map's own center out toward team_id's courtyard --
## shared by get_courtyard_position()/get_courtyard_unit_anchor() (pushed
## in opposite directions along it) and get_courtyard_inward_direction()
## below (its negation).
static func _courtyard_outward_direction(team_id: int) -> Vector2:
	var center := _courtyard_center(team_id)
	return Vector2(center.x, center.z).normalized()


## The Builder's own spawn position -- the courtyard center pushed
## _COURTYARD_BUILDER_OFFSET further outward (away from the map center),
## toward the courtyard's back wall, well clear of the unit lineup. See
## get_courtyard_unit_anchor() for where purchased squads spawn instead.
static func get_courtyard_position(team_id: int) -> Vector3:
	var center := _courtyard_center(team_id)
	var outward := _courtyard_outward_direction(team_id)
	return center + Vector3(outward.x, 0, outward.y) * _COURTYARD_BUILDER_OFFSET


## Where a purchased squad spawns -- the courtyard center pushed
## _COURTYARD_UNIT_OFFSET inward (toward the map center / the arm this
## courtyard belongs to), the opposite side of the Builder in
## get_courtyard_position(). `slot_index` (the roster slot this squad
## belongs to) fans it out sideways from the 3rd slot onward so distinct
## roster slots never spawn on top of each other -- see
## _COURTYARD_SLOT_LATERAL_SPACING's own doc comment.
static func get_courtyard_unit_anchor(team_id: int, slot_index: int = 0) -> Vector3:
	var center := _courtyard_center(team_id)
	var outward := _courtyard_outward_direction(team_id)
	var lateral := Vector2(-outward.y, outward.x)
	var lateral_offset := lateral * _courtyard_slot_lateral_offset(slot_index)
	return center - Vector3(outward.x, 0, outward.y) * _COURTYARD_UNIT_OFFSET + Vector3(lateral_offset.x, 0, lateral_offset.y)


## Fans out symmetrically from slot 0 (0, +1, -1, +2, -2, ...) rather
## than marching monotonically in one direction, so a growing roster
## stays centered on the courtyard instead of drifting toward one edge.
static func _courtyard_slot_lateral_offset(slot_index: int) -> float:
	if slot_index == 0:
		return 0.0
	var pair := (slot_index + 1) / 2
	var sign_value := 1.0 if slot_index % 2 == 1 else -1.0
	return sign_value * float(pair) * _COURTYARD_SLOT_LATERAL_SPACING


## "Front of the lineup" direction -- toward the map center / the arm
## this courtyard belongs to (same direction get_courtyard_unit_anchor()
## pushes into). Used by GameManager.reorder_roster_by_courtyard_depth()
## to rank courtyard squads by how close to the front each one's been
## dragged.
static func get_courtyard_inward_direction(team_id: int) -> Vector2:
	return -_courtyard_outward_direction(team_id)


## Whether `position` falls inside ANY team's courtyard rectangle --
## Unit._clamp_to_cross_arena() uses this as an early-out, since that
## method runs unconditionally every physics frame and would otherwise
## yank a courtyard-positioned unit back onto the nearest arm (a
## courtyard sits in a "dead corner" diagonally outside both of the
## cross's bars, exactly what that clamp exists to pull back in). Checked
## against the courtyard's true center, not either anchor, so both the
## Builder and unit spawn points (and anything moving between them) stay
## covered.
static func is_in_any_courtyard(position: Vector3) -> bool:
	for team_id in GameManager.all_team_ids():
		if is_in_teams_courtyard(team_id, position):
			return true
	return false


## Whether `position` falls inside team_id's OWN courtyard specifically --
## unlike is_in_any_courtyard() above (which only answers "courtyard-shaped
## space in general," for the arena clamp's own purposes), the
## ghost-placement flow (PlayerInputController) needs to know a clicked
## point is inside THIS team's own pen, not just anyone's.
static func is_in_teams_courtyard(team_id: int, position: Vector3) -> bool:
	var center := _courtyard_center(team_id)
	return absf(position.x - center.x) <= COURTYARD_HALF_EXTENT and absf(position.z - center.z) <= COURTYARD_HALF_EXTENT
