## Tests for UnitStats.splash_radius/splash_falloff -- roadmap Phase 2's
## third combat-depth item. Calls attacker.resolve_hit(primary, source)
## directly, same direct-call style tests/test_attack_windup.gd already
## established for this phase, so splash math can be asserted on exactly
## rather than inferred from a physics-frame budget.
extends GutTest

var _main: Node3D


func before_each() -> void:
	GameManager.reset_battle()
	GameManager.current_mode = ClassicEliminationMode.new()
	_main = load("res://Scenes/Main.tscn").instantiate()
	add_child_autofree(_main)
	await wait_physics_frames(2)


func _splash_attacker_stats() -> UnitStats:
	var stats := UnitStats.new()
	stats.damage = 10.0
	stats.splash_radius = 5.0
	stats.splash_falloff = 0.5
	return stats


func test_zero_splash_radius_only_damages_the_primary_target() -> void:
	var no_splash_stats := UnitStats.new()
	no_splash_stats.damage = 10.0
	var attacker := GameManager.spawn_unit(no_splash_stats, GameManager.get_player(GameManager.BLUE_TEAM_ID), Vector3.ZERO)
	var primary := GameManager.spawn_unit(UnitStats.new(), GameManager.get_player(GameManager.RED_TEAM_ID), Vector3(1, 0, 0))
	var nearby := GameManager.spawn_unit(UnitStats.new(), GameManager.get_player(GameManager.RED_TEAM_ID), Vector3(2, 0, 0))

	attacker.resolve_hit(primary, attacker.global_position)

	assert_eq(primary.current_health, primary.stat_block.max_health() - 10.0)
	assert_eq(nearby.current_health, nearby.stat_block.max_health(),
		"splash_radius == 0.0 should behave exactly like a plain single-target attack")


func test_splash_damages_a_hostile_unit_within_radius_with_distance_based_falloff() -> void:
	var attacker := GameManager.spawn_unit(_splash_attacker_stats(), GameManager.get_player(GameManager.BLUE_TEAM_ID), Vector3.ZERO)
	var primary := GameManager.spawn_unit(UnitStats.new(), GameManager.get_player(GameManager.RED_TEAM_ID), Vector3(10, 0, 0))
	var splashed := GameManager.spawn_unit(UnitStats.new(), GameManager.get_player(GameManager.RED_TEAM_ID), Vector3(12.5, 0, 0)) # 2.5m from primary, half of the 5.0 splash_radius

	attacker.resolve_hit(primary, attacker.global_position)

	assert_eq(primary.current_health, primary.stat_block.max_health() - 10.0,
		"the primary target should always take full damage")
	var expected_falloff := lerpf(1.0, 0.5, 0.5) # halfway to the radius edge, halfway between 1.0 and splash_falloff (0.5)
	assert_eq(splashed.current_health, splashed.stat_block.max_health() - 10.0 * expected_falloff,
		"a splashed unit should take damage interpolated between full damage and splash_falloff by distance")


func test_splash_ignores_a_unit_beyond_the_splash_radius() -> void:
	var attacker := GameManager.spawn_unit(_splash_attacker_stats(), GameManager.get_player(GameManager.BLUE_TEAM_ID), Vector3.ZERO)
	var primary := GameManager.spawn_unit(UnitStats.new(), GameManager.get_player(GameManager.RED_TEAM_ID), Vector3(10, 0, 0))
	var far_away := GameManager.spawn_unit(UnitStats.new(), GameManager.get_player(GameManager.RED_TEAM_ID), Vector3(20, 0, 0)) # 10m from primary, well beyond the 5.0 radius

	attacker.resolve_hit(primary, attacker.global_position)

	assert_eq(far_away.current_health, far_away.stat_block.max_health(),
		"a unit beyond splash_radius should take no splash damage")


## Splash hostility is judged against the ATTACKER's team, same as any
## other damage source -- a second red unit standing right next to the
## primary target SHOULD take splash (that's the whole point: clustered
## enemies), but a blue ally of the attacker wandering into range should
## never take friendly-fire splash damage.
func test_splash_hits_a_second_enemy_near_the_primary_but_never_the_attackers_own_ally() -> void:
	var attacker := GameManager.spawn_unit(_splash_attacker_stats(), GameManager.get_player(GameManager.BLUE_TEAM_ID), Vector3.ZERO)
	var primary := GameManager.spawn_unit(UnitStats.new(), GameManager.get_player(GameManager.RED_TEAM_ID), Vector3(10, 0, 0))
	var second_enemy := GameManager.spawn_unit(UnitStats.new(), GameManager.get_player(GameManager.RED_TEAM_ID), Vector3(11, 0, 0))
	var attackers_own_ally := GameManager.spawn_unit(UnitStats.new(), GameManager.get_player(GameManager.BLUE_TEAM_ID), Vector3(10.5, 0, 0))

	attacker.resolve_hit(primary, attacker.global_position)

	assert_lt(second_enemy.current_health, second_enemy.stat_block.max_health(),
		"a second enemy near the primary target should take splash damage")
	assert_eq(attackers_own_ally.current_health, attackers_own_ally.stat_block.max_health(),
		"splash should never damage the attacker's own team")
