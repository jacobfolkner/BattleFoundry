## Drives the bracket-style single-elimination final tournament that
## decides an overall champion once BloodTournamentMode.all_rounds_finished
## fires (see BattleFoundry-Roadmap.md §1, Stage D). Confirmed design:
## teams ranked by round wins (ties broken by total blood points earned)
## are paired adjacently by seed (1v2, 3v4, ...; an odd team out gets a
## bye straight through to the next round) and re-paired from whoever's
## left each round until one champion remains.
##
## Owned/driven entirely by Main.gd, the same split AIController/
## GoblinBossRound already use. Reuses GameManager's existing PLACEMENT/
## BATTLE/GAME_OVER state machine per matchup exactly like GoblinBossRound
## does: BloodTournamentMode.in_bracket_match (set here) is what stops
## on_battle_ended() from treating a bracket matchup as "the next round"
## of the 12-round match (income/round_number/round_ended don't apply to
## it). check_victory() itself needs no bracket-specific branch --  its
## existing N-team logic already reduces correctly to a 1v1 decision when
## only the two paired teams have anything deployed.
class_name FinalTournamentBracket
extends RefCounted

const _TEAM_A_ANCHOR := Vector3(-8, 0, 0)
const _TEAM_B_ANCHOR := Vector3(8, 0, 0)

## Emitted once exactly one team is left standing.
signal champion_decided(team_id: int)

var _mode: BloodTournamentMode
var _remaining: Array = [] ## team_ids still alive in the bracket, seeded best-to-worst
var _round_matches: Array = [] ## Array of [team_a, team_b] pairs for the round currently being played -- a bye is [team_id, -1]
var _round_survivors: Array = []
var _match_index: int = 0


func start(mode: BloodTournamentMode) -> void:
	_mode = mode
	_remaining = _seed_teams()
	GameManager.battle_ended.connect(_on_battle_ended)
	_begin_round()


## Ranked by round wins, ties broken by total blood points earned -- the
## confirmed seeding rule. Only teams that actually fielded a roster at
## some point (non-empty right now, same "who's really playing" filter
## GoblinBossRound uses) are seeded at all.
func _seed_teams() -> Array:
	var participants := GameManager.all_team_ids().filter(
		func(team_id: int) -> bool: return not GameManager.get_player(team_id).roster.is_empty()
	)
	participants.sort_custom(func(a: int, b: int) -> bool:
		if _mode.get_wins(a) != _mode.get_wins(b):
			return _mode.get_wins(a) > _mode.get_wins(b)
		return GameManager.get_player(a).blood_points > GameManager.get_player(b).blood_points
	)
	return participants


func _begin_round() -> void:
	if _remaining.size() <= 1:
		GameManager.battle_ended.disconnect(_on_battle_ended)
		champion_decided.emit(_remaining[0] if not _remaining.is_empty() else -1)
		return

	# The bye (if any) goes to the single best-remaining seed, tournament
	# convention, and is queued first -- _play_next_match() processes it
	# immediately (no battle needed), so by the time this round's first
	# real matchup is actually deployed, the bye has already advanced.
	_round_matches = []
	var pool: Array = _remaining.duplicate()
	if pool.size() % 2 == 1:
		_round_matches.append([pool.pop_front(), -1])
	var i := 0
	while i < pool.size():
		_round_matches.append([pool[i], pool[i + 1]])
		i += 2
	_round_survivors = []
	_match_index = 0
	_play_next_match()


## A bye ([team_id, -1]) needs no battle at all -- advances immediately
## and recurses straight into the next match, since nothing async is
## happening. A real matchup deploys both teams' current rosters (as-is,
## no new purchasing phase for the final) and starts the battle;
## _on_battle_ended() is what resumes this loop once it resolves.
func _play_next_match() -> void:
	if _match_index >= _round_matches.size():
		_remaining = _round_survivors
		_begin_round()
		return

	var pair: Array = _round_matches[_match_index]
	if pair[1] == -1:
		_round_survivors.append(pair[0])
		_match_index += 1
		_play_next_match()
		return

	_mode.in_bracket_match = true
	# start_battle() before spawning, not after: GameManager.spawn_unit()
	# only issues the auto-battle convergence order (see its own doc
	# comment) while is_battle_active() is already true, and the two
	# anchors sit well beyond acquisition_range on their own, so spawning
	# first would leave both sides just standing there forever.
	GameManager.start_battle()
	for team_id in pair:
		var player := GameManager.get_player(team_id)
		var anchor := _TEAM_A_ANCHOR if team_id == pair[0] else _TEAM_B_ANCHOR
		for stats in player.roster:
			var squad := GameManager.spawn_squad(stats, player, anchor)
			for upgrade in player.roster_upgrades:
				for unit in squad:
					upgrade.ability.cast_unit_target(unit, unit)


## A draw (both sides' last units die on the same tick) has no natural
## winner to advance -- broken the same way seeding ties are, by total
## blood points earned, so the bracket can always make progress without
## a replay.
func _on_battle_ended(winning_team_id: int, is_draw: bool) -> void:
	var pair: Array = _round_matches[_match_index]
	var winner := winning_team_id
	if is_draw:
		winner = pair[0] if GameManager.get_player(pair[0]).blood_points >= GameManager.get_player(pair[1]).blood_points else pair[1]

	_round_survivors.append(winner)
	_mode.in_bracket_match = false
	GameManager.reset_battle()
	_match_index += 1
	_play_next_match()
