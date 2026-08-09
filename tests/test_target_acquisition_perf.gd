## Tests for Unit._reacquisition_cooldown/_TARGET_REACQUISITION_INTERVAL --
## roadmap Phase 0's "no re-acquisition interval" gap. Calls
## unit._update_target() directly, same direct-call style established
## for Phase 2's combat-depth tests, so the throttle's timing can be
## asserted exactly rather than inferred from a physics-frame budget.
extends GutTest

const TANK_STATS: UnitStats = preload("res://Resources/Units/TankStats.tres")

var _main: Node3D


func before_each() -> void:
	GameManager.reset_battle()
	GameManager.current_mode = ClassicEliminationMode.new()
	_main = load("res://Scenes/Main.tscn").instantiate()
	add_child_autofree(_main)
	await wait_physics_frames(2)


func test_first_call_with_no_target_acquires_immediately() -> void:
	var tank := GameManager.spawn_unit(TANK_STATS, GameManager.get_player(GameManager.BLUE_TEAM_ID), Vector3.ZERO)
	var enemy := GameManager.spawn_unit(TANK_STATS, GameManager.get_player(GameManager.RED_TEAM_ID), Vector3(1, 0, 0))

	tank._update_target()

	assert_eq(tank.target_enemy, enemy, "the very first acquisition attempt should never be throttled")


func test_a_second_call_within_the_reacquisition_interval_does_not_pick_up_a_newly_spawned_closer_enemy() -> void:
	var tank := GameManager.spawn_unit(TANK_STATS, GameManager.get_player(GameManager.BLUE_TEAM_ID), Vector3.ZERO)
	tank._update_target() # no enemies exist yet -- stays null, but starts the reacquisition cooldown regardless

	var enemy := GameManager.spawn_unit(TANK_STATS, GameManager.get_player(GameManager.RED_TEAM_ID), Vector3(1, 0, 0))
	tank._update_target() # same instant -- the cooldown from the call above hasn't ticked down at all yet

	assert_null(tank.target_enemy,
		"a re-scan attempted before the reacquisition interval elapses should be throttled, even though a valid enemy now exists")


func test_a_call_after_the_reacquisition_interval_elapses_picks_up_the_enemy() -> void:
	var tank := GameManager.spawn_unit(TANK_STATS, GameManager.get_player(GameManager.BLUE_TEAM_ID), Vector3.ZERO)
	tank._update_target() # starts the cooldown

	var enemy := GameManager.spawn_unit(TANK_STATS, GameManager.get_player(GameManager.RED_TEAM_ID), Vector3(1, 0, 0))
	tank._reacquisition_cooldown = 0.0 # simulate the cooldown having ticked down via _physics_process()
	tank._update_target()

	assert_eq(tank.target_enemy, enemy, "a re-scan attempted after the cooldown elapses should succeed normally")


## Regression guard: an out-of-range/invalid target must be dropped
## immediately regardless of the reacquisition cooldown -- only the
## *search for a replacement* is throttled, not "give up on what I can't
## reach anymore." Confirms the cooldown set by a successful acquisition
## doesn't leave target_enemy stuck pointing at something that's since
## drifted out of range.
func test_an_out_of_range_target_is_dropped_immediately_even_while_the_cooldown_is_active() -> void:
	var tank := GameManager.spawn_unit(TANK_STATS, GameManager.get_player(GameManager.BLUE_TEAM_ID), Vector3.ZERO)
	var enemy := GameManager.spawn_unit(TANK_STATS, GameManager.get_player(GameManager.RED_TEAM_ID), Vector3(1, 0, 0))
	tank._update_target()
	assert_eq(tank.target_enemy, enemy) # sanity check -- also starts the reacquisition cooldown

	enemy.global_position = Vector3(TANK_STATS.acquisition_range + 10.0, 0, 0) # drift far away
	tank._update_target() # the cooldown from the acquisition above is still fully active here

	assert_null(tank.target_enemy,
		"an out-of-range target should be dropped the same call, not held onto until the reacquisition cooldown expires")
