## Tests for the goblin boss round's team-by-team sequencing controller
## (Scripts/BloodTournament/GoblinBossRound.gd) and the BloodTournamentMode/Main.gd
## plumbing it depends on (is_boss_round(), current_boss_team_id-aware
## can_start_battle()/check_victory()/on_battle_ended(), finish_boss_round(),
## Main._on_start_battle_pressed()). The death-escalation mechanic itself
## (revive/split) is tested in isolation in test_goblin_escalation.gd --
## this file is purely about the "every 3rd round, one team at a time"
## sequencing layer built on top of it.
extends GutTest

const TANK_STATS: UnitStats = preload("res://Resources/Units/TankStats.tres")

var _main: Node3D


func before_each() -> void:
	GameManager.reset_battle()
	GameManager.current_mode = ClassicEliminationMode.new() # don't let an earlier test's mode leak in
	var blue := GameManager.get_player(GameManager.BLUE_TEAM_ID)
	var red := GameManager.get_player(GameManager.RED_TEAM_ID)
	blue.resources = 0
	red.resources = 0
	blue.blood_points = 0
	red.blood_points = 0
	blue.roster.clear()
	red.roster.clear()
	blue.roster_upgrades.clear()
	red.roster_upgrades.clear()
	blue.is_human = true
	red.is_human = true
	_main = load("res://Scenes/Main.tscn").instantiate()
	add_child_autofree(_main)
	await wait_physics_frames(2)


func _kill_team(team_id: int) -> void:
	for unit in GameManager.get_all_units():
		if unit.player.team_id == team_id and unit.life_state == Unit.LifeState.ALIVE:
			unit.take_damage(DamageInstance.new(unit.stat_block.max_health() + 1000.0))


## Puts BloodTournamentMode two rounds in (round_number == 2), so the
## *next* round (3) is a boss round -- see BloodTournamentMode.is_boss_round().
## Goes through _main._on_tournament_toggled(true), same as every other
## integration test in this project, rather than GameManager.set_mode()
## directly, so _main._tournament_mode ends up correctly typed
## (BloodTournamentMode, not the base GameMode GameManager.current_mode
## is statically typed as).
func _start_two_rounds_into_a_match() -> BloodTournamentMode:
	_main._on_tournament_toggled(true)
	_main._tournament_mode.round_number = 2
	return _main._tournament_mode


func test_is_boss_round_true_every_third_round() -> void:
	var mode := BloodTournamentMode.new()

	for round_number in range(1, 13):
		mode.round_number = round_number - 1 # is_boss_round() asks about the *next* round
		assert_eq(mode.is_boss_round(), round_number % 3 == 0, "round %d boss-round-ness" % round_number)


func test_start_battle_during_a_boss_round_deploys_the_first_teams_roster_against_a_goblin() -> void:
	var mode := _start_two_rounds_into_a_match()
	var blue := GameManager.get_player(GameManager.BLUE_TEAM_ID)
	blue.roster = [TANK_STATS]

	_main._on_start_battle_pressed()

	assert_true(GameManager.is_battle_active())
	assert_eq(mode.current_boss_team_id, GameManager.BLUE_TEAM_ID)
	assert_false(GameManager.team_is_empty(GameManager.BLUE_TEAM_ID), "Blue's roster should have deployed")
	assert_false(GameManager.team_is_empty(GameManager.GOBLIN_TEAM_ID), "a Goblin should have spawned to fight Blue")


## Attrition: the team's own units wiping ends its turn as a DRAW (no PvP
## winner), not a TEAM_WON -- confirms BloodTournamentMode.check_victory()'s
## boss-round branch, not just that combat happens at all.
func test_a_teams_own_wipe_ends_its_turn_without_declaring_a_pvp_winner() -> void:
	var mode := _start_two_rounds_into_a_match()
	var blue := GameManager.get_player(GameManager.BLUE_TEAM_ID)
	blue.roster = [TANK_STATS]

	_main._on_start_battle_pressed()
	_kill_team(GameManager.BLUE_TEAM_ID)

	assert_eq(mode.current_boss_team_id, -1, "the boss-round controller should have cleared this once the turn ended")
	assert_eq(mode.wins_by_team.size(), 0, "a boss-round turn ending is never a PvP win for anyone")


func test_boss_round_processes_every_team_with_a_roster_in_turn() -> void:
	var mode := _start_two_rounds_into_a_match()
	var blue := GameManager.get_player(GameManager.BLUE_TEAM_ID)
	var red := GameManager.get_player(GameManager.RED_TEAM_ID)
	blue.roster = [TANK_STATS]
	red.roster = [TANK_STATS]

	_main._on_start_battle_pressed()
	assert_eq(mode.current_boss_team_id, GameManager.BLUE_TEAM_ID, "Blue registers before Red -- should go first")

	_kill_team(GameManager.BLUE_TEAM_ID)
	assert_eq(mode.current_boss_team_id, GameManager.RED_TEAM_ID, "Red's turn should start immediately after Blue's ends")
	assert_true(GameManager.team_is_empty(GameManager.BLUE_TEAM_ID), "Blue's corpse/roster shouldn't linger into Red's turn")
	assert_false(GameManager.team_is_empty(GameManager.RED_TEAM_ID))

	_kill_team(GameManager.RED_TEAM_ID)
	assert_eq(mode.current_boss_team_id, -1, "no teams left -- the boss round itself should be over")


func test_a_team_with_an_empty_roster_is_skipped() -> void:
	var mode := _start_two_rounds_into_a_match()
	var red := GameManager.get_player(GameManager.RED_TEAM_ID)
	red.roster = [TANK_STATS] # Blue's roster stays empty

	_main._on_start_battle_pressed()

	assert_eq(mode.current_boss_team_id, GameManager.RED_TEAM_ID, "Blue has nothing to fight with -- Red should go first instead")


## Full integration: once every team has had its turn, the boss round
## should grant participation income and advance the round exactly once
## for the whole thing, not once per team-turn, and land back in
## PLACEMENT the same way a normal PvP round does.
func test_boss_round_finished_grants_income_once_and_advances_to_the_next_round() -> void:
	var mode := _start_two_rounds_into_a_match()
	var blue := GameManager.get_player(GameManager.BLUE_TEAM_ID)
	blue.roster = [TANK_STATS]
	var gold_before := blue.resources

	_main._on_start_battle_pressed()
	_kill_team(GameManager.BLUE_TEAM_ID)
	await wait_physics_frames(3) # let the deferred _advance_to_next_round() run

	assert_eq(mode.round_number, 3)
	assert_eq(blue.resources, gold_before + BloodTournamentMode.PARTICIPATION_INCOME, "income should be granted exactly once for the whole boss round")
	assert_true(GameManager.is_placement_phase())
	assert_eq(blue.roster, [TANK_STATS], "no permadeath -- Blue's roster should still be there for the next round")
