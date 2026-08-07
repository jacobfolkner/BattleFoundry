## Read-only unit inspection: tracks which Unit is currently selected,
## answers "what unit (if any) is under this screen point," and renders
## purely-cosmetic 3D indicators for it. Only a disc under the selected
## unit is always on; everything else -- a disc under its target, a line
## between them, an attack-range ring, and cyan/magenta lines for desired
## vs. avoidance-adjusted velocity (see Unit._build_avoidance()) -- is
## targeting/steering detail gated behind the "pathfinding" flag in
## Scripts/DebugSettings.gd (toggled from UI/DebugMenu.gd, backtick), so
## a plain click doesn't dump the whole set into the arena. Colors are
## public constants so DebugMenu can build a matching legend without
## duplicating them.
##
## This module only ever reads public state that Unit already exposes
## (team, target_enemy, desired_velocity, velocity, global_position,
## current_health) plus Unit.get_debug_info() -- it never writes to
## gameplay state, and no gameplay script depends on this file existing.
## Selecting a unit has zero effect on combat, AI, or targeting.
##
## Autoload singleton (see project.godot) so both the click routing in
## Main.gd and the display in UI/DebugPanel.gd can reach it without a
## node path.
extends Node

signal selection_changed(unit: Unit)

const UNITS_PHYSICS_LAYER := 2 # matches Unit.tscn collision_layer/mask
const _RAY_LENGTH := 1000.0

const SELECTION_COLOR := Color(1.0, 0.9, 0.2) # yellow: selected unit + its target line
const TARGET_HIGHLIGHT_COLOR := Color(1.0, 0.3, 0.15) # orange-red: the enemy being targeted
const ATTACK_RANGE_COLOR := Color(0.85, 0.85, 0.85) # light grey: attack_range ring
const DESIRED_VELOCITY_COLOR := Color(0.2, 0.9, 1.0) # cyan: where the unit wants to go
const SAFE_VELOCITY_COLOR := Color(1.0, 0.2, 0.9) # magenta: where avoidance is actually sending it

var selected_unit: Unit = null

var _selection_indicator: MeshInstance3D
var _target_highlight_indicator: MeshInstance3D
var _target_line: MeshInstance3D
var _attack_range_ring: MeshInstance3D
var _desired_velocity_line: MeshInstance3D
var _safe_velocity_line: MeshInstance3D


func _ready() -> void:
	_selection_indicator = _build_disc(SELECTION_COLOR)
	_target_highlight_indicator = _build_disc(TARGET_HIGHLIGHT_COLOR)
	_attack_range_ring = _build_ring(ATTACK_RANGE_COLOR)
	_target_line = _build_line(SELECTION_COLOR)
	_desired_velocity_line = _build_line(DESIRED_VELOCITY_COLOR)
	_safe_velocity_line = _build_line(SAFE_VELOCITY_COLOR)


func _process(_delta: float) -> void:
	if selected_unit != null and not is_instance_valid(selected_unit):
		clear_selection()
		return

	var is_valid := has_valid_selection()
	_selection_indicator.visible = is_valid
	if is_valid:
		_selection_indicator.global_position = selected_unit.global_position + Vector3(0, 0.02, 0)

	# Everything below is targeting/steering detail, not "who's selected" --
	# stays hidden until the "pathfinding" flag is on, so a plain click
	# doesn't dump the whole arena in overlay lines.
	var show_pathfinding := is_valid and DebugSettings.is_enabled(DebugSettings.FLAG_PATHFINDING)

	_attack_range_ring.visible = show_pathfinding
	if show_pathfinding:
		# attack_range is reach *beyond* the unit's own body (see
		# Unit._distance_to_target_edge()), so the ring showing true
		# reach needs collision_radius added back in.
		_resize_ring(_attack_range_ring, selected_unit.stats.attack_range + selected_unit.stats.collision_radius)
		_attack_range_ring.global_position = selected_unit.global_position + Vector3(0, 0.02, 0)

	var target: Unit = selected_unit.target_enemy if is_valid else null
	var target_valid := show_pathfinding and target != null and is_instance_valid(target) and target.current_health > 0.0
	_target_line.visible = target_valid
	_target_highlight_indicator.visible = target_valid
	_desired_velocity_line.visible = target_valid
	_safe_velocity_line.visible = target_valid
	if target_valid:
		_redraw_line(
			_target_line,
			selected_unit.global_position + Vector3(0, 0.05, 0),
			target.global_position + Vector3(0, 0.05, 0)
		)
		_resize_disc(_target_highlight_indicator, target.stats.collision_radius)
		_target_highlight_indicator.global_position = target.global_position + Vector3(0, 0.03, 0)

		var origin := selected_unit.global_position + Vector3(0, 0.1, 0)
		_redraw_line(_desired_velocity_line, origin, origin + selected_unit.desired_velocity)
		_redraw_line(_safe_velocity_line, origin, origin + selected_unit.velocity)


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
	_resize_disc(_selection_indicator, unit.stats.collision_radius)
	selection_changed.emit(unit)


func clear_selection() -> void:
	if selected_unit == null:
		return
	selected_unit = null
	selection_changed.emit(null)


## True if a unit is selected, still exists, and hasn't died.
func has_valid_selection() -> bool:
	return selected_unit != null and is_instance_valid(selected_unit) and selected_unit.current_health > 0.0


## A flat disc (not a ring) so its orientation is unambiguous -- the same
## CylinderMesh-as-flat-disc technique Unit.gd uses for the Archer's cone,
## just with top_radius == bottom_radius.
func _build_disc(color: Color) -> MeshInstance3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED

	var disc := CylinderMesh.new()
	disc.height = 0.04
	disc.surface_set_material(0, material)

	var instance := MeshInstance3D.new()
	instance.mesh = disc
	instance.visible = false
	add_child(instance)
	return instance


func _resize_disc(instance: MeshInstance3D, unit_radius: float) -> void:
	var disc: CylinderMesh = instance.mesh
	var radius := unit_radius + 0.25
	disc.top_radius = radius
	disc.bottom_radius = radius


func _build_ring(color: Color) -> MeshInstance3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED

	var torus := TorusMesh.new()
	torus.inner_radius = 0.0 # set per-frame by _resize_ring
	torus.outer_radius = 0.01
	torus.surface_set_material(0, material)

	var instance := MeshInstance3D.new()
	instance.mesh = torus
	instance.visible = false
	add_child(instance)
	return instance


func _resize_ring(instance: MeshInstance3D, radius: float) -> void:
	var torus: TorusMesh = instance.mesh
	torus.inner_radius = maxf(radius - 0.05, 0.01)
	torus.outer_radius = radius + 0.05


func _build_line(color: Color) -> MeshInstance3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED

	var line := MeshInstance3D.new()
	line.mesh = ImmediateMesh.new()
	line.visible = false
	line.set_meta("line_material", material)
	add_child(line)
	return line


func _redraw_line(line: MeshInstance3D, from: Vector3, to: Vector3) -> void:
	var mesh: ImmediateMesh = line.mesh
	mesh.clear_surfaces()
	mesh.surface_begin(Mesh.PRIMITIVE_LINES, line.get_meta("line_material"))
	mesh.surface_add_vertex(from)
	mesh.surface_add_vertex(to)
	mesh.surface_end()
