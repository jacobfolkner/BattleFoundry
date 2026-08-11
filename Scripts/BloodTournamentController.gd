## Owns Blood Tournament's round-to-round orchestration: marching each
## team's lineup-courtyard squads onto the arena at battle start, random
## per-round spawn points, AI-turn-triggering, scoreboard text, and the
## boss-round/bracket-tournament hand-offs (GoblinBossRound/FinalTournamentBracket,
## both unchanged, still their own sibling controllers).
##
## A roster slot's live squad already exists, standing in that team's
## lineup courtyard (GameManager.sync_courtyard_to_roster()), by the time
## a battle starts -- see begin_march() below. This controller doesn't
## spawn anything itself; it only repositions+reorders already-alive
## units.
##
## Constructed once, unconditionally, in Main._ready() -- not lazily when
## Blood Tournament activates. This mirrors how Player.roster/
## Player.resources already exist and simply stay unused/inert for a
## classic-mode match: this controller's own state (round_spawn_points)
## is exactly the same shape -- always present, functionally a no-op
## whenever GameManager.current_mode doesn't populate any Player.roster.
## Constructing it unconditionally (rather than only when the tournament
## toggle is on) is also what lets several tests poke round_spawn_points/
## mode directly without going through the normal activation flow at all
## -- see their own comments below for exactly which fields that applies
## to.
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
## assigned anchor is simply never read, since nothing ever marches for
## it (see begin_march()/GoblinBossRound's own separate anchors,
## unaffected -- this only applies to normal PvP round deployment).
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
		GameManager.start_battle() # sync_courtyard_to_roster()'s safety net runs inside start_battle() itself -- see its own doc comment for why that's the one call site every path (button, test, AI) always goes through


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
	GameManager.reset_battle() # no permadeath -- every unit is freed, including anyone standing in a courtyard (reset_battle() clears Player.courtyard_units itself -- see its own doc comment)
	_hud.reset_for_new_round()
	assign_random_spawn_points()
	for team_id in GameManager.all_team_ids():
		GameManager.sync_courtyard_to_roster(GameManager.get_player(team_id)) # repopulate each team's courtyard from their persisted roster the instant PLACEMENT reopens, not only once they next buy something
	run_ai_turn_if_needed()


## "TeamName wins : TeamName wins : ..." sorted by wins descending, only
## for teams that have actually fielded a roster at some point (same
## "who's really playing" filter GoblinBossRound/FinalTournamentBracket
## use) -- BloodTournamentMode.wins_by_team only ever gets a key for a
## team once it's WON a round, so a plain teams_with_units-style sort
## would silently omit anyone still sitting on 0 wins.
## "TeamName Wg (Xg, YK, Zbp)" per participating team, sorted by wins
## descending -- wins decide ranking (the actual point of a leaderboard),
## gold/kills/blood points ride along per team as the things a player
## actually wants to compare mid-match (who's ahead economically, who's
## racking up kills) without opening each team's own panel.
func scoreboard_text() -> String:
	var participants := GameManager.all_team_ids().filter(
		func(team_id: int) -> bool: return not GameManager.get_player(team_id).roster.is_empty()
	)
	participants.sort_custom(func(a: int, b: int) -> bool: return mode.get_wins(a) > mode.get_wins(b))

	var parts: Array[String] = []
	for team_id in participants:
		var player := GameManager.get_player(team_id)
		parts.append("%s %dW (%dg, %dK, %dbp)" % [
			GameManager.get_team_display_name(team_id), mode.get_wins(team_id),
			player.resources, player.kills, player.blood_points,
		])
	return " : ".join(parts)


## Connected to GameManager.battle_started -- marches every team's
## lineup-courtyard squads onto the arena, all at once (not staggered:
## nothing is being "produced" anymore, it's already-trained troops
## marching out together). Repositions each already-alive Unit instance
## (GameManager.sync_courtyard_to_roster() already spawned them, inside
## GameManager.start_battle() itself, before this signal even fires) to
## this round's assigned arm anchor and issues an ATTACK_MOVE toward
## center -- mirrors exactly what GameManager.spawn_unit() already does
## for a mid-battle auto-battle spawn, just applied to a pre-existing
## Unit instead of a freshly created one. Deliberately march-only:
## roster_upgrades/hero_progress were already applied at courtyard-spawn
## time (see sync_courtyard_to_roster()) -- re-applying them here risks a
## double-application depending on the specific upgrade's
## Effect.stack_rule, so nothing in this method calls
## Ability.cast_unit_target()/Unit.restore_hero_progress() at all.
func begin_march() -> void:
	# Reads GameManager.current_mode directly, NOT this controller's own
	# `mode` field -- current_mode is the actual authority GameManager
	# itself uses everywhere else, whereas `mode` is only kept in sync
	# with it by Main._on_tournament_toggled()'s real activation flow. A
	# caller that does GameManager.set_mode(BloodTournamentMode.new())
	# directly (several tests, including GoblinBossRound/FinalTournamentBracket's
	# own, do exactly this) leaves `mode` null/stale -- since this method
	# runs synchronously as part of GameManager.start_battle() itself (via
	# the battle_started signal, before a caller like FinalTournamentBracket
	# gets control back to run its own GameManager.clear_courtyard_units()
	# cleanup), a null `mode` here would silently march EVERY team's
	# courtyard units, not just the ones actually meant to fight this
	# turn/matchup.
	var current_mode := GameManager.current_mode as BloodTournamentMode
	# A goblin boss round's own controller (GoblinBossRound) deploys just
	# the one team currently taking its turn directly, and a bracket
	# matchup (FinalTournamentBracket) deploys exactly its two paired
	# teams itself -- both bypass the courtyard/roster model entirely
	# (see their own class doc comments), so nothing here should run
	# during either.
	if current_mode != null and (current_mode.current_boss_team_id != -1 or current_mode.in_bracket_match):
		return

	for team_id in GameManager.all_team_ids():
		var player := GameManager.get_player(team_id)
		if player.courtyard_units.is_empty():
			continue
		var anchor: Vector3 = round_spawn_points.get(team_id, CrossArenaMap.SPAWN_POINTS[team_id])
		var rival_anchor: Variant = _arm_rival_anchor(team_id, anchor)
		for squad in player.courtyard_units:
			if squad.is_empty():
				continue
			# Same spread formula GameManager.spawn_squad() uses, applied
			# around the arm anchor instead of the courtyard anchor --
			# reused rather than a plain stack-everyone-at-one-point
			# teleport, so a marching squad doesn't need move_and_slide()
			# to shove itself apart from scratch.
			var stats: UnitStats = squad[0].stats
			var spacing := stats.collision_radius * 2.5 + 0.3
			for i in squad.size():
				var offset := Vector3((i - (squad.size() - 1) * 0.5) * spacing, 0, 0)
				squad[i].global_position = anchor + offset
				# Engage the same-arm rival first (matches the roadmap's
				# documented design: same-arm opponents fight at the arm
				# ends before survivors converge) -- walking to that spot
				# and finding nothing there (rival already eliminated, or
				# the defensive null case below) is harmless, the queued
				# center-push order still runs right after either way.
				if rival_anchor != null:
					squad[i].order_attack_move(rival_anchor)
				squad[i].order_attack_move(Vector3.ZERO, true) # queued -- runs once the arm fight resolves
		player.courtyard_units.clear()


## The arm-end position team_id's same-arm rival is marching from this
## round (round_spawn_points reassigns SPAWN_POINTS' 8 positions across
## team_ids each round -- see CrossArenaMap.arm_partner_index()'s own
## doc comment). All 8 team_ids always hold some position (active or
## not, per assign_random_spawn_points()'s own doc comment) so this is
## effectively never null in practice -- the null return is defensive
## only, for an `anchor` that somehow isn't a recognized SPAWN_POINTS
## value at all.
func _arm_rival_anchor(team_id: int, anchor: Vector3) -> Variant:
	var my_index := CrossArenaMap.SPAWN_POINTS.find(anchor)
	if my_index == -1:
		return null
	var partner_position := CrossArenaMap.SPAWN_POINTS[CrossArenaMap.arm_partner_index(my_index)]
	for other_id in GameManager.all_team_ids():
		if other_id == team_id:
			continue
		var other_anchor: Vector3 = round_spawn_points.get(other_id, CrossArenaMap.SPAWN_POINTS[other_id])
		if other_anchor == partner_position:
			return partner_position
	return null
