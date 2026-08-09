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
		player.kills = 0
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

	# Loose tolerance (4.0), not tight -- TANK_STATS.squad_size is 3, so
	# GameManager.spawn_squad() spreads members up to +-2.425 from the
	# anchor along X, and .filter()[0] isn't guaranteed to land on the
	# centered one; auto-battle (BloodTournamentMode.is_auto_battle())
	# also issues an immediate ATTACK_MOVE toward the arena center at
	# spawn, so by the time these 2 physics frames elapse the unit has
	# already started walking off its exact spawn point. What actually
	# matters here is "landed in the right arm, not a totally different
	# one" -- the 8 arms are tens of units apart, so 4.0 stays well clear
	# of any ambiguity between them.
	var green_unit: Unit = GameManager.get_all_units().filter(func(u: Unit) -> bool: return u.player == green)[0]
	var orange_unit: Unit = GameManager.get_all_units().filter(func(u: Unit) -> bool: return u.player == orange)[0]
	assert_almost_eq(green_unit.global_position.x, _main.ARM_SPAWN_POINTS[2].x, 4.0)
	assert_almost_eq(green_unit.global_position.z, _main.ARM_SPAWN_POINTS[2].z, 4.0)
	assert_almost_eq(orange_unit.global_position.x, _main.ARM_SPAWN_POINTS[5].x, 4.0)
	assert_almost_eq(orange_unit.global_position.z, _main.ARM_SPAWN_POINTS[5].z, 4.0)


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

	assert_eq(_main._scoreboard_text(), "Red 3W (300g, 0K, 0bp) : Blue 1W (300g, 0K, 0bp) : Green 0W (300g, 0K, 0bp)")


func test_scoreboard_omits_teams_that_never_fielded_a_roster() -> void:
	var mode := BloodTournamentMode.new()
	GameManager.set_mode(mode)
	_main._tournament_mode = mode
	var blue := GameManager.get_player(GameManager.BLUE_TEAM_ID)
	var red := GameManager.get_player(GameManager.RED_TEAM_ID)
	blue.roster = [TANK_STATS] # Red never buys anything this test

	assert_eq(_main._scoreboard_text(), "Blue 0W (300g, 0K, 0bp)", "only teams with an actual roster should appear")


## Confirmed design: spawn locations are randomized every round, not a
## fixed team_id -> arm mapping -- a valid assignment is still a real
## permutation of the 8 real arm points (every team gets a distinct one,
## none reused), just not necessarily team_id's own ARM_SPAWN_POINTS[team_id].
func test_assign_random_spawn_points_produces_a_valid_permutation_of_all_8_arms() -> void:
	_main._assign_random_spawn_points()

	assert_eq(_main._round_spawn_points.size(), GameManager.TEAM_COUNT)
	var used_anchors := {}
	for team_id in GameManager.all_team_ids():
		var anchor: Vector3 = _main._round_spawn_points[team_id]
		assert_true(_main.ARM_SPAWN_POINTS.has(anchor), "every assigned anchor should be one of the 8 real arm points")
		used_anchors[anchor] = true
	assert_eq(used_anchors.size(), GameManager.TEAM_COUNT, "every arm point should be used exactly once, no duplicates")


func test_deployment_uses_this_rounds_randomized_spawn_point() -> void:
	GameManager.set_mode(BloodTournamentMode.new())
	var non_default_anchor: Vector3 = _main.ARM_SPAWN_POINTS[6] # Blue's own default is ARM_SPAWN_POINTS[0]
	_main._round_spawn_points = {GameManager.BLUE_TEAM_ID: non_default_anchor}
	var blue := GameManager.get_player(GameManager.BLUE_TEAM_ID)
	var red := GameManager.get_player(GameManager.RED_TEAM_ID)
	blue.roster = [TANK_STATS]
	red.roster = [TANK_STATS]

	GameManager.start_battle()
	await wait_physics_frames(2)

	# Loose tolerance -- see test_staggered_deployment_uses_each_teams_own_cross_map_arm()'s
	# own comment (squad spread + auto-battle's immediate ATTACK_MOVE
	# toward center, not a tight spawn-point-exact check).
	var blue_unit: Unit = GameManager.get_all_units().filter(func(u: Unit) -> bool: return u.player == blue)[0]
	assert_almost_eq(blue_unit.global_position.x, non_default_anchor.x, 4.0)
	assert_almost_eq(blue_unit.global_position.z, non_default_anchor.z, 4.0)


## Confirmed design: "2 to 8 teams, fill all slots with bots or just
## some of them" -- team_count restricts which teams actually get
## funded/play, independent of every team still being registered.
func test_team_count_limits_which_teams_get_starting_gold() -> void:
	MenuSelection.start_with_tournament = true
	MenuSelection.start_with_ai_opponent = true
	MenuSelection.human_team_id = GameManager.BLUE_TEAM_ID
	MenuSelection.team_count = 3

	var main: Node3D = load("res://Scenes/Main.tscn").instantiate()
	add_child_autofree(main)
	await wait_physics_frames(2)

	assert_gt(GameManager.get_player(GameManager.BLUE_TEAM_ID).resources, 0, "the human's own team should be funded")
	assert_gt(GameManager.get_player(GameManager.RED_TEAM_ID).resources, 0, "1st AI slot should be funded")
	assert_gt(GameManager.get_player(2).resources, 0, "2nd AI slot should be funded")
	assert_eq(GameManager.get_player(3).resources, 0, "team_count=3 means only 3 teams total -- the 4th+ should be unfunded")
	assert_eq(GameManager.get_player(7).resources, 0)


func test_team_count_defaults_to_every_registered_team_without_ai_opponent() -> void:
	MenuSelection.start_with_tournament = true
	MenuSelection.start_with_ai_opponent = false # no AI opponent -- team_count shouldn't restrict anything

	var main: Node3D = load("res://Scenes/Main.tscn").instantiate()
	add_child_autofree(main)
	await wait_physics_frames(2)

	for team_id in GameManager.all_team_ids():
		assert_gt(GameManager.get_player(team_id).resources, 0, "every registered team should still be funded with no AI opponent chosen")
