## Owns three related but distinct responsibilities, kept in one autoload
## (see project.godot) because splitting them into separate globals buys
## no clarity -- every lifecycle transition needs to know whether a team
## can field a unit, so more files would just trade one coupling for
## another. The responsibilities are kept structurally separate within
## this file instead (see the section banners below):
##
## - Battle Lifecycle: the PLACEMENT / BATTLE / GAME_OVER state machine.
##   battle_state is only ever written by _transition_to(), and every
##   transition is its own named method that validates itself before
##   calling it -- an invalid transition simply doesn't happen, rather
##   than being something callers have to avoid. can_start_battle(),
##   is_battle_active(), and friends let callers (UI, tests, a future
##   Countdown/Pause/Rematch state) ask questions without attempting --
##   and silently no-op-ing -- a transition. What "winning" means is
##   delegated to current_mode (see GameMode.gd) rather than hardcoded
##   here -- GameManager stays a mode-agnostic entity registry +
##   lifecycle, and a mode like Blood Tournament (rounds, scoring) plugs
##   in without this file needing to know it exists.
##
## - Player Registry: the Player objects units are owned by, and the
##   AllianceMatrix that answers "is team A hostile to team B" instead of
##   a binary opponent function. Currently seeds exactly the two-player
##   prototype roster (BLUE_TEAM_ID/RED_TEAM_ID) that HUD's Blue/Red
##   buttons target -- a real lobby (Phase 1/8) replaces _register_default_players()
##   wholesale, not the Player/AllianceMatrix model itself.
##
## - Unit Registry: spawning units and tracking who's still alive per
##   team. The lifecycle methods above only ever query this (via
##   team_is_empty()); they never touch _units_by_team directly.
##
## Units and UI still only ever talk to GameManager, never to each
## other, which keeps both reusable by future game modes.
extends Node

enum BattleState { PLACEMENT, BATTLE, GAME_OVER }

signal battle_started
## winning_team_id is meaningless when is_draw is true -- callers must
## check is_draw first (see _declare_draw()).
signal battle_ended(winning_team_id: int, is_draw: bool)

## Read-only from outside GameManager -- set only via _transition_to(),
## which every method below goes through after validating the
## transition. Treat this as query-only; use start_battle() /
## reset_battle() (or let combat resolve a winner) to change it.
var battle_state: BattleState = BattleState.PLACEMENT

## Where newly spawned units are parented. Set by Main.gd on _ready().
var units_container: Node3D

const UNIT_SCENE: PackedScene = preload("res://Scenes/Unit.tscn")

## Half-width of the 40x40 ground plane (Scenes/Main.tscn), so Unit can
## clamp itself to the arena without duplicating the plane's dimensions.
const ARENA_HALF_EXTENT := 20.0

## No damage dealt anywhere on the field for this long during BATTLE means
## neither side can actually reach/hurt the other (e.g. an all-flying vs.
## all-ground-melee composition, or a caster that can't close range --
## see PR #4 review, "stalemate soft-lock"). Ends the battle as a draw
## instead of hanging forever. Comfortably above the longest normal-fight
## resolution time exercised by tests/test_battle_flow.gd (~15s budget).
## A var, not a const, solely so a stalemate test can shrink it instead of
## running real time out to 20s of simulated physics frames.
var STALEMATE_TIMEOUT := 20.0

## team_id for the default prototype roster's two slots -- what HUD's
## "Blue Team"/"Red Team" buttons and Main.gd's default selection target.
## Hostile to each other by AllianceMatrix's FFA-by-default rule, with no
## ally() call needed to reproduce the old always-hostile Team.Type
## behavior.
const BLUE_TEAM_ID := 0
const RED_TEAM_ID := 1

## player_id (int) -> Player. Seeded once at startup with the two-player
## prototype roster -- see _register_default_players().
var players: Dictionary = {}
var alliances := AllianceMatrix.new()

## What "winning" means for the battle currently in progress -- see
## GameMode.gd. Swappable via set_mode(); defaults to the original
## always-on elimination behavior so nothing regresses for a caller that
## never sets one.
var current_mode: GameMode = ClassicEliminationMode.new()

var _units_by_team: Dictionary = {} ## team_id (int) -> Array[Unit]. Keys created lazily by spawn_unit(), not hardcoded to two teams.

## Every unit spawned this battle, alive or dead -- unlike
## _units_by_team (which a unit is erased from the instant it dies, for
## roster/win-condition purposes), this is the reset_battle() cleanup
## list. A dying unit lingers as a corpse for a few seconds (see
## Unit._CORPSE_DECAY_DURATION) after leaving _units_by_team, so
## reset_battle() needs its own record to actually free it rather than
## leaking it into the next battle.
var _all_units: Array[Unit] = []

var _seconds_since_last_damage: float = 0.0


func _ready() -> void:
	_register_default_players()


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
##
## Hardcodes the two-team BLUE_TEAM_ID/RED_TEAM_ID elimination check --
## same scope as the pre-refactor version, just expressed through
## team_id instead of Team.Type. A real N-team victory condition is a
## GameMode concern (win conditions vary per mode: elimination, rounds,
## throne HP), not something this prototype-scale check should grow into.
func can_start_battle() -> bool:
	return is_placement_phase() and not team_is_empty(BLUE_TEAM_ID) and not team_is_empty(RED_TEAM_ID)


## PLACEMENT -> BATTLE. No-ops if can_start_battle() is false.
func start_battle() -> void:
	if not can_start_battle():
		return
	_seconds_since_last_damage = 0.0
	_transition_to(BattleState.BATTLE)
	current_mode.on_battle_started()
	battle_started.emit()


## Swaps the active mode -- takes effect for the *next* battle;
## mid-battle mode swaps aren't a supported thing to do. Resets to
## PLACEMENT first (via reset_battle()) so a mode with per-match state
## (round count, scores) always starts from a clean slate.
func set_mode(mode: GameMode) -> void:
	reset_battle()
	current_mode = mode


## BATTLE -> GAME_OVER. Private: the only legal route to GAME_OVER is
## combat resolving a winner, which only _on_unit_died can detect.
func _end_battle(winning_team_id: int) -> void:
	if not is_battle_active():
		return
	_transition_to(BattleState.GAME_OVER)
	current_mode.on_battle_ended(winning_team_id, false)
	battle_ended.emit(winning_team_id, false)


## BATTLE -> GAME_OVER, no winner. Only route in: _process()'s stalemate
## timer, when STALEMATE_TIMEOUT elapses with no damage dealt anywhere on
## the field (see the constant's doc comment).
func _declare_draw() -> void:
	if not is_battle_active():
		return
	_transition_to(BattleState.GAME_OVER)
	current_mode.on_battle_ended(BLUE_TEAM_ID, true)
	battle_ended.emit(BLUE_TEAM_ID, true)


func _process(delta: float) -> void:
	if not is_battle_active():
		return
	_seconds_since_last_damage += delta
	if _seconds_since_last_damage >= STALEMATE_TIMEOUT:
		_declare_draw()


## PLACEMENT, BATTLE, or GAME_OVER -> PLACEMENT. Frees any units still
## in the arena and clears both rosters, so the lifecycle state and the
## actual battlefield can never disagree about whether a battle is in
## progress.
##
## Also what set_mode() calls before swapping current_mode, and (once a
## mode like Blood Tournament wires it up) the natural way to reset the
## arena between rounds. Lets tests get a clean PLACEMENT state between
## cases through the public API instead of reaching into _units_by_team
## directly.
func reset_battle() -> void:
	for unit in _all_units:
		if is_instance_valid(unit):
			unit.queue_free()
	_all_units.clear()
	_units_by_team.clear()
	_transition_to(BattleState.PLACEMENT)


## The only place battle_state is written.
func _transition_to(new_state: BattleState) -> void:
	battle_state = new_state


# ---------------------------------------------------------------------
# Player Registry
# ---------------------------------------------------------------------

## Seeds the two-player prototype roster HUD's Blue/Red buttons and
## Main.gd's default selection target. player.id == player.team_id == slot
## for both, since this prototype is strictly one player per team; a real
## lobby replaces this method, not the Player/team_id split it produces.
func _register_default_players() -> void:
	var blue := Player.new(BLUE_TEAM_ID, BLUE_TEAM_ID, BLUE_TEAM_ID, "Blue", Color(0.25, 0.45, 1.0))
	var red := Player.new(RED_TEAM_ID, RED_TEAM_ID, RED_TEAM_ID, "Red", Color(1.0, 0.25, 0.25))
	players[blue.id] = blue
	players[red.id] = red


func get_player(player_id: int) -> Player:
	return players.get(player_id)


## Display name for battle_ended's winning_team_id -- looks up any
## Player currently on that team, since team_id (not player identity) is
## what a win condition resolves against. Falls back to a generic label
## if no live Player is on record for it (shouldn't happen with the
## current 1:1 prototype roster, but team_id is otherwise decoupled from
## Player, so this stays a lookup instead of an assumption).
func get_team_display_name(team_id: int) -> String:
	for player in players.values():
		if player.team_id == team_id:
			return player.display_name
	return "Team %d" % team_id


# ---------------------------------------------------------------------
# Unit Registry
# ---------------------------------------------------------------------

## Instantiates a Unit at the given position, registers it, and returns it.
func spawn_unit(stats: UnitStats, player: Player, spawn_position: Vector3) -> Unit:
	var unit: Unit = UNIT_SCENE.instantiate()
	units_container.add_child(unit)
	unit.global_position = spawn_position
	unit.setup(stats, player)
	unit.died.connect(_on_unit_died)
	unit.damaged.connect(_on_unit_damaged)
	if not _units_by_team.has(player.team_id):
		_units_by_team[player.team_id] = []
	_units_by_team[player.team_id].append(unit)
	_all_units.append(unit)
	return unit


## Every currently-valid unit spawned this battle, alive or (briefly)
## decaying corpses -- SelectionManager's drag-box selection needs to
## test every unit on the field against a screen rect, not just one
## team's roster.
func get_all_units() -> Array[Unit]:
	var units: Array[Unit] = []
	for unit in _all_units:
		if is_instance_valid(unit):
			units.append(unit)
	return units


## Returns the closest living enemy to `unit` that `unit` is actually
## capable of targeting, or null if none remain. Considers every team
## AllianceMatrix.is_hostile() says is hostile to unit's team, not just a
## single binary opponent -- this is what makes FFA/neutral factions work
## without find_nearest_enemy() itself needing to change again. A flying
## enemy is skipped unless unit.stats.can_attack_flying -- see UnitStats.
## Flying units themselves are never restricted; they can target ground.
func find_nearest_enemy(unit: Unit) -> Unit:
	var nearest: Unit = null
	var nearest_distance: float = INF
	for other_team_id in _units_by_team:
		if not alliances.is_hostile(unit.player.team_id, other_team_id):
			continue
		for enemy in _units_by_team[other_team_id]:
			if not is_instance_valid(enemy) or enemy.current_health <= 0.0:
				continue
			if enemy.stats.is_flying and not unit.stats.can_attack_flying:
				continue
			var distance := Unit.horizontal_distance_to(unit.global_position, enemy.global_position)
			if distance < nearest_distance:
				nearest_distance = distance
				nearest = enemy
	return nearest


## Public: GameMode implementations (see GameMode.gd) query rosters
## through this to decide victory, same as GameManager's own lifecycle
## methods do.
func team_is_empty(team_id: int) -> bool:
	return not _units_by_team.has(team_id) or _units_by_team[team_id].is_empty()


## `killer` (the DamageInstance.source of the killing blow) is unused here
## today -- kill attribution now flows end-to-end through the damage
## pipeline, ready for a future bounty/scoring system to read it without
## another plumbing pass.
func _on_unit_died(unit: Unit, _killer: Unit) -> void:
	_units_by_team[unit.player.team_id].erase(unit)

	if not is_battle_active():
		return

	var victory := current_mode.check_victory()
	match victory.get("result", GameMode.VictoryResult.NONE):
		GameMode.VictoryResult.TEAM_WON:
			_end_battle(victory["winning_team_id"])
		GameMode.VictoryResult.DRAW:
			_declare_draw()


func _on_unit_damaged(_unit: Unit, _instance: DamageInstance, _damage_dealt: float) -> void:
	_seconds_since_last_damage = 0.0
