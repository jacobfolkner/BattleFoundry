## Base class for a battle arena's shape: the ground meshes + navmesh a
## GameMode wants built, plus (for a map with dedicated per-team pens)
## the deployment spawn points along its edges.
##
## GameMode.get_arena_map() is what picks which concrete ArenaMap a given
## mode uses -- Main.gd builds every distinct map class any registered
## mode's get_arena_map() can return, once, up front (see
## Main._build_arenas()), and just enables/disables whichever one the
## CURRENT mode wants (see Main._sync_arena_shape()) rather than
## freeing/rebuilding on every mode swap. A new map shape is a new
## ArenaMap subclass plus one new GameMode.get_arena_map() override --
## Main.gd needs no per-shape branching to support it.
class_name ArenaMap
extends RefCounted

var _nav_region: NavigationRegion3D
var _ground_pieces: Array[MeshInstance3D] = []


## Builds this map's navigation region (parented to nav_region_parent)
## and ground pieces (parented to ground_parent) -- two separate parents
## since the nav region is a sibling of the ground container in the
## scene tree, not its child. Must be overridden; stores the built nodes
## on _nav_region/_ground_pieces so set_active() below can toggle them.
func build(_nav_region_parent: Node3D, _ground_parent: Node3D) -> void:
	push_error("ArenaMap.build() must be overridden by a concrete subclass")


## Enables/disables this map's navmesh + ground visibility -- called by
## Main._sync_arena_shape() whenever GameMode.get_arena_map() changes.
## Not overridden by subclasses -- toggling is identical for every shape,
## only build() differs.
func set_active(active: bool) -> void:
	if _nav_region:
		_nav_region.enabled = active
	for piece in _ground_pieces:
		piece.visible = active


## Team_id -> spawn anchor for a map with dedicated per-team pens (e.g.
## the cross map's 8 arm anchors). Empty (default) means "no fixed
## per-team anchors" -- correct for the plain square arena, which never
## had any; a mode using it doesn't do team-anchored deployment at all.
func get_spawn_points() -> Array[Vector3]:
	return []


## The default ground tint -- matches the original Scenes/Main.tscn
## Ground node's own look. Public so a subclass overriding `color` (see
## build_ground_piece() below) knows what "neutral/unthemed" means.
const DEFAULT_GROUND_COLOR := Color(0.16, 0.18, 0.16, 1)

## Shared ground-piece builder -- the same flat PlaneMesh + material every
## concrete map shape uses by default. `color` lets a subclass tint an
## individual piece (CrossArenaMap.build() uses this to give each of the
## 4 arms its own subtle identifying color -- gameplay feedback,
## 2026-08-11: "the cross arena has no lane/landmark differentiation" --
## while leaving the center hub and courtyards at DEFAULT_GROUND_COLOR).
## Not private (no leading underscore) so subclasses in their own files
## can call it.
func build_ground_piece(parent: Node3D, size: Vector2, position: Vector3, color: Color = DEFAULT_GROUND_COLOR) -> MeshInstance3D:
	var mesh := PlaneMesh.new()
	mesh.size = size

	var material := StandardMaterial3D.new()
	material.albedo_color = color
	mesh.surface_set_material(0, material)

	var instance := MeshInstance3D.new()
	instance.mesh = mesh
	instance.position = position
	parent.add_child(instance)
	return instance
