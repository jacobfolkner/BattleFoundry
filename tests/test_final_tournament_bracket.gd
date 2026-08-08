## Tests for the bracket-style single-elimination final tournament
## (Scripts/FinalTournamentBracket.gd), Stage D of the goblin boss round
## feature -- see BattleFoundry-Roadmap.md §1. Confirmed design: teams
## ranked by round wins (ties broken by total blood points earned) are
## paired adjacently by seed, an odd team out gets a bye (to the single
## best-remaining seed, standard tournament convention), and matches
## resolve one at a time via GameManager's existing battle state machine
## -- the same "reuse the state machine, react to battle_ended" pattern
## GoblinBossRound already proved.
extends GutTest

const TANK_STATS: UnitStats = preload("res://Resources/Units/TankStats.tres")

var _main: Node3D


func before_each() -> void:
	GameManager.reset_battle()
	GameManager.current_mode = ClassicEliminationMode.new() # don't let an earlier test's mode leak in
	for team_id in GameManager.all_team_ids():
		var player := GameManager.get_player(team_id)
		player.resources = 0
		player.blood_points = 0
		player.roster.clear()
		player.roster_upgrades.clear()
	_main = load("res://Scenes/Main.tscn").instantiate()
	add_child_autofree(_main)
	await wait_physics_frames(2)


func _kill_team(team_id: int) -> void:
	for unit in GameManager.get_all_units():
		if unit.player.team_id == team_id and unit.life_state == Unit.LifeState.ALIVE:
			unit.take_damage(DamageInstance.new(unit.stat_block.max_health() + 1000.0))


func test_top_two_seeds_by_wins_fight_first() -> void:
	var mode := BloodTournamentMode.new(2, 12)
	GameManager.set_mode(mode)
	var blue := GameManager.get_player(GameManager.BLUE_TEAM_ID)
	var red := GameManager.get_player(GameManager.RED_TEAM_ID)
	var green := GameManager.get_player(2)
	var yellow := GameManager.get_player(3)
	blue.roster = [TANK_STATS]
	red.roster = [TANK_STATS]
	green.roster = [TANK_STATS]
	yellow.roster = [TANK_STATS]
	mode.wins_by_team = {blue.team_id: 1, red.team_id: 3, green.team_id: 0, yellow.team_id: 2}

	var bracket := FinalTournamentBracket.new()
	bracket.start(mode)

	assert_false(GameManager.team_is_empty(red.team_id), "top seed (Red, 3 wins) should be in the first match")
	assert_false(GameManager.team_is_empty(yellow.team_id), "second seed (Yellow, 2 wins) should be in the first match")
	assert_true(GameManager.team_is_empty(blue.team_id), "Blue (3rd seed) shouldn't fight until the next match")
	assert_true(GameManager.team_is_empty(green.team_id), "Green (4th seed) shouldn't fight until the next match")


func test_ties_broken_by_total_blood_points() -> void:
	var mode := BloodTournamentMode.new(2, 12)
	GameManager.set_mode(mode)
	var blue := GameManager.get_player(GameManager.BLUE_TEAM_ID)
	var red := GameManager.get_player(GameManager.RED_TEAM_ID)
	blue.roster = [TANK_STATS]
	red.roster = [TANK_STATS]
	mode.wins_by_team = {blue.team_id: 1, red.team_id: 1} # tied on wins
	blue.blood_points = 50
	red.blood_points = 200 # Red should out-seed Blue on the tiebreak

	var bracket := FinalTournamentBracket.new()
	bracket._mode = mode # _seed_teams() alone doesn't need start()'s deployment/battle-start side effects
	assert_eq(bracket._seed_teams(), [red.team_id, blue.team_id])


## An odd team out gets a bye to the single best-remaining seed (standard
## tournament convention) -- the bye is queued and resolved before the
## round's real matchup is ever deployed, so by the time start() returns,
## the bye winner is already a confirmed survivor for the next round.
func test_the_best_remaining_seed_gets_a_bye_when_the_field_is_odd() -> void:
	var mode := BloodTournamentMode.new(2, 12)
	GameManager.set_mode(mode)
	var blue := GameManager.get_player(GameManager.BLUE_TEAM_ID)
	var red := GameManager.get_player(GameManager.RED_TEAM_ID)
	var green := GameManager.get_player(2)
	blue.roster = [TANK_STATS]
	red.roster = [TANK_STATS]
	green.roster = [TANK_STATS]
	mode.wins_by_team = {red.team_id: 2, green.team_id: 1, blue.team_id: 0}

	var bracket := FinalTournamentBracket.new()
	bracket.start(mode)

	assert_true(bracket._round_survivors.has(red.team_id), "Red (top seed) should have already advanced via the bye")
	assert_false(GameManager.team_is_empty(green.team_id), "Green and Blue should be the ones actually fighting this round")
	assert_false(GameManager.team_is_empty(blue.team_id))


func test_champion_decided_once_only_one_team_remains() -> void:
	var mode := BloodTournamentMode.new(2, 12)
	GameManager.set_mode(mode)
	var blue := GameManager.get_player(GameManager.BLUE_TEAM_ID)
	var red := GameManager.get_player(GameManager.RED_TEAM_ID)
	blue.roster = [TANK_STATS]
	red.roster = [TANK_STATS]
	mode.wins_by_team = {blue.team_id: 1, red.team_id: 0}

	var bracket := FinalTournamentBracket.new()
	watch_signals(bracket)
	bracket.start(mode)

	_kill_team(red.team_id)

	assert_signal_emitted_with_parameters(bracket, "champion_decided", [blue.team_id])


## A draw (both sides' last units die on the same tick, no natural
## winner) is broken the same way seeding ties are -- by total blood
## points earned -- so the bracket always makes progress.
func test_a_draw_is_broken_by_total_blood_points() -> void:
	var mode := BloodTournamentMode.new(2, 12)
	GameManager.set_mode(mode)
	var blue := GameManager.get_player(GameManager.BLUE_TEAM_ID)
	var red := GameManager.get_player(GameManager.RED_TEAM_ID)
	blue.roster = [TANK_STATS]
	red.roster = [TANK_STATS]
	mode.wins_by_team = {blue.team_id: 1, red.team_id: 0}
	red.blood_points = 100 # Red should win the tiebreak despite a draw

	var bracket := FinalTournamentBracket.new()
	watch_signals(bracket)
	bracket.start(mode)

	bracket._on_battle_ended(-1, true) # simulate the draw outcome directly

	assert_signal_emitted_with_parameters(bracket, "champion_decided", [red.team_id])


## BloodTournamentMode.in_bracket_match is what stops on_battle_ended()
## from treating a bracket matchup as "the next round" of the 12-round
## match -- confirms the gate this whole stage depends on, not just that
## a champion eventually gets decided.
func test_a_bracket_matchup_does_not_grant_round_income_or_advance_round_number() -> void:
	var mode := BloodTournamentMode.new(2, 12)
	GameManager.set_mode(mode)
	var blue := GameManager.get_player(GameManager.BLUE_TEAM_ID)
	var red := GameManager.get_player(GameManager.RED_TEAM_ID)
	blue.roster = [TANK_STATS]
	red.roster = [TANK_STATS]
	mode.wins_by_team = {blue.team_id: 1, red.team_id: 0}
	mode.round_number = 12
	var blue_gold_before := blue.resources

	var bracket := FinalTournamentBracket.new()
	bracket.start(mode)
	assert_true(mode.in_bracket_match)

	_kill_team(red.team_id)

	assert_eq(mode.round_number, 12, "a bracket matchup isn't a 13th round of the match")
	assert_eq(blue.resources, blue_gold_before, "a bracket matchup shouldn't grant BloodTournamentMode.PARTICIPATION_INCOME")
	assert_false(mode.in_bracket_match, "should be cleared once the matchup resolves")
