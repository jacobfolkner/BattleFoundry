## Tests for UnitStats.turn_rate / Unit._face_toward()/_attack()'s facing
## gate -- roadmap Phase 2's fourth combat-depth item. Same direct-call
## style as test_attack_windup.gd/test_splash_damage.gd: calls
## attacker._attack(delta) with target_enemy set by hand so timing can be
## asserted exactly instead of inferred from a physics-frame budget.
extends GutTest

var _main: Node3D


func before_each() -> void:
	GameManager.reset_battle()
	GameManager.current_mode = ClassicEliminationMode.new()
	_main = load("res://Scenes/Main.tscn").instantiate()
	add_child_autofree(_main)
	await wait_physics_frames(2)


func test_zero_turn_rate_attacks_immediately_regardless_of_facing() -> void:
	var instant_stats := UnitStats.new()
	instant_stats.damage = 10.0
	var attacker := GameManager.spawn_unit(instant_stats, GameManager.get_player(GameManager.BLUE_TEAM_ID), Vector3.ZERO)
	# rotation.y left at its default 0.0 -- Node3D's unrotated forward is
	# -Z, so this attacker is already facing directly away from a target
	# placed at +Z below.
	var target := GameManager.spawn_unit(UnitStats.new(), GameManager.get_player(GameManager.RED_TEAM_ID), Vector3(0, 0, 1))
	attacker.target_enemy = target

	attacker._attack(0.0)

	assert_eq(target.current_health, target.stat_block.max_health() - 10.0,
		"turn_rate == 0.0 should never gate an attack on facing")


func test_nonzero_turn_rate_withholds_the_attack_until_facing_the_target() -> void:
	var turning_stats := UnitStats.new()
	turning_stats.damage = 10.0
	turning_stats.turn_rate = 90.0 # degrees/sec -- a 180 deg turn takes 2s
	var attacker := GameManager.spawn_unit(turning_stats, GameManager.get_player(GameManager.BLUE_TEAM_ID), Vector3.ZERO)
	# rotation.y left at its default 0.0 -- facing directly away from a
	# target placed at +Z below (see the previous test's comment).
	var target := GameManager.spawn_unit(UnitStats.new(), GameManager.get_player(GameManager.RED_TEAM_ID), Vector3(0, 0, 1))
	attacker.target_enemy = target

	attacker._attack(0.5) # only a quarter of the 2s turn has elapsed

	assert_eq(target.current_health, target.stat_block.max_health(),
		"the attack should not land before the unit has finished turning to face its target")


func test_nonzero_turn_rate_attacks_once_facing_is_acquired() -> void:
	var turning_stats := UnitStats.new()
	turning_stats.damage = 10.0
	turning_stats.turn_rate = 90.0
	var attacker := GameManager.spawn_unit(turning_stats, GameManager.get_player(GameManager.BLUE_TEAM_ID), Vector3.ZERO)
	# rotation.y left at its default 0.0 -- facing directly away from a
	# target placed at +Z below.
	var target := GameManager.spawn_unit(UnitStats.new(), GameManager.get_player(GameManager.RED_TEAM_ID), Vector3(0, 0, 1))
	attacker.target_enemy = target

	for i in range(5): # 5 * 0.5s == 2.5s, comfortably past the 2s turn
		attacker._attack(0.5)

	assert_eq(target.current_health, target.stat_block.max_health() - 10.0,
		"the attack should land once the unit has finished turning to face its target")


func test_already_facing_the_target_attacks_without_any_turning_delay() -> void:
	var turning_stats := UnitStats.new()
	turning_stats.damage = 10.0
	turning_stats.turn_rate = 90.0
	var attacker := GameManager.spawn_unit(turning_stats, GameManager.get_player(GameManager.BLUE_TEAM_ID), Vector3.ZERO)
	var target := GameManager.spawn_unit(UnitStats.new(), GameManager.get_player(GameManager.RED_TEAM_ID), Vector3(0, 0, 1))
	attacker.look_at(target.global_position, Vector3.UP) # already facing the target
	attacker.target_enemy = target

	attacker._attack(0.0)

	assert_eq(target.current_health, target.stat_block.max_health() - 10.0,
		"a unit already facing its target should attack immediately, no turning needed")
