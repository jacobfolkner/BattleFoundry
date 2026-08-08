## Tests for the GameMode extraction (D3): GameManager delegating victory
## conditions to GameManager.current_mode instead of hardcoding
## elimination itself (see Scripts/GameMode.gd, Scripts/ClassicEliminationMode.gd),
## and the first real mode built on top of it, BloodTournamentMode
## (Scripts/BloodTournamentMode.gd) -- best-of-N rounds with the arena
## auto-resetting between them.
extends GutTest

const TANK_STATS: UnitStats = preload("res://Resources/TankStats.tres")
const FIGHTER_STATS: UnitStats = preload("res://Resources/FighterStats.tres")

var _main: Node3D


func before_each() -> void:
	GameManager.reset_battle()
	GameManager.current_mode = ClassicEliminationMode.new() # GameManager is an autoload -- don't let a mode set by an earlier test leak into this one
	_main = load("res://Scenes/Main.tscn").instantiate()
	add_child_autofree(_main)
	await wait_physics_frames(2)


func test_default_mode_is_classic_elimination() -> void:
	assert_true(GameManager.current_mode is ClassicEliminationMode)


func test_set_mode_resets_to_placement() -> void:
	GameManager.spawn_unit(TANK_STATS, GameManager.get_player(GameManager.BLUE_TEAM_ID), Vector3(-3, 0, 0))
	GameManager.spawn_unit(FIGHTER_STATS, GameManager.get_player(GameManager.RED_TEAM_ID), Vector3(3, 0, 0))
	GameManager.start_battle()
	assert_true(GameManager.is_battle_active())

	GameManager.set_mode(BloodTournamentMode.new())

	assert_true(GameManager.is_placement_phase(), "set_mode should reset to PLACEMENT")
	assert_false(GameManager.can_start_battle(), "rosters should be cleared by the reset")


func test_blood_tournament_tracks_round_wins_and_emits_round_ended() -> void:
	var mode := BloodTournamentMode.new()
	GameManager.set_mode(mode)
	watch_signals(mode)

	var blue := GameManager.get_player(GameManager.BLUE_TEAM_ID)
	var red := GameManager.get_player(GameManager.RED_TEAM_ID)
	GameManager.spawn_unit(TANK_STATS, blue, Vector3(-3, 0, 0))
	var loser := GameManager.spawn_unit(FIGHTER_STATS, red, Vector3(3, 0, 0))
	GameManager.start_battle()

	loser.take_damage(DamageInstance.new(loser.stat_block.max_health() + 100.0))

	assert_eq(mode.round_number, 1)
	assert_eq(mode.get_wins(GameManager.BLUE_TEAM_ID), 1)
	assert_eq(mode.get_wins(GameManager.RED_TEAM_ID), 0)
	assert_signal_emitted_with_parameters(mode, "round_ended", [1, GameManager.BLUE_TEAM_ID, false])


func test_blood_tournament_match_ends_after_reaching_rounds_to_win() -> void:
	var mode := BloodTournamentMode.new(2)
	GameManager.set_mode(mode)
	watch_signals(mode)

	var blue := GameManager.get_player(GameManager.BLUE_TEAM_ID)
	var red := GameManager.get_player(GameManager.RED_TEAM_ID)

	GameManager.spawn_unit(TANK_STATS, blue, Vector3(-3, 0, 0))
	var loser1 := GameManager.spawn_unit(FIGHTER_STATS, red, Vector3(3, 0, 0))
	GameManager.start_battle()
	loser1.take_damage(DamageInstance.new(loser1.stat_block.max_health() + 100.0))
	assert_false(mode.is_match_over(), "one round shouldn't decide a best-of-2")

	GameManager.reset_battle()

	GameManager.spawn_unit(TANK_STATS, blue, Vector3(-3, 0, 0))
	var loser2 := GameManager.spawn_unit(FIGHTER_STATS, red, Vector3(3, 0, 0))
	GameManager.start_battle()
	loser2.take_damage(DamageInstance.new(loser2.stat_block.max_health() + 100.0))

	assert_true(mode.is_match_over(), "the same team winning twice should decide a best-of-2")
	assert_signal_emitted_with_parameters(mode, "match_ended", [GameManager.BLUE_TEAM_ID])


func test_blood_tournament_draw_increments_round_but_not_wins() -> void:
	var mode := BloodTournamentMode.new()

	mode.on_battle_ended(GameManager.BLUE_TEAM_ID, true) # simulate a draw directly -- easier than forcing a real stalemate timeout

	assert_eq(mode.round_number, 1)
	assert_eq(mode.get_wins(GameManager.BLUE_TEAM_ID), 0)
	assert_eq(mode.get_wins(GameManager.RED_TEAM_ID), 0)


## Integration: goes through Main._on_tournament_toggled() (what HUD's
## Blood Tournament button actually calls), not a hand-built
## BloodTournamentMode + GameManager.set_mode() pair, so this also
## proves the deferred auto-reset (_advance_to_next_round(), deferred to
## avoid a same-frame signal-ordering hazard with GameManager.battle_ended
## -- see its doc comment) actually fires.
func test_main_auto_advances_to_next_round_after_a_win() -> void:
	_main._on_tournament_toggled(true)

	var blue := GameManager.get_player(GameManager.BLUE_TEAM_ID)
	var red := GameManager.get_player(GameManager.RED_TEAM_ID)
	GameManager.spawn_unit(TANK_STATS, blue, Vector3(-3, 0, 0))
	var loser := GameManager.spawn_unit(FIGHTER_STATS, red, Vector3(3, 0, 0))
	GameManager.start_battle()

	loser.take_damage(DamageInstance.new(loser.stat_block.max_health() + 100.0))
	assert_true(GameManager.is_game_over(), "sanity check: the round should have ended")

	await wait_physics_frames(2) # let the deferred _advance_to_next_round() run

	assert_true(GameManager.is_placement_phase(), "Main.gd should auto-reset for the next round")
