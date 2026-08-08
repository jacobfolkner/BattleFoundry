## Tests for roadmap §2's 8-team scaling work: AI takes a turn for every
## non-human team (not just Red), the staggered-deployment queue deploys
## each team from its own cross-map arm (_main.ARM_SPAWN_POINTS) instead
## of the old hardcoded Blue/Red-only anchors, and the tournament
## scoreboard (Main._scoreboard_text()) shows a real sorted list for
## however many teams are actually playing, not a fixed Blue/Red label.
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
		player.is_human = true
	_main = load("res://Scenes/Main.tscn").instantiate()
	add_child_autofree(_main)
	await wait_physics_frames(2)


func test_ai_takes_a_turn_for_any_non_human_team_not_just_red() -> void:
	GameManager.set_mode(BloodTournamentMode.new()) # grants STARTING_GOLD to all 8 teams
	var green := GameManager.get_player(2)
	green.is_human = false

	_main._run_ai_turn_if_needed()

	assert_false(green.roster.is_empty(), "the AI should have bought into Green's roster, not just Red's")


func test_ai_still_leaves_human_teams_alone() -> void:
	GameManager.set_mode(BloodTournamentMode.new())
	var blue := GameManager.get_player(GameManager.BLUE_TEAM_ID)

	_main._run_ai_turn_if_needed()

	assert_true(blue.roster.is_empty(), "Blue is human by default -- the AI should never buy on its behalf")


func test_staggered_deployment_uses_each_teams_own_cross_map_arm() -> void:
	GameManager.set_mode(BloodTournamentMode.new())
	var green := GameManager.get_player(2) # _main.ARM_SPAWN_POINTS[2], East arm north half
	var orange := GameManager.get_player(5) # _main.ARM_SPAWN_POINTS[5], South arm west half
	green.roster = [TANK_STATS]
	orange.roster = [TANK_STATS]

	GameManager.start_battle()
	await wait_physics_frames(2)

	var green_unit := GameManager.get_all_units().filter(func(u: Unit) -> bool: return u.player == green)[0]
	var orange_unit := GameManager.get_all_units().filter(func(u: Unit) -> bool: return u.player == orange)[0]
	assert_almost_eq(green_unit.global_position.x, _main.ARM_SPAWN_POINTS[2].x, 0.5)
	assert_almost_eq(green_unit.global_position.z, _main.ARM_SPAWN_POINTS[2].z, 0.5)
	assert_almost_eq(orange_unit.global_position.x, _main.ARM_SPAWN_POINTS[5].x, 0.5)
	assert_almost_eq(orange_unit.global_position.z, _main.ARM_SPAWN_POINTS[5].z, 0.5)


func test_scoreboard_lists_every_participating_team_sorted_by_wins() -> void:
	var mode := BloodTournamentMode.new()
	GameManager.set_mode(mode)
	_main._tournament_mode = mode
	var blue := GameManager.get_player(GameManager.BLUE_TEAM_ID)
	var red := GameManager.get_player(GameManager.RED_TEAM_ID)
	var green := GameManager.get_player(2)
	blue.roster = [TANK_STATS]
	red.roster = [TANK_STATS]
	green.roster = [TANK_STATS]
	mode.wins_by_team = {blue.team_id: 1, red.team_id: 3, green.team_id: 0}

	assert_eq(_main._scoreboard_text(), "Red 3 : Blue 1 : Green 0")


func test_scoreboard_omits_teams_that_never_fielded_a_roster() -> void:
	var mode := BloodTournamentMode.new()
	GameManager.set_mode(mode)
	_main._tournament_mode = mode
	var blue := GameManager.get_player(GameManager.BLUE_TEAM_ID)
	var red := GameManager.get_player(GameManager.RED_TEAM_ID)
	blue.roster = [TANK_STATS] # Red never buys anything this test

	assert_eq(_main._scoreboard_text(), "Blue 0", "only teams with an actual roster should appear")
