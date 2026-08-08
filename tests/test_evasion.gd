## Tests for UnitStats.evasion -- roadmap Phase 2's fifth combat-depth
## item. Only tests the two deterministic boundary values (0.0 always
## lands, 1.0 always evades, since randf() < 1.0 is guaranteed true and
## randf() < 0.0 is guaranteed false) rather than seeding/asserting on
## the RNG statistically -- no other system in this project seeds or
## asserts on exact random outcomes (see AIController's own random
## archetype/upgrade picks, tested only for invariants like "never goes
## negative," never for a specific roll), and the boundary values already
## give full deterministic coverage of the branch itself.
extends GutTest

var _main: Node3D


func before_each() -> void:
	GameManager.reset_battle()
	GameManager.current_mode = ClassicEliminationMode.new()
	_main = load("res://Scenes/Main.tscn").instantiate()
	add_child_autofree(_main)
	await wait_physics_frames(2)


func test_zero_evasion_always_takes_attack_damage() -> void:
	var defender_stats := UnitStats.new()
	defender_stats.evasion = 0.0
	var defender := GameManager.spawn_unit(defender_stats, GameManager.get_player(GameManager.BLUE_TEAM_ID), Vector3.ZERO)

	var hit_landed := defender.take_damage(DamageInstance.new(20.0, null, DamageInstance.DamageType.ATTACK))

	assert_true(hit_landed)
	assert_eq(defender.current_health, defender_stats.max_health - 20.0)


func test_full_evasion_always_avoids_attack_damage() -> void:
	var defender_stats := UnitStats.new()
	defender_stats.evasion = 1.0
	var defender := GameManager.spawn_unit(defender_stats, GameManager.get_player(GameManager.BLUE_TEAM_ID), Vector3.ZERO)

	var hit_landed := defender.take_damage(DamageInstance.new(20.0, null, DamageInstance.DamageType.ATTACK))

	assert_false(hit_landed)
	assert_eq(defender.current_health, defender_stats.max_health, "a fully-evaded attack should deal no damage at all")


func test_full_evasion_does_not_apply_to_spell_damage() -> void:
	var defender_stats := UnitStats.new()
	defender_stats.evasion = 1.0
	var defender := GameManager.spawn_unit(defender_stats, GameManager.get_player(GameManager.BLUE_TEAM_ID), Vector3.ZERO)

	var hit_landed := defender.take_damage(DamageInstance.new(20.0, null, DamageInstance.DamageType.SPELL))

	assert_true(hit_landed, "evasion should only ever apply to ATTACK damage, matching WC3's own convention")
	assert_eq(defender.current_health, defender_stats.max_health - 20.0)


func test_full_evasion_does_not_apply_to_pure_damage() -> void:
	var defender_stats := UnitStats.new()
	defender_stats.evasion = 1.0
	var defender := GameManager.spawn_unit(defender_stats, GameManager.get_player(GameManager.BLUE_TEAM_ID), Vector3.ZERO)

	var hit_landed := defender.take_damage(DamageInstance.new(20.0, null, DamageInstance.DamageType.PURE))

	assert_true(hit_landed)
	assert_eq(defender.current_health, defender_stats.max_health - 20.0)


## resolve_hit() is where splash/on_hit_ability get gated on whether the
## hit actually landed -- confirms a fully-evaded primary attack doesn't
## splash onto a nearby enemy either, since nothing should fire off an
## attack that never connected.
func test_a_fully_evaded_attack_does_not_splash_onto_a_nearby_enemy() -> void:
	var attacker_stats := UnitStats.new()
	attacker_stats.damage = 10.0
	attacker_stats.splash_radius = 5.0
	var attacker := GameManager.spawn_unit(attacker_stats, GameManager.get_player(GameManager.BLUE_TEAM_ID), Vector3.ZERO)

	var primary_stats := UnitStats.new()
	primary_stats.evasion = 1.0
	var primary := GameManager.spawn_unit(primary_stats, GameManager.get_player(GameManager.RED_TEAM_ID), Vector3(10, 0, 0))
	var nearby := GameManager.spawn_unit(UnitStats.new(), GameManager.get_player(GameManager.RED_TEAM_ID), Vector3(11, 0, 0))

	attacker.resolve_hit(primary, attacker.global_position)

	assert_eq(primary.current_health, primary.stat_block.max_health(), "the evaded primary target should take no damage")
	assert_eq(nearby.current_health, nearby.stat_block.max_health(), "a miss on the primary target should not splash onto anyone else")
