## Read-only unit inspection: tracks which Unit is currently selected,
## answers "what unit (if any) is under this screen point," and renders a
## couple of purely-cosmetic 3D indicators (a disc under the selected
## unit, a line to its current target).
##
## This module only ever reads public state that Unit already exposes
## (team, target_enemy, global_position, current_health) plus the new
## Unit.get_debug_info() snapshot method -- it never writes to gameplay
## state, and no gameplay script depends on this file existing. Selecting
## a unit has zero effect on combat, AI, or targeting.
##
## Autoload singleton (see project.godot) so both the click routing in
## Main.gd and the display in UI/DebugPanel.gd can reach it without a
## node path.
extends Node

signal selection_changed(unit: Unit)

const UNITS_PHYSICS_LAYER := 2 # matches Unit.tscn collision_layer/mask
const _RAY_LENGTH := 1000.0
const _INDICATOR_COLOR := Color(1.0, 0.9, 0.2)

var selected_unit: Unit = null

var _selection_indicator: MeshInstance3D
var _target_line: MeshInstance3D
var _line_material: StandardMaterial3D


func _ready() -> void:
	_build_selection_indicator()
	_build_target_line()


func _process(_delta: float) -> void:
	if selected_unit != null and not is_instance_valid(selected_unit):
		clear_selection()
		return

	var is_valid := has_valid_selection()
	_selection_indicator.visible = is_valid
	if is_valid:
		_selection_indicator.global_position = selected_unit.global_position + Vector3(0, 0.02, 0)

	var target: Unit = selected_unit.target_enemy if is_valid else null
	var target_valid := target != null and is_instance_valid(target) and target.current_health > 0.0
	_target_line.visible = target_valid
	if target_valid:
		_redraw_target_line(
			selected_unit.global_position + Vector3(0, 0.05, 0),
			target.global_position + Vector3(0, 0.05, 0)
		)


## Attempts to select whichever Unit's collision shape is under
## `screen_position`, as seen from `camera`. Returns true if a unit was
## hit (and selection updated), so callers -- Main.gd's click routing --
## know whether to treat the click as consumed or let it fall through to
## other handling (e.g. unit placement).
func try_select_at(camera: Camera3D, screen_position: Vector2) -> bool:
	var space_state := camera.get_world_3d().direct_space_state
	var from := camera.project_ray_origin(screen_position)
	var to := from + camera.project_ray_normal(screen_position) * _RAY_LENGTH
	var query := PhysicsRayQueryParameters3D.create(from, to, UNITS_PHYSICS_LAYER)
	var hit := space_state.intersect_ray(query)

	if hit.is_empty() or not (hit.collider is Unit):
		return false

	select(hit.collider)
	return true


func select(unit: Unit) -> void:
	selected_unit = unit
	_resize_selection_indicator(unit.stats.collision_radius)
	selection_changed.emit(unit)


func clear_selection() -> void:
	if selected_unit == null:
		return
	selected_unit = null
	selection_changed.emit(null)


## True if a unit is selected, still exists, and hasn't died.
func has_valid_selection() -> bool:
	return selected_unit != null and is_instance_valid(selected_unit) and selected_unit.current_health > 0.0


func _build_selection_indicator() -> void:
	var material := StandardMaterial3D.new()
	material.albedo_color = _INDICATOR_COLOR
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED

	# A flat disc (not a ring) so its orientation is unambiguous -- the
	# same CylinderMesh-as-flat-disc technique Unit.gd already uses for
	# the Archer's cone, just with top_radius == bottom_radius.
	var disc := CylinderMesh.new()
	disc.height = 0.04
	disc.surface_set_material(0, material)

	_selection_indicator = MeshInstance3D.new()
	_selection_indicator.mesh = disc
	_selection_indicator.visible = false
	add_child(_selection_indicator)


func _resize_selection_indicator(unit_radius: float) -> void:
	var disc: CylinderMesh = _selection_indicator.mesh
	var radius := unit_radius + 0.25
	disc.top_radius = radius
	disc.bottom_radius = radius


func _build_target_line() -> void:
	_line_material = StandardMaterial3D.new()
	_line_material.albedo_color = _INDICATOR_COLOR
	_line_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED

	_target_line = MeshInstance3D.new()
	_target_line.mesh = ImmediateMesh.new()
	_target_line.visible = false
	add_child(_target_line)


func _redraw_target_line(from: Vector3, to: Vector3) -> void:
	var mesh: ImmediateMesh = _target_line.mesh
	mesh.clear_surfaces()
	mesh.surface_begin(Mesh.PRIMITIVE_LINES, _line_material)
	mesh.surface_add_vertex(from)
	mesh.surface_add_vertex(to)
	mesh.surface_end()
