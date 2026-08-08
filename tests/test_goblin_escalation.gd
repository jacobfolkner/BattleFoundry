## Tests for the goblin-boss-round death-escalation mechanic (see
## UnitStats.revive_as_on_death/split_into_on_death,
## GameManager._spawn_death_escalation()) -- a normal kill (die() ->
## GameManager._on_unit_died()) that, for these specific archetypes, gets
## replaced by a fresh bigger unit or a fan of smaller ones instead of a
## normal corpse. This is purely the escalation mechanic in isolation --
## the actual "every 3rd round, teams fight this one at a time" sequencing
## (BattleFoundry-Roadmap.md §1) is a separate, not-yet-built layer on top.
extends GutTest

const TANK_STATS: UnitStats = preload("res://Resources/Units/TankStats.tres")
const GOBLIN_STATS: UnitStats = preload("res://Resources/Units/GoblinStats.tres")
const GOBLIN_REVIVED_STATS: UnitStats = preload("res://Resources/Units/GoblinRevivedStats.tres")
const GOBLIN_SPLIT_STATS: UnitStats = preload("res://Resources/Units/GoblinSplitStats.tres")


var _main: Node3D


func before_each() -> void:
	GameManager.reset_battle()
	GameManager.current_mode = ClassicEliminationMode.new() # don't let an earlier test's mode leak in
	var blue := GameManager.get_player(GameManager.BLUE_TEAM_ID)
	blue.blood_points = 0
	_main = load("res://Scenes/Main.tscn").instantiate()
	add_child_autofree(_main)
	await wait_physics_frames(2)


func _units_with_stats(stats: UnitStats) -> Array[Unit]:
	return GameManager.get_all_units().filter(func(u: Unit) -> bool: return u.stats == stats)


func test_killing_a_goblin_revives_it_as_the_bigger_enraged_goblin() -> void:
	var blue := GameManager.get_player(GameManager.BLUE_TEAM_ID)
	var goblin := GameManager.spawn_unit(GOBLIN_STATS, blue, Vector3(5, 0, 5))

	goblin.take_damage(DamageInstance.new(goblin.stat_block.max_health() + 100.0))

	var revived := _units_with_stats(GOBLIN_REVIVED_STATS)
	assert_eq(revived.size(), 1, "killing the base goblin should spawn exactly one Enraged Goblin")
	assert_almost_eq(revived[0].global_position.x, 5.0, 0.05)
	assert_almost_eq(revived[0].global_position.z, 5.0, 0.05)
	assert_eq(revived[0].player, blue, "the revived goblin should stay owned by the same Player as the original")


func test_killing_the_enraged_goblin_splits_it_into_two_runts() -> void:
	var blue := GameManager.get_player(GameManager.BLUE_TEAM_ID)
	var enraged := GameManager.spawn_unit(GOBLIN_REVIVED_STATS, blue, Vector3(-2, 0, 4))

	enraged.take_damage(DamageInstance.new(enraged.stat_block.max_health() + 100.0))

	var runts := _units_with_stats(GOBLIN_SPLIT_STATS)
	assert_eq(runts.size(), GOBLIN_REVIVED_STATS.split_count, "killing the Enraged Goblin should split it into split_count runts")
	assert_ne(runts[0].global_position, runts[1].global_position, "the two runts shouldn't spawn stacked on the same point")


func test_killing_a_goblin_runt_ends_the_escalation() -> void:
	var blue := GameManager.get_player(GameManager.BLUE_TEAM_ID)
	var runt := GameManager.spawn_unit(GOBLIN_SPLIT_STATS, blue, Vector3(1, 0, 1))
	var units_before := GameManager.get_all_units().size()

	runt.take_damage(DamageInstance.new(runt.stat_block.max_health() + 100.0))

	assert_eq(GameManager.get_all_units().size(), units_before, "a runt's death is final -- no further spawn")


## Full chain, one continuous kill count: base goblin -> Enraged Goblin ->
## 2 runts is 4 kills total, each granting blood points independently
## through the existing on_unit_killed() plumbing -- no special-case
## "boss kill bonus" code needed for the "big blood-point payout" the
## roadmap describes.
func test_full_escalation_chain_grants_blood_points_for_every_kill_in_the_chain() -> void:
	GameManager.set_mode(BloodTournamentMode.new())
	var blue := GameManager.get_player(GameManager.BLUE_TEAM_ID)
	var killer := GameManager.spawn_unit(TANK_STATS, blue, Vector3(0, 0, 0))
	var goblin := GameManager.spawn_unit(GOBLIN_STATS, blue, Vector3(2, 0, 0))

	goblin.take_damage(DamageInstance.new(goblin.stat_block.max_health() + 100.0, killer))
	var enraged := _units_with_stats(GOBLIN_REVIVED_STATS)[0]
	enraged.take_damage(DamageInstance.new(enraged.stat_block.max_health() + 100.0, killer))
	var runts := _units_with_stats(GOBLIN_SPLIT_STATS)
	for runt in runts:
		runt.take_damage(DamageInstance.new(runt.stat_block.max_health() + 100.0, killer))

	assert_eq(blue.blood_points, 4 * BloodTournamentMode.KILL_BLOOD_POINTS, "4 kills in the chain (goblin, enraged, 2 runts) should each grant blood points")


func test_normal_archetypes_are_unaffected_by_death_escalation() -> void:
	var blue := GameManager.get_player(GameManager.BLUE_TEAM_ID)
	var tank := GameManager.spawn_unit(TANK_STATS, blue, Vector3(0, 0, 0))
	var units_before := GameManager.get_all_units().size()

	tank.take_damage(DamageInstance.new(tank.stat_block.max_health() + 100.0))

	assert_eq(GameManager.get_all_units().size(), units_before, "TankStats has no revive/split fields set -- a normal death, nothing extra spawns")
