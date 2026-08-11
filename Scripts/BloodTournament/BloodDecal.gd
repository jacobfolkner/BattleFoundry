## A flat, fading pool left on the ground where a unit died -- Phase 11
## genre polish (the map is literally called Blood Tournament). Purely
## cosmetic: no collision, no gameplay effect. spawn() is the only entry
## point; the decal frees itself once its own fade timer elapses, so
## nothing else needs to track or clean these up.
class_name BloodDecal
extends MeshInstance3D

const _DURATION := 12.0
const _FADE_START := 8.0 ## Full opacity until this, then eases out over the remainder of _DURATION.
const _RADIUS := 0.9

var _elapsed := 0.0
var _material: StandardMaterial3D


static func spawn(parent: Node3D, ground_position: Vector3) -> void:
	var decal := BloodDecal.new()
	parent.add_child(decal)
	# A hair above the ground plane avoids z-fighting with it.
	decal.global_position = Vector3(ground_position.x, 0.02, ground_position.z)
	decal._build()


func _build() -> void:
	var plane := PlaneMesh.new()
	plane.size = Vector2.ONE * _RADIUS * 2.0
	mesh = plane

	_material = StandardMaterial3D.new()
	_material.albedo_color = Color(0.35, 0.02, 0.02, 0.85)
	_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mesh.surface_set_material(0, _material)


func _physics_process(delta: float) -> void:
	_elapsed += delta
	if _elapsed >= _FADE_START:
		var fade_t := (_elapsed - _FADE_START) / (_DURATION - _FADE_START)
		_material.albedo_color.a = lerpf(0.85, 0.0, fade_t)
	if _elapsed >= _DURATION:
		queue_free()
