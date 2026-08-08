## Root controller for the prototype scene.
##
## Owns the arena (build/toggle only -- the shapes themselves live in
## Scripts/ArenaMap.gd and subclasses) and wires input, HUD, and Blood
## Tournament round orchestration together. Actual input handling is
## Scripts/PlayerInputController.gd's job (_input below) -- this class
## forwards events/calls to it and keeps a handful of same-named
## delegate methods so every existing "private" test call site
## (_main._try_place_unit(), etc.) keeps working unchanged. Main.gd
## otherwise knows nothing about selection bookkeeping, debug UI, or the
## camera (self-managed by Scripts/OrbitCamera.gd) -- that's the whole
## point of routing through those rather than handling it here.
extends Node3D

@onready var _camera: Camera3D = $Camera3D
@onready var _units_container: Node3D = $UnitsContainer
@onready var _hud: Control = $HUDLayer/HUD

## Constructed in _ready() (needs _camera/_hud, which are @onready) --
## owns selected_stats/selected_player/dragging_unit/pending_ability_target,
## which several of Main's own non-input methods (_refresh_gold_display(),
## _on_ai_opponent_toggled(), _apply_menu_selection()) still need to
## read/write -- see the forwarding properties right below this for how
## those keep working without every caller needing an `_input.` prefix.
var _input: PlayerInputController

## Forwarding properties, not plain fields -- selected_stats/dragging_unit/
## pending_ability_target genuinely live on _input now (PlayerInputController.gd),
## but several tests still read/write _main._selected_stats/_dragging_unit/
## _pending_ability_target directly, and Main's own non-input code
## (_refresh_gold_display(), etc.) still reads _selected_player constantly.
## Godot's property syntax lets both keep working unchanged.
var _selected_stats: UnitStats:
	get: return _input.selected_stats
	set(value): _input.selected_stats = value
var _selected_player: Player:
	get: return _input.selected_player
	set(value): _input.selected_player = value
var _dragging_unit: Unit:
	get: return _input.dragging_unit
	set(value): _input.dragging_unit = value
var _pending_ability_target: int:
	get: return _input.pending_ability_target
	set(value): _input.pending_ability_target = value

## Non-null only while the HUD's Blood Tournament toggle is on -- see
## _on_tournament_toggled(). Holding the reference here (not just reading
## it back off GameManager.current_mode) is what lets _on_tournament_round_ended()
## read BloodTournamentMode-specific state (get_wins(), is_match_over())
## without every caller needing to cast/check GameManager.current_mode's type.
var _tournament_mode: BloodTournamentMode = null

var _ai := AIController.new()

## Non-null only while a goblin boss round's team-by-team sequence is
## actually running (see _on_start_battle_pressed()/GoblinBossRound's own
## class doc comment) -- a fresh instance every boss round, discarded once
## boss_round_finished fires.
var _boss_round: GoblinBossRound = null

## Non-null only while the final tournament bracket is actually running
## (see _on_all_rounds_finished()/FinalTournamentBracket's own class doc
## comment) -- one instance for the whole bracket (unlike _boss_round,
## which is one per boss round), discarded once champion_decided fires.
var _bracket: FinalTournamentBracket = null


func _ready() -> void:
	GameManager.units_container = _units_container
	GameManager.battle_ended.connect(_hud.show_winner)
	GameManager.battle_started.connect(_begin_staggered_deployment)
	_input = PlayerInputController.new(_camera, _hud, _refresh_gold_display)
	SelectionManager.local_player = _selected_player # keep in sync with the default team panel toggle
	_build_arenas()

	_hud.unit_type_selected.connect(_on_unit_type_selected)
	_hud.team_selected.connect(_on_team_selected)
	_hud.start_battle_pressed.connect(_on_start_battle_pressed)
	_hud.tournament_mode_toggled.connect(_on_tournament_toggled)
	_hud.ai_opponent_toggled.connect(_on_ai_opponent_toggled)
	_hud.ability_slot_pressed.connect(_try_cast_or_target)
	_hud.roster_slot_sold.connect(_on_roster_slot_sold)
	# HUD only ever displays whichever unit SelectionManager reports as
	# selected -- it never reads SelectionManager itself (see HUD.gd's own
	# doc comment on staying decoupled from selection/battle-lifecycle
	# internals), so this is the one bridge that tells it who to track for
	# the ability hotbar/buff row (UI/HUD.gd's track_unit()).
	SelectionManager.selection_changed.connect(_on_selection_changed)

	_apply_menu_selection()


func _on_selection_changed(units: Array[Unit]) -> void:
	_hud.track_unit(units[0] if not units.is_empty() else null)


## Consumes (and immediately clears) MenuSelection's fields -- UI/MainMenu.gd
## sets these right before changing to this scene. Clearing them here, not
## just reading them, makes this a true one-shot hand-off: if this scene
## is ever entered again without going back through the menu (a GUT test
## loading it directly, almost always), nothing carries over silently --
## MenuSelection is an autoload, so its state would otherwise survive a
## scene change (or a whole test suite run) untouched.
func _apply_menu_selection() -> void:
	var tournament := MenuSelection.start_with_tournament
	var ai_opponent := MenuSelection.start_with_ai_opponent
	var human_team_id := MenuSelection.human_team_id
	var team_count := MenuSelection.team_count
	MenuSelection.start_with_tournament = false
	MenuSelection.start_with_ai_opponent = false
	MenuSelection.human_team_id = GameManager.BLUE_TEAM_ID
	MenuSelection.team_count = GameManager.TEAM_COUNT

	_on_team_selected(human_team_id) # harmless no-op when this is already the default (Blue)

	# AI first: _on_tournament_toggled(true)'s own tail call to
	# _run_ai_turn_if_needed() only does anything once every other team is
	# already non-human, so this order lets round 1 auto-populate
	# immediately rather than needing a second, redundant check.
	#
	# The human's own team plus the next (team_count - 1) registered
	# teams (in team_id order, skipping the human's own) become the
	# active roster for this match -- "2 to 8 teams, fill some or all
	# remaining slots with bots." Left empty (meaning "every registered
	# team," see BloodTournamentMode.active_team_ids' own doc comment)
	# when ai_opponent is off -- team_count is only meaningful alongside
	# it, and every registered team funded/playing is the original,
	# pre-team-count behavior a plain "Blood Tournament: On" with no AI
	# opponent should keep. Every OTHER registered team also becomes
	# AI-controlled when ai_opponent is on (not restricted to just the
	# active set) -- harmless, since an inactive team never gets gold
	# (see BloodTournamentMode.active_team_ids) so AIController.take_turn()
	# just finds nothing affordable and no-ops for it every round.
	# Deliberately doesn't go through HUD.set_ai_toggle()/
	# Main._on_ai_opponent_toggled() -- that's the separate in-match HUD
	# button, still hardcoded to flipping just Red (a known, narrower
	# piece of UI this doesn't touch), not a fit for "N-1 teams become
	# AI" at menu hand-off time.
	var active_team_ids: Array = []
	if ai_opponent:
		active_team_ids = [human_team_id]
		for team_id in GameManager.all_team_ids():
			GameManager.get_player(team_id).is_human = (team_id == human_team_id)
			if team_id != human_team_id and active_team_ids.size() < team_count:
				active_team_ids.append(team_id)
	if tournament:
		# Goes straight to Main._on_tournament_toggled() instead of
		# HUD.set_tournament_toggle() -- that button's own toggled signal
		# only ever carries a bool, no way to also pass active_team_ids
		# through it. sync_tournament_toggle_visual() afterward just
		# matches the button's look to what already happened, without
		# re-running activation a second time.
		_on_tournament_toggled(true, active_team_ids) # its own tail call to _run_ai_turn_if_needed() is what actually runs the AI's first turn
		_hud.sync_tournament_toggle_visual(true)


## Kept for backward compat (AIController and several tests read this
## directly) -- the real source of truth is now CrossArenaMap.SPAWN_POINTS
## (Scripts/CrossArenaMap.gd), referenced here rather than duplicated
## (GDScript resolves another class's const at compile time, same
## pattern MenuSelection.human_team_id's own default already uses for
## GameManager.BLUE_TEAM_ID).
const ARM_SPAWN_POINTS: Array[Vector3] = CrossArenaMap.SPAWN_POINTS

@onready var _ground: Node3D = $Ground
var _square_map := SquareArenaMap.new()
var _cross_map := CrossArenaMap.new()


## Builds both arena maps once up front (ground meshes + navmesh) and
## leaves only the one GameManager.current_mode.get_arena_map() actually
## wants enabled/visible -- see _sync_arena_shape(), the only thing that
## needs to run again on a mode swap. Building both up front (rather than
## freeing and rebuilding nodes on every toggle) means toggling Blood
## Tournament on and off never risks leaking/duplicating navigation
## regions. Hardcodes exactly these two concrete ArenaMap classes here
## (not derived generically from every possible GameMode) since building
## requires real scene-tree parents (this node, _ground) only Main.gd
## has -- a third map shape would need one more line here, still no
## per-shape branching anywhere else (see _sync_arena_shape()).
func _build_arenas() -> void:
	_square_map.build(self, _ground)
	_cross_map.build(self, _ground)
	_sync_arena_shape()


## The only thing that needs to run again after _build_arenas() -- called
## once there, and again from _on_tournament_toggled()/_apply_menu_selection()
## whenever GameManager.current_mode actually changes. Disabling (not
## freeing) the inactive map's NavigationRegion3D fully excludes its
## navmesh from the navigation map, so the two shapes never interfere
## with each other's pathfinding. Matches by the class of whatever
## ArenaMap instance current_mode.get_arena_map() returns -- a throwaway
## instance just for the type check (cheap, RefCounted, never added to
## the scene tree), not the same object _square_map/_cross_map already
## built.
func _sync_arena_shape() -> void:
	var active_map := GameManager.current_mode.get_arena_map()
	_square_map.set_active(active_map is SquareArenaMap)
	_cross_map.set_active(active_map is CrossArenaMap)


## Swaps GameManager.current_mode between ClassicEliminationMode (the
## default single-battle behavior) and a fresh BloodTournamentMode.
## GameManager.set_mode() already resets to PLACEMENT, so this just also
## resyncs the HUD (winner banner/Start button) to match.
##
## active_team_ids (plain Array, see BloodTournamentMode.active_team_ids'
## own doc comment) restricts which of the 8 registered teams actually
## get starting gold -- empty (default) means every registered team,
## unchanged for the in-game HUD toggle's own direct signal connection
## (which only ever passes the bool) and every existing test. Only
## Main._apply_menu_selection() passes a real, possibly-smaller list, for
## the "2 to 8 teams, fill some or all remaining slots with bots" setup
## choice. Must be set on the mode BEFORE GameManager.set_mode() runs --
## that's what triggers on_activated()'s starting-gold grant, which reads
## it.
func _on_tournament_toggled(enabled: bool, active_team_ids: Array = []) -> void:
	if enabled:
		# 12 -- the genre-accurate fixed match length (see
		# BloodTournamentMode.total_rounds' own doc comment): every round
		# is played through regardless of standings, boss rounds included
		# (is_boss_round() lands on 3/6/9/12 either way). rounds_to_win (2)
		# is otherwise unused once total_rounds > 0, kept at its default.
		_tournament_mode = BloodTournamentMode.new(2, 12)
		_tournament_mode.active_team_ids = active_team_ids
		_tournament_mode.round_ended.connect(_on_tournament_round_ended)
		_tournament_mode.all_rounds_finished.connect(_on_all_rounds_finished)
		GameManager.set_mode(_tournament_mode) # grants starting gold via BloodTournamentMode.on_activated()
		_assign_random_spawn_points()
	else:
		_tournament_mode = null
		GameManager.set_mode(ClassicEliminationMode.new())
	_sync_arena_shape()
	_hud.reset_for_new_round()
	_hud.hide_tournament_score()
	_refresh_gold_display()
	_run_ai_turn_if_needed()


## Connected to HUD's Start Battle button instead of GameManager.start_battle()
## directly, so a goblin boss round (BloodTournamentMode.is_boss_round())
## can be intercepted here and handed off to GoblinBossRound's own
## team-by-team sequencing instead of one normal simultaneous PvP battle.
## Every other mode/round just calls GameManager.start_battle() exactly as
## before.
func _on_start_battle_pressed() -> void:
	if _tournament_mode != null and _tournament_mode.is_boss_round():
		_boss_round = GoblinBossRound.new()
		_boss_round.boss_round_finished.connect(_on_boss_round_finished)
		_boss_round.start(_tournament_mode)
	else:
		GameManager.start_battle()


## GoblinBossRound itself never touches round scoring (see its class doc
## comment) -- finish_boss_round() does that once, for the boss round as a
## whole, which in turn emits round_ended and drives the exact same
## _on_tournament_round_ended() -> _advance_to_next_round() path a normal
## PvP round's win already does.
func _on_boss_round_finished() -> void:
	_boss_round = null
	_tournament_mode.finish_boss_round()


## All 12 rounds of the match are done (BloodTournamentMode.all_rounds_finished)
## -- hands off to the bracket-style final tournament that decides an
## overall champion (see FinalTournamentBracket's class doc comment).
func _on_all_rounds_finished() -> void:
	_bracket = FinalTournamentBracket.new()
	_bracket.champion_decided.connect(_on_champion_decided)
	_bracket.start(_tournament_mode)


## Reuses the existing winner-banner UI (is_draw always false -- a
## champion is always a specific team, byes included) rather than
## building dedicated "tournament champion" UI for this stage; a real
## presentation pass is future polish, not part of the mechanic itself.
func _on_champion_decided(team_id: int) -> void:
	_bracket = null
	_hud.show_winner(team_id, false)


## Red's Player.is_human flips to match -- AIController.take_turn() (see
## _run_ai_turn_if_needed()) is the only other thing that ever checks it.
## Forces the human back to Blue if they happened to be playing Red when
## AI takes it over -- HUD._on_ai_toggled() already disabled that button,
## this is the matching GameManager/SelectionManager-side half.
func _on_ai_opponent_toggled(enabled: bool) -> void:
	GameManager.get_player(GameManager.RED_TEAM_ID).is_human = not enabled
	if enabled:
		_selected_player = GameManager.get_player(GameManager.BLUE_TEAM_ID)
		SelectionManager.local_player = _selected_player
	_run_ai_turn_if_needed()


## Called everywhere a fresh PLACEMENT phase begins with Blood Tournament
## gold already settled (toggling the tournament on, toggling the AI on
## mid-match, and every subsequent round) -- see each call site. A no-op
## unless there's an is_human == false player under a mode that actually
## uses_economy(), so calling this speculatively from several places is
## always safe.
func _run_ai_turn_if_needed() -> void:
	if not GameManager.is_placement_phase() or not GameManager.current_mode.uses_economy():
		return
	var any_ai_took_a_turn := false
	for team_id in GameManager.all_team_ids():
		var player := GameManager.get_player(team_id)
		if not player.is_human:
			_ai.take_turn(player)
			any_ai_took_a_turn = true
	if any_ai_took_a_turn:
		_refresh_gold_display()


## Connected to the *current* BloodTournamentMode instance's own signal,
## not something GameManager forwards -- GameManager stays mode-agnostic
## (see GameMode.gd), so mode-specific UI reactions like this one have to
## come from Main.gd holding the mode reference directly.
func _on_tournament_round_ended(round_number: int, _winning_team_id: int, _is_draw: bool) -> void:
	_hud.show_tournament_score(round_number, _scoreboard_text())
	_refresh_gold_display() # round income (BloodTournamentMode.on_battle_ended()) already landed by now
	if not _tournament_mode.is_match_over():
		# Deferred, not called straight from here: this handler runs
		# *during* GameManager._end_battle(), before its own
		# battle_ended.emit() -- resetting synchronously would flip
		# battle_state back to PLACEMENT and hide the winner banner
		# before that emit (and HUD.show_winner()) even runs, then have
		# it clobbered back to visible right after. Deferring lets this
		# round's result display first, uninterrupted.
		call_deferred("_advance_to_next_round")


## "TeamName wins : TeamName wins : ..." sorted by wins descending, only
## for teams that have actually fielded a roster at some point (same
## "who's really playing" filter GoblinBossRound/FinalTournamentBracket
## use) -- BloodTournamentMode.wins_by_team only ever gets a key for a
## team once it's WON a round, so a plain teams_with_units-style sort
## would silently omit anyone still sitting on 0 wins.
func _scoreboard_text() -> String:
	var participants := GameManager.all_team_ids().filter(
		func(team_id: int) -> bool: return not GameManager.get_player(team_id).roster.is_empty()
	)
	participants.sort_custom(func(a: int, b: int) -> bool: return _tournament_mode.get_wins(a) > _tournament_mode.get_wins(b))

	var parts: Array[String] = []
	for team_id in participants:
		parts.append("%s %d" % [GameManager.get_team_display_name(team_id), _tournament_mode.get_wins(team_id)])
	return " : ".join(parts)


func _advance_to_next_round() -> void:
	GameManager.reset_battle() # no permadeath -- every unit is freed; roster entries stay data-only until the next battle's staggered deployment
	_hud.reset_for_new_round()
	_assign_random_spawn_points()
	_run_ai_turn_if_needed()


## Seconds between one roster slot's squad marching out and the next --
## not a balance number, just enough to actually read as a staggered
## arrival rather than everyone appearing on the same frame.
const _DEPLOY_INTERVAL := 1.0

## Player.id -> Array[UnitStats], the still-to-deploy remainder of that
## player's roster, reversed (see _begin_staggered_deployment()) so it
## pops right-to-left. Player.id -> float in _deploy_timers is seconds
## remaining until that player's next entry deploys.
var _pending_deployments: Dictionary = {}
var _deploy_timers: Dictionary = {}

## Team_id -> this round's cross-map arm anchor -- confirmed design:
## spawn locations are randomized every round ("to give everyone a fair
## chance"), not a fixed team_id -> arm mapping. Reassigned by
## _assign_random_spawn_points(), called once when Blood Tournament
## activates and again at the start of every subsequent round. Only ever
## read by _deploy_next_pending_slot() below, in place of a direct
## ARM_SPAWN_POINTS[player.team_id] lookup.
var _round_spawn_points: Dictionary = {}


## Shuffles the 8 cross-map arm anchors across GameManager.all_team_ids()
## -- always all 8, regardless of how many teams are actually active
## this match (BloodTournamentMode.active_team_ids); an inactive team's
## assigned anchor is simply never read, since nothing ever deploys for
## it (see _deploy_next_pending_slot()/GoblinBossRound's own separate
## anchors, unaffected -- this only applies to normal PvP round
## deployment).
func _assign_random_spawn_points() -> void:
	var arms := ARM_SPAWN_POINTS.duplicate()
	arms.shuffle()
	_round_spawn_points.clear()
	var team_ids := GameManager.all_team_ids()
	for i in team_ids.size():
		_round_spawn_points[team_ids[i]] = arms[i]


## Literal separate staging area, not an instant respawn: Player.roster
## entries are never spawned as live Units during PLACEMENT (see
## _on_unit_type_selected()/_try_place_unit()) -- they only become real
## Units once BATTLE actually starts, marching out from each player's pen
## one slot at a time. "Rightmost deploys first, leftmost deploys last"
## (per the reference genre) is expressed as *purchase order, reversed*:
## buying appends to the end of Player.roster, so the most recently
## bought slot -- the "rightmost" one in the line-up -- pops first here.
func _begin_staggered_deployment() -> void:
	# A goblin boss round's own controller (GoblinBossRound) deploys just
	# the one team currently taking its turn directly -- the normal
	# every-registered-team staggered flow below would double-deploy that
	# same roster a second time (and also try to deploy every OTHER
	# team's roster, which shouldn't appear during a solo PvE turn at
	# all) if it ran too. Same reasoning for a bracket matchup
	# (FinalTournamentBracket) -- it deploys exactly the two paired teams
	# itself.
	if _tournament_mode != null and (_tournament_mode.current_boss_team_id != -1 or _tournament_mode.in_bracket_match):
		return

	_pending_deployments.clear()
	_deploy_timers.clear()
	for team_id in GameManager.all_team_ids():
		var player := GameManager.get_player(team_id)
		if player.roster.is_empty():
			continue
		var queue := player.roster.duplicate()
		queue.reverse()
		_pending_deployments[player.id] = queue
		_deploy_timers[player.id] = 0.0 # the first slot marches out immediately, not after a full interval's wait


## _physics_process(), not _process() -- matches every other piece of
## game-logic timing in this codebase (HUD's own _process() is the one
## exception, but that's a pure UI refresh, not gameplay timing) and
## guarantees this actually advances during GUT's wait_physics_frames(),
## which is specifically tied to physics frames. Only does anything while
## there's an active staggered deployment queue for at least one player --
## a no-op every other physics frame of the game's life, including all of
## PLACEMENT and any battle with an empty roster (classic mode, always).
func _physics_process(delta: float) -> void:
	if _pending_deployments.is_empty():
		return
	for player_id in _pending_deployments.keys().duplicate(): # duplicated: _deploy_next_pending_slot() below may erase from the dict mid-iteration
		_deploy_timers[player_id] -= delta
		if _deploy_timers[player_id] <= 0.0:
			_deploy_next_pending_slot(player_id)


## Applies every account-wide upgrade the player bought during PLACEMENT
## (see GameManager.buy_roster_upgrade()) to every unit in the squad that
## just deployed -- upgrades were recorded rather than applied at
## purchase time specifically because nothing was alive yet to apply them
## to, so this is where that deferred application actually happens.
func _deploy_next_pending_slot(player_id: int) -> void:
	var queue: Array = _pending_deployments[player_id]
	var stats: UnitStats = queue.pop_front()
	var player := GameManager.get_player(player_id)
	var anchor: Vector3 = _round_spawn_points.get(player.team_id, ARM_SPAWN_POINTS[player.team_id])
	var squad := GameManager.spawn_squad(stats, player, anchor)
	for upgrade in player.roster_upgrades:
		for unit in squad:
			upgrade.ability.cast_unit_target(unit, unit)

	if queue.is_empty():
		_pending_deployments.erase(player_id)
		_deploy_timers.erase(player_id)
	else:
		_deploy_timers[player_id] = _DEPLOY_INTERVAL


## Shows Blue/Red's current gold and blood points whenever
## current_mode.uses_economy() is true, hides it otherwise -- self-deciding
## on every call (rather than the caller tracking on/off) so every
## spend/refund/income/kill call site can just call this without also
## branching on mode type itself.
func _refresh_gold_display() -> void:
	var use_gold := GameManager.current_mode.uses_economy()
	if use_gold:
		var blue := GameManager.get_player(GameManager.BLUE_TEAM_ID)
		var red := GameManager.get_player(GameManager.RED_TEAM_ID)
		_hud.show_gold(blue.resources, red.resources, blue.blood_points, red.blood_points)
		_hud.refresh_roster_row(_selected_player.roster)
	else:
		_hud.hide_gold()
		# _hud is typed as plain Control (see its @onready declaration), so this
		# call dispatches dynamically -- a bare [] literal has no static context
		# to become Array[UnitStats] and fails HUD.refresh_roster_row()'s typed
		# parameter at runtime. A typed local variable carries its own runtime
		# type tag, unlike a fresh [] literal (Player.roster itself doesn't
		# need this -- it's already a real typed-array value, not a literal).
		var empty_roster: Array[UnitStats] = []
		_hud.refresh_roster_row(empty_roster)
	_hud.refresh_affordability(_selected_player)


## Connected to HUD's roster line-up row (see UI/HUD.gd) -- clicking a
## slot there sells it (GameManager.sell_roster_slot()) instead of the
## old right-click-a-live-unit flow (_try_sell_unit_at()), since nothing
## is live to click during PLACEMENT anymore under the staggered-deployment
## model.
func _on_roster_slot_sold(index: int) -> void:
	if GameManager.sell_roster_slot(_selected_player, index):
		_refresh_gold_display()


## Actual input handling lives in Scripts/PlayerInputController.gd (_input)
## -- every method below is a thin one-line delegate, kept under these
## exact names because several test files call them directly
## (_main._try_place_unit(), etc.) and HUD connects a few of them as
## signal handlers (_on_unit_type_selected, _on_team_selected,
## _try_cast_or_target -- see _ready()).
func _unhandled_input(event: InputEvent) -> void:
	_input.handle(event)


func _handle_mouse_button(event: InputEventMouseButton) -> void:
	_input.handle_mouse_button(event)


func _handle_mouse_motion(event: InputEventMouseMotion) -> void:
	_input.handle_mouse_motion(event)


func _on_left_release(event: InputEventMouseButton) -> void:
	_input.on_left_release(event)


func _on_right_click(event: InputEventMouseButton) -> void:
	_input.on_right_click(event)


func _handle_key(event: InputEventKey) -> void:
	_input.handle_key(event)


func _try_cast_or_target(index: int) -> void:
	_input.try_cast_or_target(index)


func _resolve_pending_ability_target(screen_position: Vector2) -> void:
	_input.resolve_pending_ability_target(screen_position)


func _cancel_pending_ability_target() -> void:
	_input.cancel_pending_ability_target()


func _handle_placement_key(event: InputEventKey) -> void:
	_input.handle_placement_key(event)


func _try_start_unit_drag(screen_position: Vector2) -> void:
	_input.try_start_unit_drag(screen_position)


func _drag_unit_to(screen_position: Vector2) -> void:
	_input.drag_unit_to(screen_position)


func _try_place_unit(screen_position: Vector2) -> void:
	_input.try_place_unit(screen_position)


func _try_sell_unit_at(screen_position: Vector2) -> void:
	_input.try_sell_unit_at(screen_position)


func _on_unit_type_selected(stats: UnitStats) -> void:
	_input.on_unit_type_selected(stats)


func _on_team_selected(team_id: int) -> void:
	_input.on_team_selected(team_id)
