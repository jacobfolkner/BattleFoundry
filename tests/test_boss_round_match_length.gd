## Tests for BloodTournamentMode.total_rounds (Stage C of the goblin boss
## round feature -- see BattleFoundry-Roadmap.md §1): the genre-accurate
## fixed 12-round match length, played through regardless of standings,
## as opposed to the original first-to-rounds_to_win-wins behavior every
## other BloodTournamentMode test in this project still relies on
## (total_rounds defaults to 0, so none of that behavior changes unless a
## test explicitly opts in, same as this file does).
extends GutTest

var _main: Node3D


func before_each() -> void:
	GameManager.reset_battle()
	GameManager.current_mode = ClassicEliminationMode.new() # don't let an earlier test's mode leak in
	_main = load("res://Scenes/Main.tscn").instantiate()
	add_child_autofree(_main)
	await wait_physics_frames(2)


func test_is_match_over_uses_the_fixed_round_count_when_total_rounds_is_set() -> void:
	var mode := BloodTournamentMode.new(2, 12)

	for round_number in range(12):
		mode.round_number = round_number
		assert_false(mode.is_match_over(), "round %d of 12 shouldn't be over yet" % round_number)

	mode.round_number = 12
	assert_true(mode.is_match_over())


## Regression guard: every existing BloodTournamentMode test constructs
## with total_rounds left at its default (0) and expects the ORIGINAL
## first-to-rounds_to_win-wins behavior -- confirms that path is
## completely unaffected by this stage's addition.
func test_default_mode_without_total_rounds_still_uses_the_win_threshold() -> void:
	var mode := BloodTournamentMode.new(2) # total_rounds left at 0
	mode.wins_by_team[GameManager.BLUE_TEAM_ID] = 2

	assert_true(mode.is_match_over(), "reaching rounds_to_win should still decide the match when total_rounds is unset")


## Once total_rounds is set, match_ended (win-threshold-based) never
## fires, even if a team's wins would otherwise have crossed rounds_to_win
## along the way -- all_rounds_finished is the only end-of-match signal
## under the fixed-length structure. Small total_rounds (3) for a fast
## test, not the real 12.
func test_all_rounds_finished_emits_once_and_match_ended_never_does() -> void:
	var mode := BloodTournamentMode.new(1, 3) # rounds_to_win=1 would normally decide it after round 1
	watch_signals(mode)

	mode.on_battle_ended(GameManager.BLUE_TEAM_ID, false) # round 1 -- Blue already has 1 win, would end a best-of-1 match
	assert_signal_not_emitted(mode, "all_rounds_finished")
	assert_signal_not_emitted(mode, "match_ended")

	mode.on_battle_ended(GameManager.RED_TEAM_ID, false) # round 2
	assert_signal_not_emitted(mode, "all_rounds_finished")

	mode.on_battle_ended(GameManager.BLUE_TEAM_ID, false) # round 3 -- total_rounds reached
	assert_signal_emitted(mode, "all_rounds_finished")
	assert_signal_not_emitted(mode, "match_ended", "match_ended is only for the win-threshold mode, never fires once total_rounds is set")


## finish_boss_round() (a goblin boss round's own round-scoring path, see
## GoblinBossRound.gd) counts toward total_rounds exactly like a normal
## PvP round's on_battle_ended() does -- round 3 in this test is both the
## boss round (is_boss_round()) and the round that completes a 3-round
## fixed-length match.
func test_a_boss_round_also_counts_toward_total_rounds() -> void:
	var mode := BloodTournamentMode.new(2, 3)
	watch_signals(mode)
	mode.on_battle_ended(GameManager.BLUE_TEAM_ID, false) # round 1
	mode.on_battle_ended(GameManager.RED_TEAM_ID, false) # round 2
	assert_true(mode.is_boss_round(), "round 3 should be a boss round")

	mode.finish_boss_round() # round 3, via the boss-round path, not on_battle_ended()

	assert_eq(mode.round_number, 3)
	assert_true(mode.is_match_over())
	assert_signal_emitted(mode, "all_rounds_finished")


func test_the_real_tournament_toggle_sets_a_12_round_fixed_length() -> void:
	_main._on_tournament_toggled(true)

	assert_eq(_main._tournament_mode.total_rounds, 12)
