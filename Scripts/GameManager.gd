## Global coordinator for unit registration, battle state, and win
## detection. Registered as an autoload singleton (see project.godot)
## so any Unit or UI script can reach it without holding a node path.
##
## This is deliberately the only "global" piece of state in the
## prototype -- everything else (units, HUD) talks to GameManager
## rather than to each other, which keeps the systems here reusable
## by future game modes beyond Blood Tournament.
extends Node

enum BattleState { PLACEMENT, BATTLE, GAME_OVER }

signal battle_started
signal battle_ended(winning_team: Team.Type)

var battle_state: BattleState = BattleState.PLACEMENT

## Where newly spawned units are parented. Set by Main.gd on _ready().
var units_container: Node3D

const UNIT_SCENE: PackedScene = preload("res://Scenes/Unit.tscn")

var _units_by_team: Dictionary = {
	Team.Type.BLUE: [],
	Team.Type.RED: [],
}


## Instantiates a Unit at the given position, registers it, and returns it.
func spawn_unit(stats: UnitStats, team: Team.Type, spawn_position: Vector3) -> Unit:
	var unit: Unit = UNIT_SCENE.instantiate()
	units_container.add_child(unit)
	unit.global_position = spawn_position
	unit.setup(stats, team)
	unit.died.connect(_on_unit_died)
	_units_by_team[team].append(unit)
	return unit


## Moves from PLACEMENT to BATTLE. No-ops if either team is empty.
func start_battle() -> void:
	if battle_state != BattleState.PLACEMENT:
		return
	if _units_by_team[Team.Type.BLUE].is_empty() or _units_by_team[Team.Type.RED].is_empty():
		return
	battle_state = BattleState.BATTLE
	battle_started.emit()


## Returns the closest living enemy to `unit`, or null if none remain.
func find_nearest_enemy(unit: Unit) -> Unit:
	var enemies: Array = _units_by_team[Team.get_opponent(unit.team)]
	var nearest: Unit = null
	var nearest_distance: float = INF
	for enemy in enemies:
		if not is_instance_valid(enemy) or enemy.current_health <= 0.0:
			continue
		var distance := unit.global_position.distance_to(enemy.global_position)
		if distance < nearest_distance:
			nearest_distance = distance
			nearest = enemy
	return nearest


func _on_unit_died(unit: Unit) -> void:
	_units_by_team[unit.team].erase(unit)

	if battle_state != BattleState.BATTLE:
		return
	if _units_by_team[Team.Type.BLUE].is_empty():
		_end_battle(Team.Type.RED)
	elif _units_by_team[Team.Type.RED].is_empty():
		_end_battle(Team.Type.BLUE)


func _end_battle(winning_team: Team.Type) -> void:
	battle_state = BattleState.GAME_OVER
	battle_ended.emit(winning_team)
