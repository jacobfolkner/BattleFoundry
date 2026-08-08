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

## Half-width of the default 40x40 flat square ground plane
## (Main._build_square_arena()), used by every mode whose
## GameMode.uses_cross_map() is false (ClassicEliminationMode, and
## everything before this constant had cross-map company) -- Unit can
## clamp itself without duplicating the plane's dimensions.
const ARENA_HALF_EXTENT := 20.0

## The alternate, cross/plus-shaped arena Main.gd also builds up front
## (Main._build_cross_arena()) but leaves disabled/hidden unless the
## active GameMode.uses_cross_map() is true (BloodTournamentMode) --
## Main._sync_arena_shape() is what actually swaps which one is live.
## A square center plus 4 arms of the same width extending outward, one
## per cardinal direction, each hosting 2 team spawn points (see
## Main.ARM_SPAWN_POINTS) -- the 8-team Blood Tournament map. Unit's arena
## clamp (_clamp_to_arena()) branches between this shape's math and the
## plain square's, since a cross isn't a square.
const CROSS_ARM_HALF_WIDTH := 8.0 ## Half-width of the center square and of every arm.
const CROSS_ARM_OUTER_EXTENT := 32.0 ## Distance from the map center to each arm's outer (spawn) edge.

## No damage dealt anywhere on the field for this long during BATTLE means
## neither side can actually reach/hurt the other (e.g. an all-flying vs.
## all-ground-melee composition, or a caster that can't close range --
## see PR #4 review, "stalemate soft-lock"). Ends the battle as a draw
## instead of hanging forever. Comfortably above the longest normal-fight
## resolution time exercised by tests/test_battle_flow.gd (~15s budget).
## A var, not a const, solely so a stalemate test can shrink it instead of
## running real time out to 20s of simulated physics frames.
var STALEMATE_TIMEOUT := 20.0

## team_id for the original two-slot prototype roster -- what
## ClassicEliminationMode's win condition and Main.gd's default selection
## target still use. Hostile to each other by AllianceMatrix's
## FFA-by-default rule, with no ally() call needed. Both are also just
## the first two entries of the full TEAM_COUNT roster below -- kept as
## named constants since so much pre-N-team code (tests included)
## addresses them by name rather than index 0/1.
const BLUE_TEAM_ID := 0
const RED_TEAM_ID := 1

## Every player slot is registered up front regardless of how many a
## given match actually uses -- see _register_default_players(). Matches
## the cross-shaped Blood Tournament map's 4 arms x 2 spawn points each;
## ClassicEliminationMode simply never looks past BLUE_TEAM_ID/RED_TEAM_ID.
const TEAM_COUNT := 8

## A dedicated non-competitive team_id, one past the 8 registered
## competitive teams (all_team_ids() stops at TEAM_COUNT-1, so this never
## collides with a real team) -- owns every unit GoblinBossRound spawns
## during a Blood Tournament boss round. Hostile to every competitive
## team automatically via AllianceMatrix's existing FFA-by-default rule;
## needs no special hostility logic of its own. Deliberately excluded
## from all_team_ids() so win-condition/income loops never see it.
const GOBLIN_TEAM_ID := TEAM_COUNT

## player_id (int) -> Player. Seeded once at startup with the full
## TEAM_COUNT roster -- see _register_default_players().
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
## PLACEMENT, and current_mode.can_start_battle() (default: both
## BLUE_TEAM_ID/RED_TEAM_ID have a unit; BloodTournamentMode overrides
## this to "at least 2 of the N registered teams have a unit" -- see
## GameMode.can_start_battle()). Split out from start_battle() so callers
## (a Start Battle button, tests, a future Countdown state) can check
## eligibility without attempting a transition that might silently no-op.
func can_start_battle() -> bool:
	return is_placement_phase() and current_mode.can_start_battle()


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


## PLACEMENT, BATTLE, or GAME_OVER -> PLACEMENT. Frees every unit still in
## the arena, dead or alive, and clears both rosters, so the lifecycle
## state and the actual battlefield can never disagree about whether a
## battle is in progress.
##
## No survivor-carryover option here (an earlier version of this method
## had one) -- Blood Tournament doesn't have permadeath: what persists
## between rounds is each Player's `roster` (purchased archetypes, data),
## not literal surviving Unit nodes. Main._advance_to_next_round() is what
## respawns a round's full roster fresh after calling this -- see
## Main._respawn_rosters().
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

const _TEAM_NAMES: Array[String] = ["Blue", "Red", "Green", "Yellow", "Purple", "Orange", "Cyan", "Magenta"]
const _TEAM_COLORS: Array[Color] = [
	Color(0.25, 0.45, 1.0),
	Color(1.0, 0.25, 0.25),
	Color(0.25, 0.85, 0.35),
	Color(0.95, 0.85, 0.2),
	Color(0.65, 0.3, 0.9),
	Color(1.0, 0.55, 0.15),
	Color(0.2, 0.85, 0.85),
	Color(0.95, 0.35, 0.75),
]

## Seeds the full TEAM_COUNT roster -- player.id == player.team_id == slot
## for every one, since this prototype is strictly one player per team; a
## real lobby replaces this method, not the Player/team_id split it
## produces. Index 0/1 are named Blue/Red for backward compatibility with
## everything (ClassicEliminationMode included) that only ever knew about
## two teams; indices 2-7 exist so BloodTournamentMode's 8-team cross map
## has a full roster to draw from without this method needing to change
## again depending on how many teams a given match actually uses.
func _register_default_players() -> void:
	for team_id in range(TEAM_COUNT):
		var player := Player.new(team_id, team_id, team_id, _TEAM_NAMES[team_id], _TEAM_COLORS[team_id])
		players[player.id] = player
	players[GOBLIN_TEAM_ID] = Player.new(GOBLIN_TEAM_ID, GOBLIN_TEAM_ID, GOBLIN_TEAM_ID, "Goblins", Color(0.35, 0.55, 0.15))


func get_player(player_id: int) -> Player:
	return players.get(player_id)


## Every registered team_id (always 0..TEAM_COUNT-1 in this prototype's
## one-player-per-team model) -- BloodTournamentMode's N-team win
## condition/income loops walk this instead of hardcoding which teams
## exist.
func all_team_ids() -> Array[int]:
	return range(TEAM_COUNT)


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


## Spawns stats.squad_size Units for one purchased/roster slot, spread
## along X around `anchor_position` so squad members don't land exactly
## stacked on each other -- the shared entry point every "this was
## purchased" call site (Main._try_place_unit()/_respawn_rosters(),
## AIController.take_turn()) uses instead of spawn_unit() directly, so
## squad_size is honored everywhere a roster slot actually deploys, not
## just some of them. Each member is a fully independent Unit -- no
## shared-fate/linkage between squad members, they fight and die on
## their own like any other unit.
func spawn_squad(stats: UnitStats, player: Player, anchor_position: Vector3) -> Array[Unit]:
	var squad: Array[Unit] = []
	var spacing := stats.collision_radius * 2.5 + 0.3
	for i in stats.squad_size:
		var offset := Vector3((i - (stats.squad_size - 1) * 0.5) * spacing, 0, 0)
		squad.append(spawn_unit(stats, player, anchor_position + offset))
	return squad


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


## The "line-up" half of selling, for the literal-staging-area placement
## model: roster entries (Player.roster) aren't spawned as live Units
## until BATTLE start (see Main._begin_staggered_deployment()), so
## there's nothing live to click/right-click during PLACEMENT to sell --
## this removes roster[index] directly instead, refunding the same
## SELL_REFUND_FRACTION as sell_unit(). PLACEMENT-only, same reasoning as
## sell_unit(). Returns whether it actually removed something, so a
## caller can tell a no-op (bad index, wrong phase) from a real sale.
func sell_roster_slot(player: Player, index: int) -> bool:
	if not is_placement_phase() or index < 0 or index >= player.roster.size():
		return false
	var stats: UnitStats = player.roster[index]
	player.roster.remove_at(index)
	if current_mode.uses_economy():
		player.add_gold(int(stats.cost * SELL_REFUND_FRACTION))
	return true


## The "shop" half of Blood Tournament's economy: spends blood points
## (not gold -- earned only from kills, see BloodTournamentMode.on_unit_killed())
## to apply a permanent Effect to an owned, living unit during PLACEMENT --
## reuses Ability.cast_unit_target() (caster == target == `unit`) rather
## than inventing a second way to apply an Effect. Returns whether the
## purchase went through, so a caller (Main.gd's hotkey handler) can tell
## a no-op from a successful buy without duplicating these checks itself.
func buy_upgrade(unit: Unit, upgrade: UnitUpgrade) -> bool:
	if not is_instance_valid(unit) or unit.life_state != Unit.LifeState.ALIVE:
		return false
	if not is_placement_phase() or not current_mode.uses_economy():
		return false
	if not unit.player.can_afford_blood_points(upgrade.cost):
		return false

	unit.player.spend_blood_points(upgrade.cost)
	upgrade.ability.cast_unit_target(unit, unit)
	return true


## The actual PLACEMENT-time shop purchase path under the staging-area
## deployment model (see Main._begin_staggered_deployment()) -- nothing
## is a living Unit during PLACEMENT for buy_upgrade() above to target
## anymore, so this spends blood points against the player's account and
## records the upgrade on Player.roster_upgrades instead of applying it
## immediately. Main._deploy_next_pending_slot() applies every recorded
## upgrade to every unit in every squad this player deploys from then on
## -- account-wide, not scoped to whichever roster slot was selected when
## it was bought, since nothing exists yet to scope it to.
func buy_roster_upgrade(player: Player, upgrade: UnitUpgrade) -> bool:
	if not is_placement_phase() or not current_mode.uses_economy():
		return false
	if not player.can_afford_blood_points(upgrade.cost):
		return false

	player.spend_blood_points(upgrade.cost)
	player.roster_upgrades.append(upgrade)
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
		current_mode.on_unit_killed(killer)

	_spawn_death_escalation(unit)

	if not is_battle_active():
		return

	var victory := current_mode.check_victory()
	match victory.get("result", GameMode.VictoryResult.NONE):
		GameMode.VictoryResult.TEAM_WON:
			_end_battle(victory["winning_team_id"])
		GameMode.VictoryResult.DRAW:
			_declare_draw()


## See UnitStats.revive_as_on_death/split_into_on_death's doc comments --
## both null for every normal archetype, so this is a no-op for the rest
## of the game. Runs unconditionally (not gated on is_battle_active())
## since it's replacing this specific death, not deciding the battle's
## outcome.
func _spawn_death_escalation(unit: Unit) -> void:
	if unit.stats.revive_as_on_death != null:
		spawn_unit(unit.stats.revive_as_on_death, unit.player, unit.global_position)
	elif unit.stats.split_into_on_death != null:
		var spacing := unit.stats.split_into_on_death.collision_radius * 2.5 + 0.3
		for i in unit.stats.split_count:
			var offset := Vector3((i - (unit.stats.split_count - 1) * 0.5) * spacing, 0, 0)
			spawn_unit(unit.stats.split_into_on_death, unit.player, unit.global_position + offset)


func _on_unit_damaged(_unit: Unit, _instance: DamageInstance, _damage_dealt: float) -> void:
	_seconds_since_last_damage = 0.0
