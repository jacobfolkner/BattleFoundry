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
	mode.on_activated()


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


## PLACEMENT, BATTLE, or GAME_OVER -> PLACEMENT. Frees units still in the
## arena and clears both rosters, so the lifecycle state and the actual
## battlefield can never disagree about whether a battle is in progress.
##
## `preserve_survivors`: when true, any unit still alive (Unit.LifeState.ALIVE
## -- a decaying corpse doesn't count) is kept instead of freed, and re-seeded
## into its team's roster so can_start_battle()/team_is_empty() see it
## immediately. This is Blood Tournament's roster-carryover mechanic
## (Main._advance_to_next_round() is the only caller that passes true) --
## permadeath is the point of that genre, so only *living* units carry over,
## never corpses. Defaults to false so every other caller (set_mode(), tests,
## a plain single-battle reset) keeps the original free-everything behavior
## exactly, with no risk of a leftover GameManager.current_mode from an
## earlier call deciding this by accident.
func reset_battle(preserve_survivors: bool = false) -> void:
	var survivors: Array[Unit] = []
	if preserve_survivors:
		for unit in _all_units:
			if is_instance_valid(unit) and unit.life_state == Unit.LifeState.ALIVE:
				survivors.append(unit)

	for unit in _all_units:
		if is_instance_valid(unit) and not survivors.has(unit):
			unit.queue_free()

	_all_units = survivors
	_units_by_team.clear()
	for unit in survivors:
		if not _units_by_team.has(unit.player.team_id):
			_units_by_team[unit.player.team_id] = []
		_units_by_team[unit.player.team_id].append(unit)

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


## Fraction of UnitStats.cost refunded by sell_unit() -- only meaningful
## while current_mode.uses_economy() is true.
const SELL_REFUND_FRACTION := 0.5

## Removes `unit` from the arena during PLACEMENT -- undoing a placement
## (a survivor you'd rather not keep, or a fresh unit placed by mistake),
## not something available mid-battle. Refunds SELL_REFUND_FRACTION of its
## cost only if the active mode uses_economy(); the removal itself works
## either way, since "undo my placement" is useful even in a free-to-place
## classic match. No-ops silently for an already-dead/invalid unit or
## outside PLACEMENT, same "an invalid transition simply doesn't happen"
## contract the battle lifecycle methods above use.
func sell_unit(unit: Unit) -> void:
	if not is_instance_valid(unit) or unit.life_state != Unit.LifeState.ALIVE:
		return
	if not is_placement_phase():
		return

	if current_mode.uses_economy():
		unit.player.add_gold(int(unit.stats.cost * SELL_REFUND_FRACTION))

	_units_by_team[unit.player.team_id].erase(unit)
	_all_units.erase(unit)
	unit.queue_free()


## The "shop" half of Blood Tournament's economy (slice 3): spends gold to
## apply a permanent Effect to an owned, living unit during PLACEMENT --
## reuses Ability.cast_unit_target() (caster == target == `unit`) rather
## than inventing a second way to apply an Effect, per the roadmap's own
## "no new framework needed" framing. Returns whether the purchase went
## through, so a caller (Main.gd's hotkey handler) can tell a no-op from a
## successful buy without duplicating these checks itself.
func buy_upgrade(unit: Unit, upgrade: UnitUpgrade) -> bool:
	if not is_instance_valid(unit) or unit.life_state != Unit.LifeState.ALIVE:
		return false
	if not is_placement_phase() or not current_mode.uses_economy():
		return false
	if not unit.player.can_afford(upgrade.cost):
		return false

	unit.player.spend(upgrade.cost)
	upgrade.ability.cast_unit_target(unit, unit)
	return true


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


## Returns the closest living enemy to `unit` within its
## UnitStats.acquisition_range that `unit` is actually capable of
## targeting, or null if none qualify. Considers every team
## AllianceMatrix.is_hostile() says is hostile to unit's team, not just a
## single binary opponent -- this is what makes FFA/neutral factions work
## without find_nearest_enemy() itself needing to change again. A flying
## enemy is skipped unless unit.stats.can_attack_flying -- see UnitStats.
## Flying units themselves are never restricted; they can target ground.
##
## The acquisition_range cap is what fixes the "an idle unit walks across
## the whole arena to fight something far away" rough edge -- previously
## this always returned *some* enemy if one existed anywhere on the field,
## no matter the distance. See Unit._update_target(), the only caller that
## matters for autonomous AI, for the other half of the fix (an
## already-acquired target gets dropped, not chased forever, once it
## drifts out of range too).
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
			if distance > unit.stats.acquisition_range:
				continue
			if distance < nearest_distance:
				nearest_distance = distance
				nearest = enemy
	return nearest


## Public: GameMode implementations (see GameMode.gd) query rosters
## through this to decide victory, same as GameManager's own lifecycle
## methods do.
func team_is_empty(team_id: int) -> bool:
	return not _units_by_team.has(team_id) or _units_by_team[team_id].is_empty()


## `killer` (the DamageInstance.source of the killing blow) is what the
## kill-attribution plumbing threaded through the damage pipeline for --
## Unit.gain_xp() itself no-ops for a non-hero, so this is safe to call
## unconditionally rather than checking killer.stats.is_hero here too.
func _on_unit_died(unit: Unit, killer: Unit) -> void:
	_units_by_team[unit.player.team_id].erase(unit)

	if is_instance_valid(killer):
		killer.gain_xp(Unit.XP_PER_KILL)

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
