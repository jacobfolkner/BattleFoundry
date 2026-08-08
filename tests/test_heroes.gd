## Tests for roadmap Phase 4, v1 scope: Unit.gain_xp()/leveling
## (UnitStats.is_hero) and ability_unlock_levels gating cast_ability() --
## deliberately just XP-on-kill, flat per-level stat growth, and
## level-gated abilities reusing the existing Ability/Effect framework, no
## more. Explicitly out of scope for this slice (same "prove the
## mechanic" framing every other v1 system in this project has shipped
## with): respawn, buyback, attributes as a separate currency, and a
## random ability draft/choice UI.
extends GutTest

const TANK_STATS: UnitStats = preload("res://Resources/Units/TankStats.tres")
const FIGHTER_STATS: UnitStats = preload("res://Resources/Units/FighterStats.tres")
const HERO_STATS: UnitStats = preload("res://Resources/Units/HeroStats.tres")

var _main: Node3D


func before_each() -> void:
	GameManager.reset_battle()
	GameManager.current_mode = ClassicEliminationMode.new()
	_main = load("res://Scenes/Main.tscn").instantiate()
	add_child_autofree(_main)
	await wait_physics_frames(2)


func test_gain_xp_is_a_no_op_for_a_non_hero_unit() -> void:
	var tank := GameManager.spawn_unit(TANK_STATS, GameManager.get_player(GameManager.BLUE_TEAM_ID), Vector3.ZERO)

	tank.gain_xp(1000.0)

	assert_eq(tank.level, 1)
	assert_eq(tank.xp, 0.0)


func test_killing_an_enemy_awards_xp_only_to_a_hero_killer() -> void:
	var blue := GameManager.get_player(GameManager.BLUE_TEAM_ID)
	var red := GameManager.get_player(GameManager.RED_TEAM_ID)
	var hero := GameManager.spawn_unit(HERO_STATS, blue, Vector3.ZERO)
	var victim := GameManager.spawn_unit(FIGHTER_STATS, red, Vector3(1, 0, 0))
	GameManager.start_battle()

	victim.take_damage(DamageInstance.new(victim.stat_block.max_health() + 100.0, hero))

	assert_eq(hero.xp, Unit.XP_PER_KILL)


func test_killing_an_enemy_with_a_non_hero_killer_does_not_crash_or_grant_xp() -> void:
	var blue := GameManager.get_player(GameManager.BLUE_TEAM_ID)
	var red := GameManager.get_player(GameManager.RED_TEAM_ID)
	var tank := GameManager.spawn_unit(TANK_STATS, blue, Vector3.ZERO)
	var victim := GameManager.spawn_unit(FIGHTER_STATS, red, Vector3(1, 0, 0))
	GameManager.start_battle()

	victim.take_damage(DamageInstance.new(victim.stat_block.max_health() + 100.0, tank))

	assert_eq(tank.level, 1) # sanity: gain_xp() no-ops for a non-hero, this just proves _on_unit_died() didn't error calling it


func test_enough_xp_levels_up_grows_stats_and_fully_heals() -> void:
	var hero := GameManager.spawn_unit(HERO_STATS, GameManager.get_player(GameManager.BLUE_TEAM_ID), Vector3.ZERO)
	var original_max_health := hero.stat_block.max_health()
	var original_damage := hero.stat_block.damage()
	var original_armor := hero.stat_block.armor()
	hero.current_health = 1.0 # simulate being nearly dead before the level-up heal

	hero.gain_xp(hero.get_xp_to_next_level()) # exactly enough for level 1 -> 2 (100 XP)

	assert_eq(hero.level, 2)
	assert_eq(hero.xp, 0.0)
	assert_almost_eq(hero.stat_block.max_health(), original_max_health + 20.0, 0.01)
	assert_almost_eq(hero.stat_block.damage(), original_damage + 3.0, 0.01)
	assert_almost_eq(hero.stat_block.armor(), original_armor + 1.0, 0.01)
	assert_almost_eq(hero.current_health, hero.stat_block.max_health(), 0.01, "leveling up should fully heal, not leave the hero at 1 HP out of a bigger pool")


func test_a_single_large_xp_grant_can_carry_a_hero_through_multiple_levels() -> void:
	var hero := GameManager.spawn_unit(HERO_STATS, GameManager.get_player(GameManager.BLUE_TEAM_ID), Vector3.ZERO)

	hero.gain_xp(100.0 + 200.0 + 50.0) # level 1->2 (100) + 2->3 (200), 50 XP left over toward 3->4

	assert_eq(hero.level, 3)
	assert_almost_eq(hero.xp, 50.0, 0.01)


func test_ability_unlock_levels_gates_casting_until_the_required_level() -> void:
	var hero := GameManager.spawn_unit(HERO_STATS, GameManager.get_player(GameManager.BLUE_TEAM_ID), Vector3.ZERO)
	GameManager.spawn_unit(TANK_STATS, GameManager.get_player(GameManager.RED_TEAM_ID), Vector3(1, 0, 0))

	assert_false(hero.cast_ability(1), "Ground Slam (slot 1) requires level 2 -- the hero starts at level 1")

	hero.gain_xp(hero.get_xp_to_next_level())
	assert_eq(hero.level, 2)

	assert_true(hero.cast_ability(1), "Ground Slam should be castable once the hero reaches level 2")


func test_level_1_ability_is_available_immediately() -> void:
	var hero := GameManager.spawn_unit(HERO_STATS, GameManager.get_player(GameManager.BLUE_TEAM_ID), Vector3.ZERO)
	var target := GameManager.spawn_unit(TANK_STATS, GameManager.get_player(GameManager.RED_TEAM_ID), Vector3(1, 0, 0))

	assert_true(hero.cast_ability(0, target), "Cleave Strike (slot 0) unlocks at level 1, available from spawn")


## Regression guard: a non-hero archetype's empty ability_unlock_levels
## array must never gate anything -- Unit.cast_ability()'s gate check only
## applies when stats.is_hero is true.
func test_non_hero_abilities_are_never_level_gated() -> void:
	var tank := GameManager.spawn_unit(TANK_STATS, GameManager.get_player(GameManager.BLUE_TEAM_ID), Vector3.ZERO)
	GameManager.spawn_unit(FIGHTER_STATS, GameManager.get_player(GameManager.RED_TEAM_ID), Vector3(2, 0, 0))

	assert_true(tank.cast_ability(0), "Tank's War Stomp should cast normally -- Tank isn't a hero and has no unlock levels")


## The hero's always-on aura (see UnitStats.aura_ability) doesn't go
## through the level-gate at all in this v1 (only stats.abilities does) --
## it's active from spawn like any other archetype's aura would be.
func test_hero_aura_is_active_from_spawn_regardless_of_level() -> void:
	var blue := GameManager.get_player(GameManager.BLUE_TEAM_ID)
	var hero := GameManager.spawn_unit(HERO_STATS, blue, Vector3.ZERO)
	var ally := GameManager.spawn_unit(TANK_STATS, blue, Vector3(2, 0, 0))

	for i in range(20): # comfortably past Unit._AURA_TICK_INTERVAL (0.25s)
		await wait_physics_frames(1)

	assert_almost_eq(ally.stat_block.armor(), TANK_STATS.armor + 1.0, 0.01, "Aura of Vigor should already be buffing allies at level 1")
