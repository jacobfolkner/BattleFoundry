## Owns Blood Tournament's round-to-round orchestration: staggered
## deployment, random per-round spawn points, AI-turn-triggering,
## scoreboard text, and the boss-round/bracket-tournament hand-offs
## (GoblinBossRound/FinalTournamentBracket, both unchanged, still their
## own sibling controllers).
##
## Constructed once, unconditionally, in Main._ready() -- not lazily when
## Blood Tournament activates. This mirrors how Player.roster/
## Player.resources already exist and simply stay unused/inert for a
## classic-mode match: this controller's own state (round_spawn_points,
## the staggered-deployment queues) is exactly the same shape -- always
## present, functionally a no-op whenever GameManager.current_mode
## doesn't populate any Player.roster. Constructing it unconditionally
## (rather than only when the tournament toggle is on) is also what lets
## several tests poke round_spawn_points/mode directly without going
## through the normal activation flow at all -- see their own comments
## below for exactly which fields that applies to.
##
## `mode` is null until Main._on_tournament_toggled(true) sets it (via
## Main._tournament_mode's forwarding property -- see Main.gd) -- several
## tests set that field directly, bypassing activation entirely, so
## everything here has to tolerate mode being assigned (or read) at any
## time, not just right after a real activation.
##
## refresh_gold_display is a Callable, not a Main reference, matching the
## same narrow-interface shape PlayerInputController.gd already
## established for the identical need.
class_name BloodTournamentController
extends RefCounted

## Seconds between one roster slot's squad marching out and the next --
## not a balance number, just enough to actually read as a staggered
## arrival rather than everyone appearing on the same frame.
const _DEPLOY_INTERVAL := 1.0

var _hud: Control
var _ai := AIController.new()
var _refresh_gold_display: Callable

var mode: BloodTournamentMode = null

## Non-null only while a goblin boss round's team-by-team sequence is
## actually running -- a fresh instance every boss round, discarded once
## boss_round_finished fires.
var _boss_round: GoblinBossRound = null
## Non-null only while the final tournament bracket is actually running
## -- one instance for the whole bracket (unlike _boss_round, which is
## one per boss round), discarded once champion_decided fires.
var _bracket: FinalTournamentBracket = null

## Player.id -> Array[UnitStats], the still-to-deploy remainder of that
## player's roster, reversed (see begin_staggered_deployment()) so it
## pops right-to-left. Player.id -> float in _deploy_timers is seconds
## remaining until that player's next entry deploys.
var _pending_deployments: Dictionary = {}
var _deploy_timers: Dictionary = {}

## Team_id -> this round's cross-map arm anchor -- confirmed design:
## spawn locations are randomized every round ("to give everyone a fair
## chance"), not a fixed team_id -> arm mapping. Reassigned by
## assign_random_spawn_points(), called once when Blood Tournament
## activates and again at the start of every subsequent round. Not
## private (no leading underscore, and a plain field, not wrapped in a
## forwarding property here) -- Main._round_spawn_points forwards to
## this directly, and a couple of tests read/write it before any
## activation has happened at all.
var round_spawn_points: Dictionary = {}


func _init(hud: Control, refresh_gold_display: Callable) -> void:
	_hud = hud
	_refresh_gold_display = refresh_gold_display


## Shuffles the 8 cross-map arm anchors across GameManager.all_team_ids()
## -- always all 8, regardless of how many teams are actually active
## this match (BloodTournamentMode.active_team_ids); an inactive team's
## assigned anchor is simply never read, since nothing ever deploys for
## it (see deploy_next_pending_slot()/GoblinBossRound's own separate
## anchors, unaffected -- this only applies to normal PvP round
## deployment).
func assign_random_spawn_points() -> void:
	var arms := CrossArenaMap.SPAWN_POINTS.duplicate()
	arms.shuffle()
	round_spawn_points.clear()
	var team_ids := GameManager.all_team_ids()
	for i in team_ids.size():
		round_spawn_points[team_ids[i]] = arms[i]


## Connected to HUD's Start Battle button via Main._on_start_battle_pressed()
## -- a goblin boss round (BloodTournamentMode.is_boss_round()) gets
## intercepted here and handed off to GoblinBossRound's own team-by-team
## sequencing instead of one normal simultaneous PvP battle. Every other
## mode/round (including classic mode, mode == null) just calls
## GameManager.start_battle() exactly as before.
func start_battle_pressed() -> void:
	if mode != null and mode.is_boss_round():
		_boss_round = GoblinBossRound.new()
		_boss_round.boss_round_finished.connect(_on_boss_round_finished)
		_boss_round.start(mode)
	else:
		GameManager.start_battle()


## GoblinBossRound itself never touches round scoring (see its class doc
## comment) -- mode.finish_boss_round() does that once, for the boss
## round as a whole, which in turn emits round_ended and drives the
## exact same on_round_ended() -> advance_to_next_round() path a normal
## PvP round's win already does.
func _on_boss_round_finished() -> void:
	_boss_round = null
	mode.finish_boss_round()


## All 12 rounds of the match are done (BloodTournamentMode.all_rounds_finished,
## connected by Main._on_tournament_toggled()) -- hands off to the
## bracket-style final tournament that decides an overall champion (see
## FinalTournamentBracket's own class doc comment).
func on_all_rounds_finished() -> void:
	_bracket = FinalTournamentBracket.new()
	_bracket.champion_decided.connect(_on_champion_decided)
	_bracket.start(mode)


## Reuses the existing winner-banner UI (is_draw always false -- a
## champion is always a specific team, byes included) rather than
## building dedicated "tournament champion" UI for this stage; a real
## presentation pass is future polish, not part of the mechanic itself.
func _on_champion_decided(team_id: int) -> void:
	_bracket = null
	_hud.show_winner(team_id, false)


## Called everywhere a fresh PLACEMENT phase begins with Blood Tournament
## gold already settled (toggling the tournament on, and every subsequent
## round) -- a no-op unless there's an is_human == false player under a
## mode that actually uses_economy(), so calling this speculatively from
## several places is always safe.
func run_ai_turn_if_needed() -> void:
	if not GameManager.is_placement_phase() or not GameManager.current_mode.uses_economy():
		return
	var any_ai_took_a_turn := false
	for team_id in GameManager.all_team_ids():
		var player := GameManager.get_player(team_id)
		if not player.is_human:
			_ai.take_turn(player)
			any_ai_took_a_turn = true
	if any_ai_took_a_turn:
		_refresh_gold_display.call()


## Connected to the *current* BloodTournamentMode instance's own signal
## by Main._on_tournament_toggled() -- GameManager stays mode-agnostic
## (see GameMode.gd), so mode-specific UI reactions like this one have to
## come from something holding the mode reference directly.
func on_round_ended(round_number: int, _winning_team_id: int, _is_draw: bool) -> void:
	_hud.show_tournament_score(round_number, scoreboard_text())
	_refresh_gold_display.call() # round income (BloodTournamentMode.on_battle_ended()) already landed by now
	if not mode.is_match_over():
		# Deferred, not called straight from here: this handler runs
		# *during* GameManager._end_battle(), before its own
		# battle_ended.emit() -- resetting synchronously would flip
		# battle_state back to PLACEMENT and hide the winner banner
		# before that emit (and HUD.show_winner()) even runs, then have
		# it clobbered back to visible right after. Deferring lets this
		# round's result display first, uninterrupted.
		call_deferred("advance_to_next_round")


func advance_to_next_round() -> void:
	GameManager.reset_battle() # no permadeath -- every unit is freed; roster entries stay data-only until the next battle's staggered deployment
	_hud.reset_for_new_round()
	assign_random_spawn_points()
	run_ai_turn_if_needed()


## "TeamName wins : TeamName wins : ..." sorted by wins descending, only
## for teams that have actually fielded a roster at some point (same
## "who's really playing" filter GoblinBossRound/FinalTournamentBracket
## use) -- BloodTournamentMode.wins_by_team only ever gets a key for a
## team once it's WON a round, so a plain teams_with_units-style sort
## would silently omit anyone still sitting on 0 wins.
func scoreboard_text() -> String:
	var participants := GameManager.all_team_ids().filter(
		func(team_id: int) -> bool: return not GameManager.get_player(team_id).roster.is_empty()
	)
	participants.sort_custom(func(a: int, b: int) -> bool: return mode.get_wins(a) > mode.get_wins(b))

	var parts: Array[String] = []
	for team_id in participants:
		parts.append("%s %d" % [GameManager.get_team_display_name(team_id), mode.get_wins(team_id)])
	return " : ".join(parts)


## Literal separate staging area, not an instant respawn: Player.roster
## entries are never spawned as live Units during PLACEMENT -- they only
## become real Units once BATTLE actually starts, marching out from each
## player's pen one slot at a time. "Rightmost deploys first, leftmost
## deploys last" (per the reference genre) is expressed as *purchase
## order, reversed*: buying appends to the end of Player.roster, so the
## most recently bought slot -- the "rightmost" one in the line-up --
## pops first here.
func begin_staggered_deployment() -> void:
	# A goblin boss round's own controller (GoblinBossRound) deploys just
	# the one team currently taking its turn directly -- the normal
	# every-registered-team staggered flow below would double-deploy that
	# same roster a second time (and also try to deploy every OTHER
	# team's roster, which shouldn't appear during a solo PvE turn at
	# all) if it ran too. Same reasoning for a bracket matchup
	# (FinalTournamentBracket) -- it deploys exactly the two paired teams
	# itself.
	if mode != null and (mode.current_boss_team_id != -1 or mode.in_bracket_match):
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


## Called from Main._physics_process() every physics frame, unconditionally
## -- matches every other piece of game-logic timing in this codebase
## (HUD's own _process() is the one exception, but that's a pure UI
## refresh, not gameplay timing) and guarantees this actually advances
## during GUT's wait_physics_frames(), which is specifically tied to
## physics frames. Only does anything while there's an active staggered
## deployment queue for at least one player -- a no-op every other
## physics frame of the game's life, including all of PLACEMENT and any
## battle with an empty roster (classic mode, always).
func tick(delta: float) -> void:
	if _pending_deployments.is_empty():
		return
	for player_id in _pending_deployments.keys().duplicate(): # duplicated: deploy_next_pending_slot() below may erase from the dict mid-iteration
		_deploy_timers[player_id] -= delta
		if _deploy_timers[player_id] <= 0.0:
			deploy_next_pending_slot(player_id)


## Applies every account-wide upgrade the player bought during PLACEMENT
## (see GameManager.buy_roster_upgrade()) to every unit in the squad that
## just deployed -- upgrades were recorded rather than applied at
## purchase time specifically because nothing was alive yet to apply them
## to, so this is where that deferred application actually happens.
func deploy_next_pending_slot(player_id: int) -> void:
	var queue: Array = _pending_deployments[player_id]
	var stats: UnitStats = queue.pop_front()
	var player := GameManager.get_player(player_id)
	var anchor: Vector3 = round_spawn_points.get(player.team_id, CrossArenaMap.SPAWN_POINTS[player.team_id])
	var squad := GameManager.spawn_squad(stats, player, anchor)
	for upgrade in player.roster_upgrades:
		for unit in squad:
			upgrade.ability.cast_unit_target(unit, unit)

	if queue.is_empty():
		_pending_deployments.erase(player_id)
		_deploy_timers.erase(player_id)
	else:
		_deploy_timers[player_id] = _DEPLOY_INTERVAL
