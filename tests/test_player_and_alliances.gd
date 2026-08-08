## Tests for the Player/AllianceMatrix model that replaced the old
## Team.Type enum + get_opponent(): free-for-all-by-default hostility
## between distinct teams, ally()/unally(), the always-non-hostile
## neutral team, and GameManager's default two-player prototype roster.
extends GutTest

const TANK_STATS: UnitStats = preload("res://Resources/Units/TankStats.tres")

var _main: Node3D


func before_each() -> void:
	GameManager.reset_battle()
	GameManager.current_mode = ClassicEliminationMode.new() # don't let an earlier test's mode (and its cross-shaped arena) leak into this one
	_main = load("res://Scenes/Main.tscn").instantiate()
	add_child_autofree(_main)
	await wait_physics_frames(2)


# ---------------------------------------------------------------------
# AllianceMatrix
# ---------------------------------------------------------------------

func test_distinct_teams_are_hostile_by_default() -> void:
	var alliances := AllianceMatrix.new()
	assert_true(alliances.is_hostile(0, 1))


func test_a_team_is_never_hostile_to_itself() -> void:
	var alliances := AllianceMatrix.new()
	assert_false(alliances.is_hostile(0, 0))


func test_ally_and_unally_toggle_hostility() -> void:
	var alliances := AllianceMatrix.new()
	assert_true(alliances.is_hostile(0, 1))

	alliances.ally(0, 1)
	assert_false(alliances.is_hostile(0, 1), "allied teams should no longer be hostile")
	assert_true(alliances.are_allied(0, 1))

	alliances.unally(0, 1)
	assert_true(alliances.is_hostile(0, 1), "unallying should revert to the FFA-default hostile")


func test_neutral_team_is_never_hostile_to_anyone() -> void:
	var alliances := AllianceMatrix.new()
	var neutral := AllianceMatrix.NEUTRAL_TEAM_ID

	assert_false(alliances.is_hostile(neutral, 0))
	assert_false(alliances.is_hostile(0, neutral))
	assert_false(alliances.is_hostile(neutral, 1))


# ---------------------------------------------------------------------
# GameManager's default player roster
# ---------------------------------------------------------------------

func test_default_players_are_registered_and_hostile() -> void:
	var blue := GameManager.get_player(GameManager.BLUE_TEAM_ID)
	var red := GameManager.get_player(GameManager.RED_TEAM_ID)

	assert_not_null(blue)
	assert_not_null(red)
	assert_true(GameManager.alliances.is_hostile(blue.team_id, red.team_id),
		"the default two-player roster should reproduce the old always-hostile Team.Type behavior")


func test_get_team_display_name() -> void:
	assert_eq(GameManager.get_team_display_name(GameManager.BLUE_TEAM_ID), "Blue")
	assert_eq(GameManager.get_team_display_name(GameManager.RED_TEAM_ID), "Red")
	assert_eq(GameManager.get_team_display_name(99), "Team 99",
		"a team_id with no registered Player should still get a readable fallback")


# ---------------------------------------------------------------------
# Combat generalizes past two teams
# ---------------------------------------------------------------------

## The old find_nearest_enemy() hardcoded Team.get_opponent() -- exactly
## one other side. This proves it now scans every AllianceMatrix-hostile
## team instead, using a third team that was never part of GameManager's
## default two-player roster at all.
func test_find_nearest_enemy_recognizes_a_third_unregistered_team() -> void:
	var blue := GameManager.get_player(GameManager.BLUE_TEAM_ID)
	var green := Player.new(2, 2, 2, "Green", Color.GREEN)

	var blue_unit := GameManager.spawn_unit(TANK_STATS, blue, Vector3(-3, 0, 0))
	var green_unit := GameManager.spawn_unit(TANK_STATS, green, Vector3(3, 0, 0))

	assert_true(GameManager.alliances.is_hostile(blue.team_id, green.team_id),
		"an unregistered third team should still be hostile under the FFA default")
	assert_eq(GameManager.find_nearest_enemy(blue_unit), green_unit)


func test_allied_teams_do_not_target_each_other() -> void:
	var blue := GameManager.get_player(GameManager.BLUE_TEAM_ID)
	var green := Player.new(2, 2, 2, "Green", Color.GREEN)
	GameManager.alliances.ally(blue.team_id, green.team_id)

	var blue_unit := GameManager.spawn_unit(TANK_STATS, blue, Vector3(-3, 0, 0))
	GameManager.spawn_unit(TANK_STATS, green, Vector3(3, 0, 0))

	assert_null(GameManager.find_nearest_enemy(blue_unit),
		"an allied team's units should never be returned as an enemy")

	GameManager.alliances.unally(blue.team_id, green.team_id) # don't leak into other tests


## The "known rough edge" this project shipped with from the start: no
## distance cutoff meant find_nearest_enemy() always returned *some*
## enemy anywhere on the field, so an idle unit would walk clear across
## the arena to fight something on the other side of it.
func test_find_nearest_enemy_ignores_a_target_beyond_acquisition_range() -> void:
	var blue := GameManager.get_player(GameManager.BLUE_TEAM_ID)
	var red := GameManager.get_player(GameManager.RED_TEAM_ID)
	var blue_unit := GameManager.spawn_unit(TANK_STATS, blue, Vector3.ZERO)
	GameManager.spawn_unit(TANK_STATS, red, Vector3(TANK_STATS.acquisition_range + 5.0, 0, 0))

	assert_null(GameManager.find_nearest_enemy(blue_unit),
		"an enemy beyond acquisition_range should never be found, even with nothing closer to prefer instead")


func test_find_nearest_enemy_still_finds_a_target_within_acquisition_range() -> void:
	var blue := GameManager.get_player(GameManager.BLUE_TEAM_ID)
	var red := GameManager.get_player(GameManager.RED_TEAM_ID)
	var blue_unit := GameManager.spawn_unit(TANK_STATS, blue, Vector3.ZERO)
	var enemy := GameManager.spawn_unit(TANK_STATS, red, Vector3(TANK_STATS.acquisition_range - 2.0, 0, 0))

	assert_eq(GameManager.find_nearest_enemy(blue_unit), enemy)
