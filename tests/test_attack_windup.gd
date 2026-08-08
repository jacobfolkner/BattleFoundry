## Tests for UnitStats.attack_windup / Unit._attack()'s windup-then-release
## split -- roadmap Phase 2's second combat-depth item. Calls
## attacker._attack(delta) directly with target_enemy set by hand, rather
## than running a full battle simulation, so windup timing can be asserted
## on exactly instead of inferred from a physics-frame budget (same
## "prefer a direct read over inferring from timing" lesson already on
## record for this project -- see
## memory/project_lifecycle_players_orders_projectiles_branch.md).
extends GutTest

var _main: Node3D


func before_each() -> void:
	GameManager.reset_battle()
	GameManager.current_mode = ClassicEliminationMode.new()
	_main = load("res://Scenes/Main.tscn").instantiate()
	add_child_autofree(_main)
	await wait_physics_frames(2)


func _windup_attacker_stats() -> UnitStats:
	var stats := UnitStats.new()
	stats.damage = 10.0
	stats.attack_interval = 1.0
	stats.attack_windup = 0.3
	return stats


func test_zero_windup_lands_the_hit_the_same_call_the_cooldown_allows() -> void:
	var instant_stats := UnitStats.new()
	instant_stats.damage = 10.0
	instant_stats.attack_interval = 1.0
	var attacker := GameManager.spawn_unit(instant_stats, GameManager.get_player(GameManager.BLUE_TEAM_ID), Vector3.ZERO)
	var target := GameManager.spawn_unit(UnitStats.new(), GameManager.get_player(GameManager.RED_TEAM_ID), Vector3(1, 0, 0))
	attacker.target_enemy = target

	attacker._attack(0.0)

	assert_eq(target.current_health, target.stat_block.max_health() - 10.0,
		"attack_windup == 0.0 should land the hit instantly, exactly as before this system existed")


func test_nonzero_windup_does_not_land_the_hit_before_it_elapses() -> void:
	var attacker := GameManager.spawn_unit(_windup_attacker_stats(), GameManager.get_player(GameManager.BLUE_TEAM_ID), Vector3.ZERO)
	var target := GameManager.spawn_unit(UnitStats.new(), GameManager.get_player(GameManager.RED_TEAM_ID), Vector3(1, 0, 0))
	attacker.target_enemy = target

	attacker._attack(0.0) # commits the swing
	attacker._attack(0.2) # 0.2s into a 0.3s windup -- not landed yet

	assert_eq(target.current_health, target.stat_block.max_health(),
		"the hit should not land before attack_windup has fully elapsed")


func test_nonzero_windup_lands_the_hit_once_it_elapses() -> void:
	var attacker := GameManager.spawn_unit(_windup_attacker_stats(), GameManager.get_player(GameManager.BLUE_TEAM_ID), Vector3.ZERO)
	var target := GameManager.spawn_unit(UnitStats.new(), GameManager.get_player(GameManager.RED_TEAM_ID), Vector3(1, 0, 0))
	attacker.target_enemy = target

	attacker._attack(0.0) # commits the swing
	attacker._attack(0.3) # exactly the full windup

	assert_eq(target.current_health, target.stat_block.max_health() - 10.0,
		"the hit should land once attack_windup has fully elapsed")


func test_windup_locks_the_target_at_swing_commit_not_at_release() -> void:
	var attacker := GameManager.spawn_unit(_windup_attacker_stats(), GameManager.get_player(GameManager.BLUE_TEAM_ID), Vector3.ZERO)
	var original_target := GameManager.spawn_unit(UnitStats.new(), GameManager.get_player(GameManager.RED_TEAM_ID), Vector3(1, 0, 0))
	var other_target := GameManager.spawn_unit(UnitStats.new(), GameManager.get_player(GameManager.RED_TEAM_ID), Vector3(2, 0, 0))
	attacker.target_enemy = original_target

	attacker._attack(0.0) # commits against original_target
	attacker.target_enemy = other_target # re-targeted mid-swing
	attacker._attack(0.3) # windup elapses

	assert_eq(original_target.current_health, original_target.stat_block.max_health() - 10.0,
		"the hit should land on whoever was targeted when the swing committed")
	assert_eq(other_target.current_health, other_target.stat_block.max_health(),
		"a re-target mid-swing should not redirect an already-committed hit")


func test_windup_fizzles_harmlessly_if_the_target_dies_before_it_elapses() -> void:
	var attacker := GameManager.spawn_unit(_windup_attacker_stats(), GameManager.get_player(GameManager.BLUE_TEAM_ID), Vector3.ZERO)
	var target := GameManager.spawn_unit(UnitStats.new(), GameManager.get_player(GameManager.RED_TEAM_ID), Vector3(1, 0, 0))
	attacker.target_enemy = target

	attacker._attack(0.0) # commits the swing
	target.take_damage(DamageInstance.new(target.stat_block.max_health() + 100.0))
	attacker._attack(0.3) # windup elapses against a now-dead target -- should not crash

	assert_eq(target.life_state, Unit.LifeState.DEAD, "target should already be dead from the setup damage, not double-killed by the fizzled swing")


func test_attack_cooldown_only_starts_counting_once_the_windup_hit_lands() -> void:
	var attacker := GameManager.spawn_unit(_windup_attacker_stats(), GameManager.get_player(GameManager.BLUE_TEAM_ID), Vector3.ZERO)
	var target := GameManager.spawn_unit(UnitStats.new(), GameManager.get_player(GameManager.RED_TEAM_ID), Vector3(1, 0, 0))
	attacker.target_enemy = target

	attacker._attack(0.0) # commits the swing (0.3s windup)
	attacker._attack(0.3) # hit lands, attack_interval (1.0s) cooldown starts now
	attacker._attack(0.9) # short of the full 1.0s interval since the hit landed

	assert_eq(target.current_health, target.stat_block.max_health() - 10.0,
		"a second swing should not commit before the full attack_interval has elapsed since the last hit landed")
