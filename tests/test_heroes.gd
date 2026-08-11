## Tests for roadmap Phase 4: Unit.gain_xp()/leveling (UnitStats.is_hero),
## ability_unlock_levels gating cast_ability(), and Player.hero_progress/
## Unit.restore_hero_progress() (a hero's level/XP surviving a Blood
## Tournament round boundary -- "heroes spawn alongside units," not a
## separate mid-battle respawn timer; see Player.hero_progress's own doc
## comment for why). Explicitly still out of scope (same "prove the
## mechanic" framing every other v1 system in this project has shipped
## with): buyback, attributes as a separate currency, and a random
## ability draft/choice UI.
extends GutTest

const TANK_STATS: UnitStats = preload("res://Resources/Units/TankStats.tres")
const FIGHTER_STATS: UnitStats = preload("res://Resources/Units/FighterStats.tres")
const HERO_STATS: UnitStats = preload("res://Resources/Units/HeroStats.tres")

var _main: Node3D


func before_each() -> void:
	GameManager.reset_battle()
	GameManager.current_mode = ClassicEliminationMode.new()
	# Player is a persistent autoload-owned object, never recreated
	# between tests -- hero_progress left by an earlier test in this file
	# (or any other) would otherwise leak into whichever test runs next,
	# same cross-test-pollution category current_mode/resources/roster
	# already needed this treatment for elsewhere in this project.
	GameManager.get_player(GameManager.BLUE_TEAM_ID).hero_progress.clear()
	GameManager.get_player(GameManager.RED_TEAM_ID).hero_progress.clear()
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


# ---------------------------------------------------------------------
# Hero progress persistence (Player.hero_progress) -- "heroes spawn
# alongside units," across a Blood Tournament round boundary
# ---------------------------------------------------------------------

func test_gain_xp_persists_progress_to_the_owning_players_hero_progress() -> void:
	var blue := GameManager.get_player(GameManager.BLUE_TEAM_ID)
	var hero := GameManager.spawn_unit(HERO_STATS, blue, Vector3.ZERO)

	hero.gain_xp(150.0) # 100 to hit level 2, 50 left over toward level 3

	assert_true(blue.hero_progress.has(HERO_STATS))
	assert_eq(blue.hero_progress[HERO_STATS].level, 2)
	assert_almost_eq(blue.hero_progress[HERO_STATS].xp, 50.0, 0.01)


func test_restore_hero_progress_fast_forwards_a_fresh_units_level_stats_and_xp() -> void:
	var hero := GameManager.spawn_unit(HERO_STATS, GameManager.get_player(GameManager.BLUE_TEAM_ID), Vector3.ZERO)
	var base_max_health := hero.stat_block.max_health()
	var base_damage := hero.stat_block.damage()
	var base_armor := hero.stat_block.armor()

	hero.restore_hero_progress(3, 50.0) # as if this hero had already reached level 3 with 50 XP banked

	assert_eq(hero.level, 3)
	assert_almost_eq(hero.xp, 50.0, 0.01)
	assert_almost_eq(hero.stat_block.max_health(), base_max_health + 40.0, 0.01, "two levels' worth of growth (1->2, 2->3) should have applied")
	assert_almost_eq(hero.stat_block.damage(), base_damage + 6.0, 0.01)
	assert_almost_eq(hero.stat_block.armor(), base_armor + 2.0, 0.01)
	assert_almost_eq(hero.current_health, hero.stat_block.max_health(), 0.01, "restoring progress should leave the hero at full health, same as a normal level-up")


func test_restore_hero_progress_is_a_no_op_for_a_non_hero_unit() -> void:
	var tank := GameManager.spawn_unit(TANK_STATS, GameManager.get_player(GameManager.BLUE_TEAM_ID), Vector3.ZERO)

	tank.restore_hero_progress(5, 999.0)

	assert_eq(tank.level, 1)
	assert_eq(tank.xp, 0.0)


## End-to-end through the real lineup-courtyard flow, not a direct
## restore_hero_progress() call -- proves
## GameManager.sync_courtyard_to_roster() actually wires
## Player.hero_progress into a freshly-spawned courtyard hero, across a
## real round boundary (GameManager.reset_battle() frees the old hero
## Unit entirely, same as it would between any two Blood Tournament
## rounds). Drives sync_courtyard_to_roster() directly rather than
## GameManager.start_battle() -- Blood Tournament is is_auto_battle(), so
## a real battle would have the hero autonomously fight and possibly land
## a kill (Unit.XP_PER_KILL), making the exact XP numbers this test
## asserts on non-deterministic for a reason entirely unrelated to what's
## actually being tested here.
func test_a_hero_that_leveled_up_keeps_its_level_after_the_next_rounds_redeployment() -> void:
	GameManager.set_mode(BloodTournamentMode.new())
	var blue := GameManager.get_player(GameManager.BLUE_TEAM_ID)
	blue.roster = [HERO_STATS]

	GameManager.sync_courtyard_to_roster(blue)
	var round_one_hero: Unit = blue.courtyard_units[0][0]
	round_one_hero.gain_xp(250.0) # level 1 -> 2, 150 XP left over

	GameManager.reset_battle() # frees round_one_hero entirely, same as a real round boundary
	GameManager.sync_courtyard_to_roster(blue)
	var round_two_hero: Unit = blue.courtyard_units[0][0]

	assert_ne(round_two_hero, round_one_hero, "sanity check: this really is a fresh Unit instance, not the same one surviving")
	assert_eq(round_two_hero.level, 2, "the hero's level should carry over into the next round's redeployment")
	assert_almost_eq(round_two_hero.xp, 150.0, 0.01)
