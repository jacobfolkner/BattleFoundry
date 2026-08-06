## Owns two related but distinct responsibilities, kept in one autoload
## (see project.godot) because splitting them into separate globals buys
## no clarity -- every lifecycle transition needs to know whether a team
## can field a unit, so two files would just trade one coupling for
## another. The two responsibilities are kept structurally separate
## within this file instead (see the section banners below):
##
## - Battle Lifecycle: the PLACEMENT / BATTLE / GAME_OVER state machine.
##   battle_state is only ever written by _transition_to(), and every
##   transition is its own named method that validates itself before
##   calling it -- an invalid transition simply doesn't happen, rather
##   than being something callers have to avoid. can_start_battle(),
##   is_battle_active(), and friends let callers (UI, tests, a future
##   Countdown/Pause/Rematch state) ask questions without attempting --
##   and silently no-op-ing -- a transition.
##
## - Unit Registry: spawning units and tracking who's still alive per
##   team. The lifecycle methods above only ever query this (via
##   _team_is_empty()); they never touch _units_by_team directly.
##
## Units and UI still only ever talk to GameManager, never to each
## other, which keeps both reusable by future game modes.
extends Node

enum BattleState { PLACEMENT, BATTLE, GAME_OVER }

signal battle_started
signal battle_ended(winning_team: Team.Type)

## Read-only from outside GameManager -- set only via _transition_to(),
## which every method below goes through after validating the
## transition. Treat this as query-only; use start_battle() /
## reset_battle() (or let combat resolve a winner) to change it.
var battle_state: BattleState = BattleState.PLACEMENT

## Where newly spawned units are parented. Set by Main.gd on _ready().
var units_container: Node3D

const UNIT_SCENE: PackedScene = preload("res://Scenes/Unit.tscn")

var _units_by_team: Dictionary = {
	Team.Type.BLUE: [],
	Team.Type.RED: [],
}


# ---------------------------------------------------------------------
# Battle Lifecycle
# ---------------------------------------------------------------------

func is_placement_phase() -> bool:
	return battle_state == BattleState.PLACEMENT


func is_battle_active() -> bool:
	return battle_state == BattleState.BATTLE


func is_game_over() -> bool:
	return battle_state == BattleState.GAME_OVER


## True only when a battle could actually be started right now: still in
## PLACEMENT, and both teams have at least one unit. Split out from
## start_battle() so callers (a Start Battle button, tests, a future
## Countdown state) can check eligibility without attempting a
## transition that might silently no-op.
func can_start_battle() -> bool:
	return is_placement_phase() and not _team_is_empty(Team.Type.BLUE) and not _team_is_empty(Team.Type.RED)


## PLACEMENT -> BATTLE. No-ops if can_start_battle() is false.
func start_battle() -> void:
	if not can_start_battle():
		return
	_transition_to(BattleState.BATTLE)
	battle_started.emit()


## BATTLE -> GAME_OVER. Private: the only legal route to GAME_OVER is
## combat resolving a winner, which only _on_unit_died can detect.
func _end_battle(winning_team: Team.Type) -> void:
	if not is_battle_active():
		return
	_transition_to(BattleState.GAME_OVER)
	battle_ended.emit(winning_team)


## PLACEMENT, BATTLE, or GAME_OVER -> PLACEMENT. Frees any units still
## in the arena and clears both rosters, so the lifecycle state and the
## actual battlefield can never disagree about whether a battle is in
## progress.
##
## Not called anywhere in gameplay yet -- no "New Battle" UI exists --
## but is the natural foundation for a future Rematch/Replay milestone,
## and lets tests get a clean PLACEMENT state between cases through the
## public API instead of reaching into _units_by_team directly.
func reset_battle() -> void:
	for team in _units_by_team:
		for unit in _units_by_team[team]:
			if is_instance_valid(unit):
				unit.queue_free()
		_units_by_team[team].clear()
	_transition_to(BattleState.PLACEMENT)


## The only place battle_state is written.
func _transition_to(new_state: BattleState) -> void:
	battle_state = new_state


# ---------------------------------------------------------------------
# Unit Registry
# ---------------------------------------------------------------------

## Instantiates a Unit at the given position, registers it, and returns it.
func spawn_unit(stats: UnitStats, team: Team.Type, spawn_position: Vector3) -> Unit:
	var unit: Unit = UNIT_SCENE.instantiate()
	units_container.add_child(unit)
	unit.global_position = spawn_position
	unit.setup(stats, team)
	unit.died.connect(_on_unit_died)
	_units_by_team[team].append(unit)
	return unit


## Returns the closest living enemy to `unit`, or null if none remain.
func find_nearest_enemy(unit: Unit) -> Unit:
	var enemies: Array = _units_by_team[Team.get_opponent(unit.team)]
	var nearest: Unit = null
	var nearest_distance: float = INF
	for enemy in enemies:
		if not is_instance_valid(enemy) or enemy.current_health <= 0.0:
			continue
		var distance := Unit.horizontal_distance_to(unit.global_position, enemy.global_position)
		if distance < nearest_distance:
			nearest_distance = distance
			nearest = enemy
	return nearest


func _team_is_empty(team: Team.Type) -> bool:
	return _units_by_team[team].is_empty()


func _on_unit_died(unit: Unit) -> void:
	_units_by_team[unit.team].erase(unit)

	if not is_battle_active():
		return
	if _team_is_empty(Team.Type.BLUE):
		_end_battle(Team.Type.RED)
	elif _team_is_empty(Team.Type.RED):
		_end_battle(Team.Type.BLUE)
