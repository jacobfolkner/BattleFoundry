## A minimal billboard health bar: two flat primitive quads (background +
## fill), no textures or imported art required.
##
## Purely a display component -- it holds no combat logic and is driven
## entirely by set_fraction(), so any future entity that wants a health
## readout (not just Unit) can reuse it without depending on combat code.
class_name HealthBar
extends Node3D

const WIDTH: float = 1.0
const HEIGHT: float = 0.12
const FULL_COLOR := Color(0.2, 0.9, 0.2)
const EMPTY_COLOR := Color(0.9, 0.15, 0.15)

var _fill_instance: MeshInstance3D
var _fill_mesh: QuadMesh
var _fill_material: StandardMaterial3D


func _ready() -> void:
	_build_background()
	_build_fill()


func _build_background() -> void:
	var quad := QuadMesh.new()
	quad.size = Vector2(WIDTH, HEIGHT)
	quad.surface_set_material(0, _make_bar_material(Color(0.08, 0.08, 0.08)))

	var mesh_instance := MeshInstance3D.new()
	mesh_instance.mesh = quad
	add_child(mesh_instance)


func _build_fill() -> void:
	_fill_mesh = QuadMesh.new()
	_fill_mesh.size = Vector2(WIDTH, HEIGHT)
	_fill_material = _make_bar_material(FULL_COLOR)
	_fill_mesh.surface_set_material(0, _fill_material)

	_fill_instance = MeshInstance3D.new()
	_fill_instance.mesh = _fill_mesh
	# A tiny vertical offset separates the two coplanar quads so they don't
	# z-fight. Vertical (not depth) is used because it stays correct
	# regardless of which way the unit is currently facing -- a unit only
	# ever yaws (rotates around world Y), so an offset along Y is the one
	# axis that rotation can't turn edge-on to the camera.
	_fill_instance.position.y = 0.002
	add_child(_fill_instance)


func _make_bar_material(color: Color) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	return material


## Updates the bar to show `fraction` (0.0 - 1.0) of health remaining.
## The fill shrinks from its right edge and shifts from green to red.
func set_fraction(fraction: float) -> void:
	fraction = clampf(fraction, 0.0, 1.0)
	_fill_mesh.size.x = WIDTH * fraction
	_fill_instance.position.x = -WIDTH * 0.5 * (1.0 - fraction)
	_fill_material.albedo_color = FULL_COLOR.lerp(EMPTY_COLOR, 1.0 - fraction)
