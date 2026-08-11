## Translucent preview of a not-yet-bought unit, following the cursor
## during the Blood Tournament build menu's click-to-place flow (see
## PlayerInputController._pending_build_stats). One persistent
## MeshInstance3D, position/visibility/mesh swapped in place rather than
## instantiate-and-free every frame -- same pooled-node convention
## SelectionManager._build_indicator() already uses for its own
## selection ring.
##
## Deliberately NOT a full Unit scene instance -- no collision, no
## NavigationAgent3D, no AI, no health bar, just the visual. Unit.gd's
## own _build_appearance() isn't factored out as a reusable standalone
## helper (it assumes a full Unit's other @onready fields exist and
## always builds collision/health-bar/status-indicator alongside the
## mesh), so this mirrors just its mesh_shape match on its own rather
## than pulling in everything else that method does.
##
## First real use of transparency anywhere in this codebase (grepped:
## zero existing StandardMaterial3D sets `transparency` or an alpha
## below 1.0 before this) -- every other material here is opaque.
class_name PlacementGhost
extends Node3D

const _VALID_ALPHA := 0.5
const _INVALID_COLOR := Color(1.0, 0.2, 0.2, 0.5)

var _mesh_instance: MeshInstance3D
var _material: StandardMaterial3D


func _ready() -> void:
	_mesh_instance = MeshInstance3D.new()
	add_child(_mesh_instance)

	_material = StandardMaterial3D.new()
	_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED

	visible = false


## Builds the mesh for `stats` (same shape/size fields, and the same
## 3-way match, Unit._build_appearance() reads) and shows it tinted with
## `team_color` at _VALID_ALPHA -- call set_valid(false, ...) afterward
## for a point that starts out invalid.
func show_for(stats: UnitStats, team_color: Color) -> void:
	var mesh: Mesh
	match stats.mesh_shape:
		"Capsule":
			var capsule := CapsuleMesh.new()
			capsule.radius = stats.mesh_size.x
			capsule.height = stats.mesh_size.y
			mesh = capsule
		"Cone":
			var cone := CylinderMesh.new()
			cone.top_radius = 0.0
			cone.bottom_radius = stats.mesh_size.x
			cone.height = stats.mesh_size.y
			mesh = cone
		_:
			var box := BoxMesh.new()
			box.size = stats.mesh_size
			mesh = box
	mesh.surface_set_material(0, _material)
	_mesh_instance.mesh = mesh
	# Half the mesh height keeps the ghost resting on the ground instead
	# of being centered through the floor -- same reasoning
	# Unit._build_appearance() already documents for the real mesh.
	_mesh_instance.position.y = stats.mesh_size.y * 0.5

	set_valid(true, team_color)
	visible = true


## true: reduced-alpha team color (a legal spot to confirm). false: a
## flat red tint (the cursor is outside the buying team's own courtyard
## -- see CrossArenaMap.is_in_teams_courtyard()) -- confirming here is a
## no-op, not a cancel, so the tint is the only feedback the player gets
## that this particular spot won't work.
func set_valid(valid: bool, team_color: Color) -> void:
	if valid:
		_material.albedo_color = Color(team_color.r, team_color.g, team_color.b, _VALID_ALPHA)
	else:
		_material.albedo_color = _INVALID_COLOR


func move_to(world_position: Vector3) -> void:
	global_position = world_position


func hide_ghost() -> void:
	visible = false
