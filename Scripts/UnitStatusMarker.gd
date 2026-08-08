## A minimal billboard "something is affecting you" marker: one small flat
## quad floating above a Unit (just above its HealthBar), shown/hidden and
## recolored by Unit._refresh_status_indicator(). Same "flat primitive,
## unshaded, no textures" approach as HealthBar.gd -- this project has no
## icon/texture assets at all, so this is one colored marker standing in
## for a whole buff/debuff icon row, not per-effect icons. Proves CC/buffs
## are no longer entirely invisible in-world (previously only visible via
## the debug panel's "Effects" line or the HUD's 2D buff row for whichever
## unit happens to be selected).
class_name UnitStatusMarker
extends Node3D

const _SIZE := Vector2(0.35, 0.35)

var _mesh_instance: MeshInstance3D
var _material: StandardMaterial3D


func _ready() -> void:
	var quad := QuadMesh.new()
	quad.size = _SIZE

	_material = StandardMaterial3D.new()
	_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_material.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	quad.surface_set_material(0, _material)

	_mesh_instance = MeshInstance3D.new()
	_mesh_instance.mesh = quad
	_mesh_instance.visible = false
	add_child(_mesh_instance)


func show_status(color: Color) -> void:
	_material.albedo_color = color
	_mesh_instance.visible = true


func hide_status() -> void:
	_mesh_instance.visible = false
