## Tests for UnitStats.crit_chance/crit_multiplier -- roadmap Phase 2's
## sixth and final combat-depth item. Same boundary-value approach as
## test_evasion.gd (0.0/1.0 are both deterministic, no RNG seeding
## needed) and the same direct-call style as the rest of this phase's
## tests (attacker.resolve_hit(target, source) called directly).
extends GutTest

var _main: Node3D


func before_each() -> void:
	GameManager.reset_battle()
	GameManager.current_mode = ClassicEliminationMode.new()
	_main = load("res://Scenes/Main.tscn").instantiate()
	add_child_autofree(_main)
	await wait_physics_frames(2)


func test_zero_crit_chance_never_multiplies_damage() -> void:
	var attacker_stats := UnitStats.new()
	attacker_stats.damage = 10.0
	attacker_stats.crit_chance = 0.0
	var attacker := GameManager.spawn_unit(attacker_stats, GameManager.get_player(GameManager.BLUE_TEAM_ID), Vector3.ZERO)
	var target := GameManager.spawn_unit(UnitStats.new(), GameManager.get_player(GameManager.RED_TEAM_ID), Vector3(1, 0, 0))

	attacker.resolve_hit(target, attacker.global_position)

	assert_eq(target.current_health, target.stat_block.max_health() - 10.0)


func test_full_crit_chance_always_multiplies_damage() -> void:
	var attacker_stats := UnitStats.new()
	attacker_stats.damage = 10.0
	attacker_stats.crit_chance = 1.0
	attacker_stats.crit_multiplier = 3.0
	var attacker := GameManager.spawn_unit(attacker_stats, GameManager.get_player(GameManager.BLUE_TEAM_ID), Vector3.ZERO)
	var target := GameManager.spawn_unit(UnitStats.new(), GameManager.get_player(GameManager.RED_TEAM_ID), Vector3(1, 0, 0))

	attacker.resolve_hit(target, attacker.global_position)

	assert_eq(target.current_health, target.stat_block.max_health() - 30.0,
		"crit_chance == 1.0 should always deal crit_multiplier x damage")


## Armor mitigation should apply AFTER the crit multiplier, matching
## WC3's own ordering (crit multiplies the raw hit, armor reduces
## whatever comes out of that) -- not "crit the already-mitigated
## amount."
func test_crit_multiplies_damage_before_armor_mitigation_applies() -> void:
	var attacker_stats := UnitStats.new()
	attacker_stats.damage = 10.0
	attacker_stats.crit_chance = 1.0
	attacker_stats.crit_multiplier = 2.0
	var attacker := GameManager.spawn_unit(attacker_stats, GameManager.get_player(GameManager.BLUE_TEAM_ID), Vector3.ZERO)
	var target := GameManager.spawn_unit(UnitStats.new(), GameManager.get_player(GameManager.RED_TEAM_ID), Vector3(1, 0, 0))
	target.stat_block.base_armor = 5.0

	attacker.resolve_hit(target, attacker.global_position)

	# (10 * 2) - 5 == 15, not (10 - 5) * 2 == 10
	assert_eq(target.current_health, target.stat_block.max_health() - 15.0)


## A crit's splash damage should scale the same way as its primary hit --
## one crit roll per swing, not a separate roll per splashed target.
func test_a_critical_hit_also_multiplies_its_splash_damage() -> void:
	var attacker_stats := UnitStats.new()
	attacker_stats.damage = 10.0
	attacker_stats.crit_chance = 1.0
	attacker_stats.crit_multiplier = 2.0
	attacker_stats.splash_radius = 5.0
	attacker_stats.splash_falloff = 0.5
	var attacker := GameManager.spawn_unit(attacker_stats, GameManager.get_player(GameManager.BLUE_TEAM_ID), Vector3.ZERO)
	var primary := GameManager.spawn_unit(UnitStats.new(), GameManager.get_player(GameManager.RED_TEAM_ID), Vector3(10, 0, 0))
	var splashed := GameManager.spawn_unit(UnitStats.new(), GameManager.get_player(GameManager.RED_TEAM_ID), Vector3(15, 0, 0)) # exactly at the 5.0 radius edge -- splash_falloff applies in full

	attacker.resolve_hit(primary, attacker.global_position)

	assert_eq(primary.current_health, primary.stat_block.max_health() - 20.0, "primary target should take the full crit damage (10 * 2)")
	assert_eq(splashed.current_health, splashed.stat_block.max_health() - 10.0, "splashed unit should take the crit-scaled damage times splash_falloff (10 * 2 * 0.5)")
