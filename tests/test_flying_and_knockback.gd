## Tests for the flying-unit and knockback mechanics added alongside the
## Bat Rider and Giant archetypes: a flying unit rests at flight_height
## instead of the ground plane, can still fight ground units (proving
## the horizontal-distance combat-range fix, not just the visual
## offset), and Giant's attack visibly launches its target into the air
## and back.
extends GutTest

const TANK_STATS: UnitStats = preload("res://Resources/TankStats.tres")
const FIGHTER_STATS: UnitStats = preload("res://Resources/FighterStats.tres")
const ARCHER_STATS: UnitStats = preload("res://Resources/ArcherStats.tres")
const BAT_RIDER_STATS: UnitStats = preload("res://Resources/BatRiderStats.tres")
const GIANT_STATS: UnitStats = preload("res://Resources/GiantStats.tres")

var _main: Node3D


func before_each() -> void:
	GameManager.reset_battle()
	_main = load("res://Scenes/Main.tscn").instantiate()
	add_child_autofree(_main)
	await wait_physics_frames(2)


func test_bat_rider_rests_at_flight_height() -> void:
	var bat_rider := GameManager.spawn_unit(BAT_RIDER_STATS, Team.Type.BLUE, Vector3.ZERO)
	await wait_physics_frames(3)

	assert_almost_eq(bat_rider.global_position.y, BAT_RIDER_STATS.flight_height, 0.05,
		"a flying unit should rest at flight_height, not the ground plane")


func test_ground_unit_still_rests_at_zero() -> void:
	var tank := GameManager.spawn_unit(TANK_STATS, Team.Type.BLUE, Vector3.ZERO)
	await wait_physics_frames(3)

	assert_almost_eq(tank.global_position.y, 0.0, 0.05,
		"non-flying units must be unaffected by the flight-height change")


## Archer has can_attack_flying = true (a ranged unit, per the "ground
## can't hit air unless it's anti-air/ranged" convention) -- proves a
## flying unit and a permitted ground unit can fight each other despite
## the height difference, i.e. the horizontal-distance range fix works,
## not just the can_attack_flying gate.
func test_flying_unit_and_permitted_ground_unit_can_damage_each_other() -> void:
	var bat_rider := GameManager.spawn_unit(BAT_RIDER_STATS, Team.Type.BLUE, Vector3(-1, 0, 0))
	var archer := GameManager.spawn_unit(ARCHER_STATS, Team.Type.RED, Vector3(1, 0, 0))
	GameManager.start_battle()

	for i in range(120): # 2s -- plenty for both to land at least one hit at this range
		await wait_physics_frames(1)

	assert_lt(bat_rider.current_health, BAT_RIDER_STATS.max_health,
		"a unit with can_attack_flying = true should be able to hit a flying unit")
	assert_lt(archer.current_health, ARCHER_STATS.max_health,
		"flying unit should be able to hit a ground unit despite the height difference")


## Tank has can_attack_flying = false (the default) -- it should never
## even acquire the Bat Rider as a target, let alone damage it, while
## the Bat Rider (unrestricted, flying units can always hit ground) can
## still damage the Tank.
func test_ground_melee_cannot_target_flying_unit() -> void:
	var bat_rider := GameManager.spawn_unit(BAT_RIDER_STATS, Team.Type.BLUE, Vector3(-1, 0, 0))
	var tank := GameManager.spawn_unit(TANK_STATS, Team.Type.RED, Vector3(1, 0, 0))
	GameManager.start_battle()

	for i in range(120): # 2s
		await wait_physics_frames(1)

	assert_eq(bat_rider.current_health, BAT_RIDER_STATS.max_health,
		"can_attack_flying = false should mean the Tank never lands a hit on a flying unit")
	assert_null(tank.target_enemy, "the Tank should never acquire the flying unit as a target at all")
	assert_lt(tank.current_health, TANK_STATS.max_health,
		"the flying unit should still be able to hit the ground unit")


func test_giant_knockback_launches_target_up_and_back_and_lands() -> void:
	GameManager.spawn_unit(GIANT_STATS, Team.Type.BLUE, Vector3.ZERO)
	var target := GameManager.spawn_unit(FIGHTER_STATS, Team.Type.RED, Vector3(1, 0, 0))
	GameManager.start_battle()

	var max_height := 0.0
	var was_airborne := false
	for i in range(60): # 1s -- comfortably covers the 0.6s knockback arc
		await wait_physics_frames(1)
		if is_instance_valid(target):
			max_height = maxf(max_height, target.global_position.y)
			was_airborne = was_airborne or target.global_position.y > 0.1

	assert_true(was_airborne, "Giant's hit should launch the target off the ground")
	assert_gt(max_height, 0.5, "the target should rise a meaningful height, not just jitter")
	if is_instance_valid(target):
		assert_almost_eq(target.global_position.y, 0.0, 0.1,
			"target should have landed back on the ground within the 1s test window")
		assert_gt(target.global_position.distance_to(Vector3(1, 0, 0)), 1.0,
			"target should have been pushed back, not just up")
