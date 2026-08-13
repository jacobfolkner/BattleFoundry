## Tests for Scripts/Combat/Projectile.gd and the projectile_speed/projectile_homing
## fields it reads off UnitStats -- Archer is the first archetype
## migrated onto it (see ArcherStats.tres), replacing its old instant
## ranged damage.
extends GutTest

const TANK_STATS: UnitStats = preload("res://Resources/Units/TankStats.tres")
const FIGHTER_STATS: UnitStats = preload("res://Resources/Units/FighterStats.tres")
const ARCHER_STATS: UnitStats = preload("res://Resources/Units/ArcherStats.tres")
const PROJECTILE_SCENE: PackedScene = preload("res://Scenes/Projectile.tscn")

var _main: Node3D


func before_each() -> void:
	GameManager.reset_battle()
	GameManager.current_mode = ClassicEliminationMode.new() # don't let an earlier test's mode (and its cross-shaped arena) leak into this one
	# See Player.reset_for_new_match()'s own doc comment -- reset_battle()
	# deliberately leaves player.roster alone, so a stale one from an
	# earlier test would otherwise resurrect as extra live units the
	# moment this file's own start_battle() call runs.
	GameManager.get_player(GameManager.BLUE_TEAM_ID).reset_for_new_match()
	GameManager.get_player(GameManager.RED_TEAM_ID).reset_for_new_match()
	_main = load("res://Scenes/Main.tscn").instantiate()
	add_child_autofree(_main)
	await wait_physics_frames(2)


func _spawn_projectile(source: Unit, target: Unit, speed: float, guidance: Projectile.GuidanceType) -> Projectile:
	var projectile: Projectile = PROJECTILE_SCENE.instantiate()
	GameManager.units_container.add_child(projectile)
	projectile.global_position = source.global_position
	projectile.setup(source, target, speed, guidance)
	return projectile


func test_projectile_does_not_deal_damage_the_instant_it_is_fired() -> void:
	var attacker := GameManager.spawn_unit(ARCHER_STATS, GameManager.get_player(GameManager.BLUE_TEAM_ID), Vector3.ZERO)
	var target := GameManager.spawn_unit(TANK_STATS, GameManager.get_player(GameManager.RED_TEAM_ID), Vector3(5, 0, 0))

	_spawn_projectile(attacker, target, 10.0, Projectile.GuidanceType.HOMING)

	assert_eq(target.current_health, TANK_STATS.max_health,
		"damage should only land on impact, not the instant a projectile is spawned")


func test_projectile_travels_and_deals_damage_on_impact() -> void:
	var attacker := GameManager.spawn_unit(ARCHER_STATS, GameManager.get_player(GameManager.BLUE_TEAM_ID), Vector3.ZERO)
	var target := GameManager.spawn_unit(TANK_STATS, GameManager.get_player(GameManager.RED_TEAM_ID), Vector3(5, 0, 0))

	var projectile := _spawn_projectile(attacker, target, 10.0, Projectile.GuidanceType.HOMING)

	for i in range(120): # 2s -- comfortably covers 5m at 10 m/s (~0.5s)
		if not is_instance_valid(projectile):
			break
		await wait_physics_frames(1)

	assert_false(is_instance_valid(projectile), "the projectile should free itself on impact")
	assert_lt(target.current_health, TANK_STATS.max_health, "impact should deal damage via Unit.resolve_hit()")


func test_homing_projectile_tracks_a_target_that_moves_after_launch() -> void:
	var attacker := GameManager.spawn_unit(ARCHER_STATS, GameManager.get_player(GameManager.BLUE_TEAM_ID), Vector3.ZERO)
	var target := GameManager.spawn_unit(TANK_STATS, GameManager.get_player(GameManager.RED_TEAM_ID), Vector3(5, 0, 0))

	var projectile := _spawn_projectile(attacker, target, 3.0, Projectile.GuidanceType.HOMING) # slow, so the retarget matters
	target.global_position = Vector3(5, 0, 5) # sidesteps after the shot is already in flight

	for i in range(300): # 5s -- generous for a slow 3 m/s projectile to retarget and cross the gap
		if not is_instance_valid(projectile):
			break
		await wait_physics_frames(1)

	assert_false(is_instance_valid(projectile))
	assert_lt(target.current_health, TANK_STATS.max_health,
		"a HOMING projectile should still hit a target that moved after it was fired")


func test_ballistic_projectile_can_miss_a_target_that_moved() -> void:
	var attacker := GameManager.spawn_unit(ARCHER_STATS, GameManager.get_player(GameManager.BLUE_TEAM_ID), Vector3.ZERO)
	var target := GameManager.spawn_unit(TANK_STATS, GameManager.get_player(GameManager.RED_TEAM_ID), Vector3(5, 0, 0))

	var projectile := _spawn_projectile(attacker, target, 3.0, Projectile.GuidanceType.BALLISTIC)
	target.global_position = Vector3(5, 0, 20) # well clear of the projectile's fixed original flight line

	for i in range(300):
		if not is_instance_valid(projectile):
			break
		await wait_physics_frames(1)

	assert_false(is_instance_valid(projectile),
		"a BALLISTIC projectile should still expire once it reaches its original aim point, even on a miss")
	assert_eq(target.current_health, TANK_STATS.max_health,
		"a BALLISTIC shot aimed at the old position should miss a target that's moved well clear of it")


func test_projectile_dissipates_if_its_target_is_freed_mid_flight() -> void:
	var attacker := GameManager.spawn_unit(ARCHER_STATS, GameManager.get_player(GameManager.BLUE_TEAM_ID), Vector3.ZERO)
	var target := GameManager.spawn_unit(TANK_STATS, GameManager.get_player(GameManager.RED_TEAM_ID), Vector3(5, 0, 0))

	var projectile := _spawn_projectile(attacker, target, 2.0, Projectile.GuidanceType.HOMING)

	target.queue_free()
	await wait_physics_frames(3) # let the free actually process

	for i in range(60):
		if not is_instance_valid(projectile):
			break
		await wait_physics_frames(1)

	assert_false(is_instance_valid(projectile), "a projectile should free itself once its target is gone")


func test_melee_attack_deals_damage_without_spawning_a_projectile() -> void:
	var tank := GameManager.spawn_unit(TANK_STATS, GameManager.get_player(GameManager.BLUE_TEAM_ID), Vector3(-1, 0, 0))
	var target := GameManager.spawn_unit(FIGHTER_STATS, GameManager.get_player(GameManager.RED_TEAM_ID), Vector3(1, 0, 0))
	GameManager.start_battle()

	var hit := await _wait_until(func(): return target.current_health < FIGHTER_STATS.max_health, 90) # comfortably covers Tank's 1.2s attack_interval
	assert_true(hit, "the Tank should land a melee hit")

	var projectile_count := 0
	for child in GameManager.units_container.get_children():
		if child is Projectile:
			projectile_count += 1
	assert_eq(projectile_count, 0, "a melee attack (projectile_speed == 0) should never spawn a Projectile")


## Full integration through the real AI/attack loop, not a manually
## constructed Projectile -- validates Unit._fire_projectile_at()'s own
## wiring (position, guidance, GameManager.units_container parenting).
func test_archer_attack_spawns_a_projectile_instead_of_instant_damage() -> void:
	GameManager.spawn_unit(ARCHER_STATS, GameManager.get_player(GameManager.BLUE_TEAM_ID), Vector3(-2, 0, 0))
	GameManager.spawn_unit(TANK_STATS, GameManager.get_player(GameManager.RED_TEAM_ID), Vector3(2, 0, 0))
	GameManager.start_battle()

	var spawned := await _wait_until(func():
		for child in GameManager.units_container.get_children():
			if child is Projectile:
				return true
		return false
	, 120) # comfortably covers Archer's 1.0s attack_interval

	assert_true(spawned, "the Archer's attack should spawn a Projectile rather than dealing damage instantly")


## Polls `condition` once per physics frame (not a wall-clock timer, which
## doesn't map to simulated physics time under GUT). Returns true as soon
## as it's met, false if `timeout_physics_frames` elapses first.
func _wait_until(condition: Callable, timeout_physics_frames: int) -> bool:
	var frames := 0
	while not condition.call():
		if frames >= timeout_physics_frames:
			return false
		await wait_physics_frames(1)
		frames += 1
	return true
