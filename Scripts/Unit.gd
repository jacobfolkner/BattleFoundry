## A single combat unit: a primitive-mesh body that fights automatically
## once GameManager enters the BATTLE state.
##
## Movement is still a straight-line walk toward the current target (no
## steering or pathfinding); a real steering system can replace
## _move_toward_target() later without touching the rest of the class or
## GameManager. What's no longer true is that units pass through each
## other: Unit is a CharacterBody3D and moves via move_and_slide(), so
## Godot's physics server resolves overlap and blocking against every
## other unit's CollisionShape3D -- no custom overlap code here at all.
class_name Unit
extends CharacterBody3D

signal died(unit: Unit)

@export var stats: UnitStats

var team: Team.Type
var current_health: float
var target_enemy: Unit = null

var _attack_cooldown: float = 0.0
var _health_bar: HealthBar

@onready var _mesh_instance: MeshInstance3D = $MeshInstance3D
@onready var _collision_shape: CollisionShape3D = $CollisionShape3D


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

	_build_collision()
	_build_health_bar()


func _build_collision() -> void:
	var shape := CapsuleShape3D.new()
	shape.radius = stats.collision_radius
	# A capsule's height must be at least 2x its radius (Godot clamps
	# otherwise); maxf keeps this valid regardless of how mesh_size or
	# collision_radius get tuned later.
	shape.height = maxf(stats.mesh_size.y, stats.collision_radius * 2.0)
	_collision_shape.shape = shape
	_collision_shape.position.y = stats.mesh_size.y * 0.5


func _build_health_bar() -> void:
	_health_bar = HealthBar.new()
	_health_bar.position.y = stats.mesh_size.y + 0.35
	add_child(_health_bar)


func _physics_process(delta: float) -> void:
	velocity = Vector3.ZERO

	var is_battling := GameManager.battle_state == GameManager.BattleState.BATTLE and current_health > 0.0
	if is_battling:
		_update_target()
		if target_enemy != null:
			var distance := global_position.distance_to(target_enemy.global_position)
			if distance > stats.attack_range:
				_move_toward_target()
			else:
				_attack(delta)

	# Called every physics frame, even when velocity is zero, so the
	# physics server also resolves any resting overlap (e.g. two units
	# placed too close together) rather than only reacting while moving.
	move_and_slide()

	# move_and_slide() (MOTION_MODE_FLOATING) resolves penetration along
	# whichever axis has the least overlap. Units spawned at or very near
	# the same point have no well-defined *horizontal* separating axis --
	# their capsules are coincident along the vertical axis too -- so the
	# physics server can occasionally choose to push one straight up
	# instead of sideways. Nothing here simulates height or gravity, so
	# any such drift is permanent unless corrected: this line is the fix,
	# re-asserting the ground-plane invariant every frame regardless of
	# what direction collision resolution picked. It also forecloses
	# vertical stacking, since two units can never end up on different Y
	# layers long enough to stop colliding horizontally.
	global_position.y = 0.0


func _update_target() -> void:
	var target_is_valid := target_enemy != null and is_instance_valid(target_enemy) and target_enemy.current_health > 0.0
	if not target_is_valid:
		target_enemy = GameManager.find_nearest_enemy(self)


func _move_toward_target() -> void:
	var direction := target_enemy.global_position - global_position
	direction.y = 0.0
	direction = direction.normalized()
	velocity = direction * stats.move_speed
	look_at(global_position + direction, Vector3.UP)


func _attack(delta: float) -> void:
	_attack_cooldown -= delta
	if _attack_cooldown > 0.0:
		return
	_attack_cooldown = stats.attack_interval
	target_enemy.take_damage(stats.damage)


func take_damage(amount: float) -> void:
	current_health -= amount
	_health_bar.set_fraction(current_health / stats.max_health)
	if current_health <= 0.0:
		die()


func die() -> void:
	died.emit(self)
	queue_free()


## Read-only snapshot for Scripts/DebugInspector.gd / UI/DebugPanel.gd.
## Everything here is derived by re-reading existing public state -- this
## method never sets anything, so it can't affect AI, combat, or
## targeting. Values are pre-formatted display strings by design, so the
## debug panel stays a generic "print whatever keys this returns" renderer
## and never needs unit-specific formatting logic of its own.
func get_debug_info() -> Dictionary:
	return {
		"Name": stats.unit_name,
		"Team": Team.get_display_name(team),
		"Health": "%.0f / %.0f" % [current_health, stats.max_health],
		"AI State": _describe_state(),
		"Target": target_enemy.stats.unit_name if target_enemy != null else "(none)",
		"Distance to Target": _describe_distance_to_target(),
		"Attack Range": "%.1f m" % stats.attack_range,
		"Attack Cooldown": "%.1fs" % maxf(_attack_cooldown, 0.0),
		"Position": "(%.1f, %.1f, %.1f)" % [global_position.x, global_position.y, global_position.z],
	}


## Mirrors the branches in _physics_process (without altering any of
## them) to describe, in words, which one is currently active.
func _describe_state() -> String:
	if current_health <= 0.0:
		return "Dead"
	match GameManager.battle_state:
		GameManager.BattleState.PLACEMENT:
			return "Waiting (Placement)"
		GameManager.BattleState.GAME_OVER:
			return "Waiting (Game Over)"
	if target_enemy == null:
		return "Searching for Target"
	var distance := global_position.distance_to(target_enemy.global_position)
	return "Moving" if distance > stats.attack_range else "Attacking"


func _describe_distance_to_target() -> String:
	if target_enemy == null:
		return "-"
	return "%.1f m" % global_position.distance_to(target_enemy.global_position)
