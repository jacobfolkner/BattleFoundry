## A single fired shot: travels from its spawn point toward -- or
## continuously tracking, if HOMING -- a target, and delivers `source`'s
## attack via Unit.resolve_hit() on arrival, instead of Unit._attack()
## applying damage the instant the attack cooldown allows. Every future
## missile-based ability reuses this rather than reinventing "travels
## through space, then hits" per ability.
##
## Not a physics body: nothing needs to collide with a projectile in
## flight, so it just moves by direct position assignment (the same
## technique Unit.apply_knockback() uses for its arc) and checks
## horizontal proximity to its target each frame instead of doing real
## collision detection.
class_name Projectile
extends Node3D

enum GuidanceType { BALLISTIC, HOMING }

## Safety net so a projectile can't fly forever -- e.g. a HOMING shot
## chasing a target that's consistently faster than it, or a BALLISTIC
## shot aimed at a point so far away travel would otherwise take absurdly
## long. Should never actually trigger under normal archetype tuning.
const _MAX_LIFETIME := 5.0
const _HIT_DISTANCE := 0.3 ## Horizontal distance (m) counted as "arrived."

var source: Unit
var target: Unit
var guidance: GuidanceType
var speed: float

## Fixed at setup() for BALLISTIC (aimed at target's position at launch,
## and never recalculated -- this is what lets a target dodge a
## BALLISTIC shot by moving); recomputed every frame for HOMING.
var _direction: Vector3
var _lifetime_elapsed: float = 0.0

@onready var _mesh_instance: MeshInstance3D = $MeshInstance3D


func _ready() -> void:
	var mesh := SphereMesh.new()
	mesh.radius = 0.12
	mesh.height = 0.24

	var material := StandardMaterial3D.new()
	material.albedo_color = Color(1.0, 0.9, 0.3)
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mesh.surface_set_material(0, material)

	_mesh_instance.mesh = mesh


## Called by Unit right after instancing and positioning it (global_position
## must already be set -- BALLISTIC's fixed direction is computed from it
## here, once).
func setup(new_source: Unit, new_target: Unit, new_speed: float, new_guidance: GuidanceType) -> void:
	source = new_source
	target = new_target
	speed = new_speed
	guidance = new_guidance
	_direction = _horizontal_direction_to(global_position, target.global_position)


func _physics_process(delta: float) -> void:
	_lifetime_elapsed += delta
	if _lifetime_elapsed >= _MAX_LIFETIME:
		queue_free()
		return

	if not is_instance_valid(target):
		queue_free() # nothing left to hit or track -- dissipates harmlessly
		return

	if guidance == GuidanceType.HOMING:
		_direction = _horizontal_direction_to(global_position, target.global_position)

	global_position += _direction * speed * delta

	if Unit.horizontal_distance_to(global_position, target.global_position) <= _HIT_DISTANCE:
		_impact()


## `source` (and its stats) must still exist to resolve a hit -- if the
## attacker died mid-flight, its shot just fizzles rather than resolving
## through a freed Unit. No current archetype fires a projectile fast
## enough, or lives short enough, for this to come up in practice.
func _impact() -> void:
	if is_instance_valid(source) and is_instance_valid(target) and target.current_health > 0.0:
		source.resolve_hit(target, global_position)
	queue_free()


static func _horizontal_direction_to(from: Vector3, to: Vector3) -> Vector3:
	var direction := to - from
	direction.y = 0.0
	if direction.length_squared() < 0.0001:
		return Vector3.FORWARD
	return direction.normalized()
