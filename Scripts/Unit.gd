## A single combat unit: a primitive-mesh body that fights automatically
## once GameManager enters the BATTLE state.
##
## Movement and combat are intentionally simple -- a unit walks in a
## straight line toward its current target and has no collision with
## other units. This keeps the prototype readable; a real steering or
## pathfinding system can replace _move_toward_target() later without
## touching the rest of the class or GameManager.
class_name Unit
extends Node3D

signal died(unit: Unit)

@export var stats: UnitStats

var team: Team.Type
var current_health: float
var target_enemy: Unit = null

var _attack_cooldown: float = 0.0

@onready var _mesh_instance: MeshInstance3D = $MeshInstance3D


## Called by GameManager right after the unit is added to the scene tree.
func setup(new_stats: UnitStats, new_team: Team.Type) -> void:
	stats = new_stats
	team = new_team
	current_health = stats.max_health
	_build_appearance()


func _build_appearance() -> void:
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

	var material := StandardMaterial3D.new()
	material.albedo_color = Color(0.25, 0.45, 1.0) if team == Team.Type.BLUE else Color(1.0, 0.25, 0.25)
	mesh.surface_set_material(0, material)

	_mesh_instance.mesh = mesh
	# Half the mesh height keeps the unit resting on the ground instead of
	# being centered through the floor.
	_mesh_instance.position.y = stats.mesh_size.y * 0.5


func _process(delta: float) -> void:
	if GameManager.battle_state != GameManager.BattleState.BATTLE:
		return
	if current_health <= 0.0:
		return

	_update_target()
	if target_enemy == null:
		return

	var distance := global_position.distance_to(target_enemy.global_position)
	if distance > stats.attack_range:
		_move_toward_target(delta)
	else:
		_attack(delta)


func _update_target() -> void:
	var target_is_valid := target_enemy != null and is_instance_valid(target_enemy) and target_enemy.current_health > 0.0
	if not target_is_valid:
		target_enemy = GameManager.find_nearest_enemy(self)


func _move_toward_target(delta: float) -> void:
	var direction := target_enemy.global_position - global_position
	direction.y = 0.0
	direction = direction.normalized()
	global_position += direction * stats.move_speed * delta
	look_at(global_position + direction, Vector3.UP)


func _attack(delta: float) -> void:
	_attack_cooldown -= delta
	if _attack_cooldown > 0.0:
		return
	_attack_cooldown = stats.attack_interval
	target_enemy.take_damage(stats.damage)


func take_damage(amount: float) -> void:
	current_health -= amount
	if current_health <= 0.0:
		die()


func die() -> void:
	died.emit(self)
	queue_free()
