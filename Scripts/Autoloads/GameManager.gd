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
## Fires only for a hero casting its own highest-unlock-level ability
## slot (its "ultimate," Q/E/R's R by this project's own convention) --
## see _on_unit_ability_cast(). Main.gd listens for this to trigger
## camera shake; GameManager itself has no opinion on presentation.
signal hero_ultimate_cast(unit: Unit)
## Fires on every death, win or no killer (see _on_unit_died()) --
## Main.gd listens for this to refresh the gold/blood-points display and
## leaderboard live during a round, not just on the next explicit UI
## action or round transition.
signal unit_killed(unit: Unit, killer: Unit)

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
const CROSS_ARM_HALF_WIDTH := 10.0 ## Half-width of the center square and of every arm's own corridor.
## Distance from the map center to where each arm's corridor ends and its
## (wider) spawn platform begins -- see CROSS_ARM_PLATFORM_HALF_WIDTH/
## CROSS_ARM_PLATFORM_DEPTH right below. Was this map's true outer edge
## before the platform existed; kept as the corridor/platform boundary
## rather than renamed, since several tests and CrossArenaMap's own
## trapezoid transition (see CrossArenaMap.build()) read it as exactly
## that seam.
const CROSS_ARM_OUTER_EXTENT := 40.0

## Half-width of the wider spawn platform at each arm's outer end,
## noticeably wider than the corridor's own CROSS_ARM_HALF_WIDTH.
## CrossArenaMap.build() connects the two via one trapezoid nav-mesh
## polygon per arm (reusing the corridor's own outer corner vertices)
## rather than a hard-edged T-junction, since this project's navmesh
## vertices-shared-by-index stitching convention only guarantees
## connectivity for exactly that shape.
const CROSS_ARM_PLATFORM_HALF_WIDTH := 22.0
## How far beyond CROSS_ARM_OUTER_EXTENT the platform extends.
const CROSS_ARM_PLATFORM_DEPTH := 12.0
## The map's true outer edge now that the platform exists -- used
## wherever CROSS_ARM_OUTER_EXTENT alone used to mark the far boundary
## (Unit._clamp_to_cross_arena(), UI/MiniMap.gd's half-extent).
const CROSS_ARM_PLATFORM_OUTER_EXTENT := CROSS_ARM_OUTER_EXTENT + CROSS_ARM_PLATFORM_DEPTH

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
##
## sync_courtyard_to_roster() runs here, for every registered player,
## before the state transition -- the one call site every path (the real
## Start Battle button via BloodTournamentController.start_battle_pressed(),
## a test calling this directly, a future caller) always goes through, so
## it's the right place for the final safety net that makes Player.roster
## the durable truth regardless of how it got mutated (a human/AI buy
## already synced immediately for visual feedback, but plenty of existing
## tests set player.roster directly without ever calling
## buy_roster_slot()). Harmless to call for every player in every mode --
## a roster that's stayed empty the whole time (classic mode, always) is
## just a no-op.
func start_battle() -> void:
	if not can_start_battle():
		return
	for player in players.values():
		sync_courtyard_to_roster(player)
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


## BATTLE -> GAME_OVER, no winner. Only route in: _physics_process()'s
## stalemate timer, when STALEMATE_TIMEOUT elapses with no damage dealt
## anywhere on the field (see the constant's doc comment).
func _declare_draw() -> void:
	if not is_battle_active():
		return
	_transition_to(BattleState.GAME_OVER)
	current_mode.on_battle_ended(BLUE_TEAM_ID, true)
	battle_ended.emit(BLUE_TEAM_ID, true)


## _physics_process(), not _process() -- a real determinism gap on a
## variable-frame-rate _process() delta (two runs of an identical match at
## different frame rates would cross STALEMATE_TIMEOUT on different real-
## world ticks, unreproducible for a future replay/networked peer).
## _physics_process()'s delta is fixed (Godot's default 60Hz, no
## project.godot override), so this is deterministic per simulated tick.
func _physics_process(delta: float) -> void:
	if not is_battle_active():
		return
	_seconds_since_last_damage += delta
	if _seconds_since_last_damage >= STALEMATE_TIMEOUT:
		_declare_draw()


## PLACEMENT, BATTLE, or GAME_OVER -> PLACEMENT. Frees every unit still in
## the arena, dead or alive, so the lifecycle state and the actual
## battlefield can never disagree about whether a battle is in progress.
##
## Deliberately does NOT touch Player.roster (or roster_squad_ids/
## roster_upgrades/archetype_upgrades/hero_progress/...) -- no
## survivor-carryover here (an earlier version of this method had one),
## but Blood Tournament doesn't have permadeath either: what persists
## between rounds is each Player's `roster` (purchased archetypes, data),
## not literal surviving Unit nodes. sync_courtyard_to_roster() is what
## respawns a round's full roster fresh into each team's lineup courtyard
## after this runs. This is exactly right for a real match's between-round
## transition, but it means calling ONLY this (not
## Player.reset_for_new_match()) between separate tests/matches leaves a
## stale roster sitting on a persistent Player object -- see that
## method's own doc comment for the bug shape this caused.
##
## DOES clear every registered Player's `courtyard_units` -- those live
## Unit references are among what the sweep above just freed, so leaving
## the array itself non-empty would make sync_courtyard_to_roster() wrongly
## believe those slots are already populated (it only fills slots the
## array doesn't yet have an entry for) and skip respawning them entirely.
func reset_battle() -> void:
	for unit in _all_units:
		if is_instance_valid(unit):
			unit.queue_free()

	_all_units.clear()
	_units_by_team.clear()
	for player in players.values():
		player.courtyard_units.clear()

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
	# Not `return range(TEAM_COUNT)` -- range() returns a plain untyped
	# Array, and Godot's return-type coercion for that into Array[int] is
	# inconsistent between call sites (see this session's several other
	# instances of the same underlying quirk) -- most callers just
	# `for team_id in GameManager.all_team_ids():`, which tolerates an
	# untyped runtime Array fine, but the first caller to actually
	# `var x := GameManager.all_team_ids()` and rely on real Array[int]
	# semantics hit a hard runtime error ("Trying to assign an array of
	# type Array to a variable of type Array[int]"). Building the array
	# explicitly, element by element, is the one pattern that's reliably
	# produced a genuinely-typed Array[int] everywhere else this session.
	var ids: Array[int] = []
	for i in range(TEAM_COUNT):
		ids.append(i)
	return ids


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

## Instantiates a Unit at the given position, registers it, and returns
## it. Under an auto-battle mode (GameMode.is_auto_battle()), a unit
## spawned mid-BATTLE (a goblin boss round or bracket matchup deploying
## directly via spawn_squad() -- normal Blood Tournament combat units
## don't take this branch at all anymore, since they're spawned into a
## team's lineup courtyard during PLACEMENT via sync_courtyard_to_roster(),
## then just repositioned+reordered at battle start by
## BloodTournamentController.begin_march(), never re-spawned) gets an
## immediate ATTACK_MOVE order toward the arena center: with no player
## able to issue manual orders
## during auto-battle (see Main._try_cast_or_target()/_on_right_click()),
## nothing would otherwise make it converge on/engage the enemy at all --
## default autonomous AI only reacts to what's already within
## acquisition_range, it doesn't march toward a distant fight on its own.
## ATTACK_MOVE (not plain MOVE) so it still fights anything encountered
## along the way, not just once it arrives.
func spawn_unit(stats: UnitStats, player: Player, spawn_position: Vector3) -> Unit:
	var unit: Unit = UNIT_SCENE.instantiate()
	units_container.add_child(unit)
	unit.global_position = spawn_position
	unit.setup(stats, player)
	unit.net_id = _next_unit_net_id
	_next_unit_net_id += 1
	_units_by_net_id[unit.net_id] = unit
	unit.died.connect(_on_unit_died)
	unit.damaged.connect(_on_unit_damaged)
	unit.ability_cast_used.connect(_on_unit_ability_cast)
	if not _units_by_team.has(player.team_id):
		_units_by_team[player.team_id] = []
	_units_by_team[player.team_id].append(unit)
	_all_units.append(unit)
	if is_battle_active() and current_mode.is_auto_battle():
		unit.order_attack_move(Vector3.ZERO)
	return unit


var _next_unit_net_id: int = 0
var _units_by_net_id: Dictionary = {} # net_id: int -> Unit

## Resolves a Command's (Scripts/Core/Command.gd) net_id payload back to a
## live Unit -- -1 (Command's own "no unit" sentinel) or a stale id both
## return null. Lazily self-cleaning (erases a stale entry the first time
## it's looked up) rather than proactively erased at every one of the
## several places a Unit gets removed from _all_units/_units_by_team --
## matches get_all_units()'s own already-established
## lazy-validity-filter convention instead of adding yet another manual
## cleanup site.
func get_unit_by_net_id(net_id: int) -> Unit:
	if net_id == -1 or not _units_by_net_id.has(net_id):
		return null
	var unit: Unit = _units_by_net_id[net_id]
	if not is_instance_valid(unit):
		_units_by_net_id.erase(net_id)
		return null
	return unit


## Spawns a permanent, non-combat courtyard fixture (Blood Tournament's
## Builder NPC -- Resources/Units/BuilderStats.tres) -- deliberately NOT
## the same as spawn_unit() above: no _units_by_team/_all_units
## registration, no died/damaged signal connections. This is load-bearing,
## not an oversight -- a Builder must survive every reset_battle() call
## (created once per team for the whole match, in
## BloodTournamentMode.on_activated(), not respawned each round) and must
## never count toward BloodTournamentMode.check_victory()'s
## GameManager.team_is_empty() check, which a normal spawn_unit() Unit
## sitting in _units_by_team forever would silently break (a team would
## never read as eliminated). Verified every get_all_units()/_units_by_team
## consumer (aura/AoE sweeps, camera hero-follow, drag-select, exact
## squad-size-sum test assertions) is correctly indifferent to -- or
## actively depends on -- the Builder being uncounted.
func spawn_courtyard_fixture(stats: UnitStats, player: Player, spawn_position: Vector3) -> Unit:
	var unit: Unit = UNIT_SCENE.instantiate()
	units_container.add_child(unit)
	unit.global_position = spawn_position
	unit.setup(stats, player)
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
	for i in stats.squad_size:
		squad.append(spawn_unit(stats, player, anchor_position + _squad_formation_offset(stats, i)))
	return squad


## Member i's offset from a squad's anchor -- a fixed world-X row, spread
## by collision_radius so members don't land stacked. Shared by
## spawn_squad() and reposition_courtyard_squad() below (dragging a
## courtyard squad to a new spot reforms it the same way it was
## originally spawned).
func _squad_formation_offset(stats: UnitStats, i: int) -> Vector3:
	var spacing := stats.collision_radius * 2.5 + 0.3
	return Vector3((i - (stats.squad_size - 1) * 0.5) * spacing, 0, 0)


## Moves every live member of player.courtyard_units[squad_index] to
## reform around new_center -- used both to commit a courtyard
## drag-to-reorder (PlayerInputController._resolve_courtyard_drag()) and,
## called with the squad's pre-drag center, to revert an invalid drop.
## Member 0 (the only one actually visible -- see Unit.set_courtyard_visible())
## is snapped exactly onto new_center afterward rather than left at its
## own _squad_formation_offset() position, same reasoning
## _spawn_roster_squad_at()'s own doc comment covers in full: that offset
## is zero-mean across the whole squad, not zero at index 0, so a
## squad_size > 1 drag would otherwise visibly drop the unit somewhere
## other than where the player actually released it.
func reposition_courtyard_squad(player: Player, squad_index: int, new_center: Vector3) -> void:
	var squad: Array = player.courtyard_units[squad_index]
	var stats: UnitStats = player.roster[squad_index]
	for i in squad.size():
		var unit = squad[i]
		if is_instance_valid(unit):
			unit.global_position = new_center + _squad_formation_offset(stats, i)
	if not squad.is_empty() and is_instance_valid(squad[0]):
		squad[0].global_position = new_center


## Keeps Player.roster's order matching the courtyard's visual
## front-to-back arrangement after a drag -- purely organizational,
## battle deployment is simultaneous so roster order has no mechanical
## effect. Ranks each slot by its squad's centroid projected onto
## CrossArenaMap.get_courtyard_inward_direction() (closer to the
## arm/front sorts first), tie-broken by current index so slots that
## haven't been dragged (e.g. several spawned at the same default
## anchor by sync_courtyard_to_roster()) never visibly reshuffle on
## their own -- Array.sort_custom() isn't guaranteed stable. Rebuilds
## both roster and courtyard_units from the same sorted index list in
## one pass so they stay index-paired atomically.
func reorder_roster_by_courtyard_depth(player: Player) -> void:
	if player.roster.size() <= 1:
		return
	var inward := CrossArenaMap.get_courtyard_inward_direction(player.team_id)
	var indices := range(player.roster.size())
	indices.sort_custom(func(a, b):
		var proj_a := Vector2(_squad_centroid(player.courtyard_units[a]).x, _squad_centroid(player.courtyard_units[a]).z).dot(inward)
		var proj_b := Vector2(_squad_centroid(player.courtyard_units[b]).x, _squad_centroid(player.courtyard_units[b]).z).dot(inward)
		if proj_a == proj_b:
			return a < b
		return proj_a > proj_b
	)
	var new_roster: Array[UnitStats] = []
	var new_courtyard_units: Array = []
	var new_squad_ids: Array[int] = []
	for i in indices:
		new_roster.append(player.roster[i])
		new_courtyard_units.append(player.courtyard_units[i])
		new_squad_ids.append(player.roster_squad_ids[i])
	player.roster = new_roster
	player.courtyard_units = new_courtyard_units
	player.roster_squad_ids = new_squad_ids


## Squad member 0's own position -- the only member ever actually visible
## in the courtyard (Unit.set_courtyard_visible()) and the one
## _spawn_roster_squad_at()/reposition_courtyard_squad() both pin exactly
## onto their anchor point, so this IS the anchor, not an approximation
## of it. Used to be an average across every live member instead
## (relying on _squad_formation_offset()'s offsets being zero-mean to
## recover the anchor) -- that broke the instant squad[0] started getting
## pinned to the exact click/drop point while members 1..N-1 stayed at
## their own (still zero-mean-around-the-*old*-anchor) offsets: the
## courtyard's own "inward" direction turned out to share a real X
## component with the formation spread axis, not be orthogonal to it as
## first assumed, so the mismatch skewed depth-sort comparisons enough to
## flip which of two squads counted as "more forward" (caught by
## test_lineup_courtyard.gd, not just reasoned through). Member 1..N-1's
## own positions are otherwise fully vestigial now -- invisible, non-
## colliding, and unconditionally overwritten fresh by
## BloodTournamentController.begin_march() the moment they matter again --
## so there's no reason to keep averaging them in at all.
func _squad_centroid(squad: Array) -> Vector3:
	if squad.is_empty() or not is_instance_valid(squad[0]):
		return Vector3.ZERO
	return squad[0].global_position


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


## The "line-up" half of selling, for the lineup-courtyard model: a
## roster slot is now a real, potentially multi-unit squad standing in
## the courtyard (Player.courtyard_units[index]), not just a data entry,
## so this frees every unit in that squad -- not only whichever one was
## actually clicked (see PlayerInputController.try_sell_unit_at()'s own
## courtyard branch) -- alongside removing the data entries. Mirrors
## sell_unit()'s own _units_by_team/_all_units bookkeeping per unit freed.
## PLACEMENT-only, same reasoning as sell_unit(). Returns whether it
## actually removed something, so a caller can tell a no-op (bad index,
## wrong phase) from a real sale.
func sell_roster_slot(player: Player, index: int) -> bool:
	if not is_placement_phase() or index < 0 or index >= player.roster.size():
		return false
	var stats: UnitStats = player.roster[index]
	player.roster.remove_at(index)
	if index < player.roster_squad_ids.size():
		player.archetype_upgrades.erase(player.roster_squad_ids[index])
		player.roster_squad_ids.remove_at(index)
	if index < player.courtyard_units.size():
		var squad: Array = player.courtyard_units[index]
		for unit in squad:
			if is_instance_valid(unit):
				_units_by_team[unit.player.team_id].erase(unit)
				_all_units.erase(unit)
				unit.queue_free()
		player.courtyard_units.remove_at(index)
	if current_mode.uses_economy():
		player.add_gold(int(stats.cost * SELL_REFUND_FRACTION))
	return true


## Single gate both the human buy flow (PlayerInputController.begin_build_placement()/
## resolve_build_placement(), via buy_roster_slot_at() below) and the AI
## (AIController.take_turn()) go through -- mirrors
## buy_roster_upgrade()'s existing shape. Only the data/ledger side
## (afford-check, spend, append) -- sync_courtyard_to_roster() below is
## what actually realizes the new slot as a live squad standing in the
## courtyard; kept separate rather than folded in here so a caller could
## batch several buys before syncing once (today's two callers each sync
## immediately after, for responsive visual feedback).
func buy_roster_slot(player: Player, stats: UnitStats) -> bool:
	if not player.can_afford(stats.cost):
		return false
	player.spend(stats.cost)
	player.roster.append(stats)
	player.roster_squad_ids.append(player.next_squad_id())
	return true


## Makes Player.roster the durable source of truth and Player.courtyard_units
## a derived cache that's always correct by the time it's actually read --
## called after a successful buy/sell (immediate visual feedback), once
## per team right after reset_battle() at round start (which already
## clears courtyard_units itself -- see its own doc comment for why), and
## again as a final safety net right before start_battle_pressed()
## actually flips battle_state. That last call is what keeps every
## existing test that sets player.roster directly (the dominant
## test-setup idiom in this codebase) working unmodified, without
## courtyard_units needing to be hand-maintained at every possible
## roster-mutation call site.
func sync_courtyard_to_roster(player: Player) -> void:
	# Keeps roster_squad_ids index-aligned with roster regardless of how
	# roster got mutated -- the dominant test-setup idiom in this codebase
	# sets player.roster directly, bypassing buy_roster_slot() (the only
	# other place a squad_id is normally assigned), so this backfill is
	# what lets buy_archetype_upgrade() work against those tests unchanged,
	# the same "durable safety net" role this method already plays for
	# courtyard_units below.
	while player.roster_squad_ids.size() > player.roster.size():
		player.roster_squad_ids.pop_back()
	while player.roster_squad_ids.size() < player.roster.size():
		player.roster_squad_ids.append(player.next_squad_id())

	while player.courtyard_units.size() > player.roster.size():
		var extra: Array = player.courtyard_units.pop_back()
		for unit in extra:
			if is_instance_valid(unit):
				_units_by_team[unit.player.team_id].erase(unit)
				_all_units.erase(unit)
				unit.queue_free()

	for i in range(player.courtyard_units.size(), player.roster.size()):
		var stats: UnitStats = player.roster[i]
		_spawn_roster_squad_at(player, stats, player.roster_squad_ids[i], CrossArenaMap.get_courtyard_unit_anchor(player.team_id, i))


## The full ordered list of UnitStats one roster slot for `base_stats`
## actually deploys as, once the upgrades bought specifically for
## `squad_id` (see Player.archetype_upgrades) are folded in --
## base_stats.squad_size copies of base_stats, plus each upgrade's
## extra_base_units (more of the same archetype) and
## bonus_unit_stats/bonus_unit_count (a different unit type entirely). A
## squad with no archetype upgrades of its own gets exactly
## base_stats.squad_size copies back -- today's pre-upgrade behavior,
## unchanged. Pure lookup; spawns nothing itself.
func _expanded_squad_composition(base_stats: UnitStats, squad_upgrades: Array) -> Array[UnitStats]:
	var composition: Array[UnitStats] = []
	for i in base_stats.squad_size:
		composition.append(base_stats)
	for upgrade in squad_upgrades:
		for i in upgrade.extra_base_units:
			composition.append(base_stats)
		if upgrade.bonus_unit_stats != null:
			for i in upgrade.bonus_unit_count:
				composition.append(upgrade.bonus_unit_stats)
	return composition


## Spawns one roster slot's squad at `position`, applying every
## account-wide roster upgrade, `squad_id`'s own ArchetypeUpgrade
## purchases (squad composition + granted aura -- see
## Player.archetype_upgrades' own doc comment for why per-squad, not
## per-archetype), and restoring hero progress -- the shared per-slot
## body sync_courtyard_to_roster()'s loop above and buy_roster_slot_at()
## below both use, so the two call sites (default courtyard anchor vs. a
## player-chosen ghost-placement point) can't silently drift apart on
## what "realizing a roster slot" actually means.
func _spawn_roster_squad_at(player: Player, stats: UnitStats, squad_id: int, position: Vector3) -> void:
	var squad_upgrades: Array = player.archetype_upgrades.get(squad_id, [])
	var composition := _expanded_squad_composition(stats, squad_upgrades)
	var squad: Array[Unit] = []
	for i in composition.size():
		var member_stats: UnitStats = composition[i]
		var offset := Vector3((i - (composition.size() - 1) * 0.5) * (member_stats.collision_radius * 2.5 + 0.3), 0, 0)
		squad.append(spawn_unit(member_stats, player, position + offset))

	for upgrade in player.roster_upgrades:
		if upgrade.heroes_only and not stats.is_hero:
			continue
		for unit in squad:
			upgrade.ability.cast_unit_target(unit, unit)
	for upgrade in squad_upgrades:
		if upgrade.aura_ability != null:
			for unit in squad:
				unit.granted_aura_ability = upgrade.aura_ability
	if stats.is_hero and player.hero_progress.has(stats):
		var saved: Dictionary = player.hero_progress[stats]
		for unit in squad:
			if unit.stats.is_hero:
				unit.restore_hero_progress(saved.level, saved.xp)
	# Only the squad's first member is actually shown in the courtyard --
	# see Unit.set_courtyard_visible()'s own doc comment. squad[0]'s own
	# spawn position came from the same per-member offset formula
	# _squad_formation_offset() uses, which is zero-mean around `position`
	# but not zero at index 0 for composition.size() > 1 -- snap it back
	# onto `position` explicitly so a multi-member squad's one visible
	# unit lands exactly where the player clicked. Members 1..N-1 are
	# left at their own offset positions, which doesn't matter since
	# they're invisible/non-colliding and get overwritten fresh by
	# begin_march() once revealed for battle.
	squad[0].global_position = position
	for i in range(1, squad.size()):
		squad[i].set_courtyard_visible(false)
	player.courtyard_units.append(squad)


## The ghost-placement confirm path (PlayerInputController.resolve_build_placement()) --
## buys the slot (same GameManager.buy_roster_slot() gate the human
## click-a-build-menu-button path and the AI both go through) and spawns
## its squad at the player-CHOSEN position instead of the default
## get_courtyard_unit_anchor() sync_courtyard_to_roster() always uses.
## Only ever the newest slot (player.roster.size() - 1 after the buy
## succeeds) -- there's nothing to reconcile here the way
## sync_courtyard_to_roster() does, since a placement click only ever
## concerns the one slot just bought.
func buy_roster_slot_at(player: Player, stats: UnitStats, position: Vector3) -> bool:
	if not buy_roster_slot(player, stats):
		return false
	_spawn_roster_squad_at(player, stats, player.roster_squad_ids[-1], position)
	return true


## Frees every Unit currently in player.courtyard_units without touching
## player.roster itself. GoblinBossRound/FinalTournamentBracket deploy a
## team's roster directly via spawn_squad() at their own bespoke anchors,
## bypassing the courtyard/march flow entirely -- but both also call
## GameManager.start_battle() first (to get the auto-battle convergence
## order flowing before anyone spawns), which runs
## sync_courtyard_to_roster() for every registered player as its own
## safety net. Without this, that safety net would realize a normal
## courtyard squad for the SAME roster right before the boss-round/bracket
## code spawns a second, separate combat squad -- a real double-spawn, not
## just a stale-looking duplicate. Both callers use this immediately after
## start_battle(), before their own direct spawn_squad() loop.
func clear_courtyard_units(player: Player) -> void:
	for squad in player.courtyard_units:
		for unit in squad:
			if is_instance_valid(unit):
				_units_by_team[unit.player.team_id].erase(unit)
				_all_units.erase(unit)
				unit.queue_free()
	player.courtyard_units.clear()


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


## The account-wide shop upgrade path: spends blood points and records
## the upgrade on Player.roster_upgrades (applied to every FUTURE squad
## sync_courtyard_to_roster() spawns into the courtyard from now on -- not
## scoped to whichever roster slot was selected when it was bought, since
## upgrades were always meant to apply account-wide, not per-unit), plus
## applies it immediately to every unit CURRENTLY standing in the
## courtyard, for visible instant feedback rather than a purchase that
## silently does nothing until the next buy.
func buy_roster_upgrade(player: Player, upgrade: UnitUpgrade) -> bool:
	if not is_placement_phase() or not current_mode.uses_economy():
		return false
	if not player.can_afford_blood_points(upgrade.cost):
		return false

	player.spend_blood_points(upgrade.cost)
	player.roster_upgrades.append(upgrade)
	for i in player.courtyard_units.size():
		if upgrade.heroes_only and not player.roster[i].is_hero:
			continue
		for unit in player.courtyard_units[i]:
			upgrade.ability.cast_unit_target(unit, unit)
	return true


## The per-archetype shop upgrade path (ArchetypeUpgrade -- see its own
## class doc comment): spends blood points and records the purchase
## against ONE specific squad (`squad_id`, see Player.roster_squad_ids),
## not every squad of that archetype the player owns -- a player with two
## Archer squads can upgrade just one of them. Same "already-standing
## squad gets the aura immediately, composition changes wait for the next
## (re)spawn" split pick_hero_ability() documents right below -- growing
## an already-standing squad's member count live is real added complexity
## (spawning the delta into an existing courtyard array, repositioning
## around it) for a purchase-time moment that's already about to be
## superseded by the next round's sync_courtyard_to_roster() anyway; the
## granted aura, by contrast, is just an Effect application, exactly as
## cheap to apply retroactively as buy_roster_upgrade()'s own already
## does. Refuses a duplicate purchase of the same upgrade for the same
## squad outright (no stacking two "extra units" copies onto one squad),
## and refuses a squad_id that isn't currently one of player's own or
## whose archetype doesn't match the upgrade at all.
func buy_archetype_upgrade(player: Player, upgrade: ArchetypeUpgrade, squad_id: int) -> bool:
	if not is_placement_phase() or not current_mode.uses_economy():
		return false
	var index := player.roster_squad_ids.find(squad_id)
	if index == -1 or player.roster[index] != upgrade.archetype:
		return false
	var squad_upgrades: Array = player.archetype_upgrades.get(squad_id, [])
	if squad_upgrades.has(upgrade):
		return false
	if not player.can_afford_blood_points(upgrade.cost):
		return false

	player.spend_blood_points(upgrade.cost)
	squad_upgrades.append(upgrade)
	player.archetype_upgrades[squad_id] = squad_upgrades
	if upgrade.aura_ability != null and index < player.courtyard_units.size():
		for unit in player.courtyard_units[index]:
			unit.granted_aura_ability = upgrade.aura_ability
	return true


## Which squad_id (see Player.roster_squad_ids) `unit` currently belongs
## to, or -1 if it isn't part of any of `player`'s courtyard squads --
## used to scope an archetype-upgrade purchase to the specific squad the
## player has selected (see Main._on_archetype_upgrade_requested()) rather
## than every squad of that archetype.
func find_squad_id_for_unit(player: Player, unit: Unit) -> int:
	for i in player.courtyard_units.size():
		if player.courtyard_units[i].has(unit):
			return player.roster_squad_ids[i]
	return -1


## Records which candidate `player` picked for one of `stats`' drafted
## ability slots (UnitStats.ability_draft_choices) -- see
## Player.hero_ability_picks/Unit._resolve_abilities(). PLACEMENT-only,
## same as every other roster-configuration action (buy_roster_upgrade()
## above) -- a drafted pick only takes effect the next time this
## archetype is (re)spawned, so there's nothing meaningful to change
## mid-battle anyway. Free (no cost) -- drafting isn't a purchase, just a
## choice among what the hero already has.
func pick_hero_ability(player: Player, stats: UnitStats, slot_index: int, chosen_index: int) -> bool:
	if not is_placement_phase():
		return false
	if not player.hero_ability_picks.has(stats):
		player.hero_ability_picks[stats] = {}
	player.hero_ability_picks[stats][slot_index] = chosen_index
	return true


## Which of player.courtyard_units[i] `unit` currently belongs to, -1 if
## none -- the public, GameManager-side twin of what used to be
## PlayerInputController's own private _find_courtyard_slot_index()
## (still there, now delegating here) -- apply_command()'s SELL_UNIT case
## needs the same lookup and can't reach into a per-Main
## PlayerInputController instance.
func find_courtyard_slot_index(player: Player, unit: Unit) -> int:
	for i in player.courtyard_units.size():
		if player.courtyard_units[i].has(unit):
			return i
	return -1


## The single dispatch point every Command (Scripts/Core/Command.gd) --
## human or AI, always via CommandQueue, never called directly -- resolves
## through. Re-validates ownership (unit.player.team_id == command.team_id)
## at apply time rather than trusting whatever checked it at enqueue time,
## the same "don't trust the caller, verify again where it matters"
## posture Command's own doc comment calls out as the point of routing
## through net_id/team_id instead of live object references in the first
## place -- today that's just defense-in-depth against a bug, but it's
## exactly the check a future untrusted remote peer's commands would also
## need. Silently no-ops on a command that no longer resolves (unit died,
## squad sold) between enqueue and apply -- same "stale target, do
## nothing" contract every existing order-issuing path already has.
func apply_command(command: Command) -> void:
	var player := get_player(command.team_id)
	match command.type:
		Command.Type.UNIT_ORDER:
			var unit := get_unit_by_net_id(command.unit_net_id)
			if unit == null or unit.player.team_id != command.team_id:
				return
			match command.order_type:
				Unit.OrderType.MOVE:
					unit.order_move(command.target_position, command.queue)
				Unit.OrderType.ATTACK_MOVE:
					var target := get_unit_by_net_id(command.target_net_id)
					if target != null:
						unit.order_attack_unit(target, command.queue)
					else:
						unit.order_attack_move(command.target_position, command.queue)
				Unit.OrderType.STOP:
					unit.order_stop()
				Unit.OrderType.HOLD:
					unit.order_hold()
				Unit.OrderType.PATROL:
					unit.order_patrol(command.target_position, command.queue)
				Unit.OrderType.FOLLOW:
					var target := get_unit_by_net_id(command.target_net_id)
					if target != null and target != unit:
						unit.order_follow(target, command.queue)

		Command.Type.CAST_ABILITY:
			var unit := get_unit_by_net_id(command.unit_net_id)
			if unit == null or unit.player.team_id != command.team_id:
				return
			if command.ability_index < 0 or command.ability_index >= unit.resolved_abilities.size():
				return
			var ability: Ability = unit.resolved_abilities[command.ability_index]
			if ability == null:
				return
			if ability.cast_type == Ability.CastType.UNIT_TARGET:
				var target := get_unit_by_net_id(command.target_net_id)
				unit.cast_ability(command.ability_index, target if target != null else unit.target_enemy)
			else:
				unit.cast_ability(command.ability_index)

		Command.Type.BUY_ROSTER_SLOT:
			if player == null:
				return
			if command.has_target_position:
				buy_roster_slot_at(player, command.unit_stats, command.target_position)
			elif buy_roster_slot(player, command.unit_stats):
				sync_courtyard_to_roster(player)

		Command.Type.SELL_UNIT:
			var unit := get_unit_by_net_id(command.unit_net_id)
			if unit == null or unit.player.team_id != command.team_id or unit.stats.is_builder:
				return
			if current_mode.uses_economy():
				var index := find_courtyard_slot_index(unit.player, unit)
				if index != -1:
					sell_roster_slot(unit.player, index)
			else:
				unit.player.roster.erase(unit.stats)
				sell_unit(unit)

		Command.Type.BUY_ROSTER_UPGRADE:
			if player != null:
				buy_roster_upgrade(player, command.upgrade as UnitUpgrade)

		Command.Type.BUY_ARCHETYPE_UPGRADE:
			if player != null:
				buy_archetype_upgrade(player, command.upgrade as ArchetypeUpgrade, command.squad_id)

		Command.Type.PICK_HERO_ABILITY:
			if player != null:
				pick_hero_ability(player, command.unit_stats, command.slot_index, command.chosen_index)

		Command.Type.EXCHANGE_CURRENCY:
			if player != null:
				if command.exchange_gold_for_blood:
					player.exchange_gold_for_blood_points()
				else:
					player.exchange_blood_points_for_gold()

		Command.Type.START_BATTLE:
			start_battle()


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


var _cached_alive_units: Array[Unit] = []
var _cached_alive_units_tick: int = -1

## Same living units get_all_units() would return filtered to
## life_state == ALIVE, but computed at most once per physics tick and
## reused by every caller that tick -- Unit._compute_avoidance_velocity()
## calls this once per unit per tick, so without caching, a naive
## get_all_units() rebuild there costs O(units^2) in allocation/validity-
## checking alone, on top of the separation math's own inherent O(n^2)
## neighbor scan (confirmed as a real perf regression via
## tools/benchmark.sh while landing the D1 multiplayer plan's deterministic
## avoidance replacement -- see BattleFoundry-Roadmap.md). Keyed on
## Engine.get_physics_frames() purely as a local "has a tick elapsed since
## I last built this" check -- the actual counter value is never read as
## simulation data, so this doesn't introduce any determinism risk.
func get_alive_units_cached() -> Array[Unit]:
	var tick := Engine.get_physics_frames()
	if tick != _cached_alive_units_tick:
		_cached_alive_units_tick = tick
		_cached_alive_units = get_all_units().filter(func(u: Unit) -> bool: return u.life_state == Unit.LifeState.ALIVE)
		_rebuild_avoidance_grid(_cached_alive_units)
	return _cached_alive_units


## Cell size == Unit._AVOIDANCE_NEIGHBOR_DISTANCE exactly -- the standard
## uniform-grid neighbor-search guarantee (cell_size >= search_radius)
## means anything within neighbor_distance of a unit is guaranteed to sit
## in that unit's own cell or one of its 8 immediate neighbors, never
## farther out. Duplicated as a constant here rather than reading
## Unit._AVOIDANCE_NEIGHBOR_DISTANCE directly so this file doesn't need to
## know Unit's private constants exist -- if that value ever changes, this
## one needs updating alongside it (noted on both).
const _AVOIDANCE_GRID_CELL_SIZE := 6.0
var _avoidance_grid: Dictionary = {} # Vector2i cell -> Array[Unit]

func _rebuild_avoidance_grid(units: Array[Unit]) -> void:
	_avoidance_grid.clear()
	for unit in units:
		var cell := _avoidance_cell(unit.global_position)
		if not _avoidance_grid.has(cell):
			_avoidance_grid[cell] = []
		_avoidance_grid[cell].append(unit)


func _avoidance_cell(position: Vector3) -> Vector2i:
	return Vector2i(floori(position.x / _AVOIDANCE_GRID_CELL_SIZE), floori(position.z / _AVOIDANCE_GRID_CELL_SIZE))


## Every living unit within the 3x3 grid-cell block around `position` --
## a superset of "within _AVOIDANCE_NEIGHBOR_DISTANCE," not an exact
## radius filter (the caller, Unit._compute_avoidance_velocity(), already
## does its own precise distance check on top of this). Only ever probes
## 9 SPECIFIC, directly-computed cell keys, in a fixed dx/dz order --
## never iterates _avoidance_grid's own Dictionary key set, which would
## reintroduce the exact hash-iteration-order nondeterminism risk this
## whole grid exists to stay clear of.
func get_nearby_units_cached(position: Vector3) -> Array[Unit]:
	get_alive_units_cached() # ensures _avoidance_grid is fresh for this tick
	var nearby: Array[Unit] = []
	var center := _avoidance_cell(position)
	for dx in [-1, 0, 1]:
		for dz in [-1, 0, 1]:
			var cell := Vector2i(center.x + dx, center.y + dz)
			if _avoidance_grid.has(cell):
				nearby.append_array(_avoidance_grid[cell])
	return nearby


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
##
## `exclude`, when given, is skipped even if it would otherwise be
## nearest -- used by Unit._update_target()'s own "stuck chase" fallback
## (see Unit._STUCK_CHASE_THRESHOLD's doc comment) to find a *different*
## enemy once the current one has proven unreachable (crowded out by
## allies already occupying every attack_range slot around it), rather
## than this purely-geometric search just handing back the same
## already-crowded target every time.
##
## Still a plain O(n) scan, deliberately -- a spatial-grid version was
## tried and reverted: tools/benchmark.sh showed no measurable
## improvement (the real cost at high unit counts is NavigationAgent3D
## avoidance, not this search) and it introduced a real bug (a
## same-physics-frame spawn-then-query missed the newly spawned unit,
## since the grid snapshot predated it). Don't re-attempt without first
## confirming via tools/benchmark.sh that this scan is actually the bottleneck.
func find_nearest_enemy(unit: Unit, exclude: Unit = null) -> Unit:
	var nearest: Unit = null
	var nearest_distance: float = INF
	for other_team_id in _units_by_team:
		if not alliances.is_hostile(unit.player.team_id, other_team_id):
			continue
		for enemy in _units_by_team[other_team_id]:
			if enemy == exclude:
				continue
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

	unit_killed.emit(unit, killer)
	_spawn_death_escalation(unit)

	if not is_battle_active():
		return

	var victory := current_mode.check_victory()
	match victory.get("result", GameMode.VictoryResult.NONE):
		GameMode.VictoryResult.TEAM_WON:
			_end_battle(victory["winning_team_id"])
		GameMode.VictoryResult.DRAW:
			_declare_draw()


## See UnitStats.revive_as_on_death/split_into_on_death/
## split_into_self_on_death's doc comments -- all null/false for every
## normal archetype, so this is a no-op for the rest of the game. Runs
## unconditionally (not gated on is_battle_active()) since it's replacing
## this specific death, not deciding the battle's outcome.
func _spawn_death_escalation(unit: Unit) -> void:
	if unit.stats.revive_as_on_death != null:
		spawn_unit(unit.stats.revive_as_on_death, unit.player, unit.global_position)
	elif unit.stats.split_into_on_death != null:
		_spawn_split(unit, unit.stats.split_into_on_death)
	elif unit.stats.split_into_self_on_death:
		_spawn_split(unit, unit.stats)


func _spawn_split(unit: Unit, split_stats: UnitStats) -> void:
	var spacing := split_stats.collision_radius * 2.5 + 0.3
	for i in unit.stats.split_count:
		var offset := Vector3((i - (unit.stats.split_count - 1) * 0.5) * spacing, 0, 0)
		spawn_unit(split_stats, unit.player, unit.global_position + offset)


func _on_unit_damaged(_unit: Unit, _instance: DamageInstance, _damage_dealt: float) -> void:
	_seconds_since_last_damage = 0.0


## The "ultimate" slot is whichever index requires the highest hero
## level to unlock, not a hardcoded slot number -- today that's always
## index 2 (R) given HeroStats.tres's [1, 2, 3] unlock levels, but this
## stays correct if a future hero archetype orders its slots differently.
func _on_unit_ability_cast(unit: Unit, index: int) -> void:
	if not unit.stats.is_hero or unit.stats.ability_unlock_levels.is_empty():
		return
	if index == unit.stats.ability_unlock_levels.find(unit.stats.ability_unlock_levels.max()):
		hero_ultimate_cast.emit(unit)
