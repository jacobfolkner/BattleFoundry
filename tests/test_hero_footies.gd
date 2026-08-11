## Tests for HeroFootiesMode (roadmap Phase 6): thrones spawning at battle
## start, the throne-HP win/draw condition, and the automatic wave-spawner
## (Scripts/GameModes/HeroFootiesMode.gd).
extends GutTest

const FOOTMAN_STATS: UnitStats = preload("res://Resources/Units/FootmanStats.tres")
const THRONE_STATS: UnitStats = preload("res://Resources/Units/ThroneStats.tres")
const TANK_STATS: UnitStats = preload("res://Resources/Units/TankStats.tres")

var _main: Node3D


func before_each() -> void:
	GameManager.reset_battle()
	GameManager.current_mode = ClassicEliminationMode.new() # GameManager is an autoload -- don't let a mode set by an earlier test leak into this one
	_main = load("res://Scenes/Main.tscn").instantiate()
	add_child_autofree(_main)
	await wait_physics_frames(2)


## Placing one unit per side (any archetype -- there's no economy/roster
## gate, same free placement ClassicEliminationMode already has) is enough
## to satisfy the inherited GameMode.can_start_battle() default.
func _place_one_unit_per_side() -> void:
	GameManager.spawn_unit(TANK_STATS, GameManager.get_player(GameManager.BLUE_TEAM_ID), Vector3(-3, 0, -10))
	GameManager.spawn_unit(TANK_STATS, GameManager.get_player(GameManager.RED_TEAM_ID), Vector3(3, 0, 10))


func test_defaults_stay_manual_free_placement_on_the_plain_square_arena() -> void:
	var mode := HeroFootiesMode.new()
	assert_false(mode.is_auto_battle(), "the human player commands their own units manually, unlike Blood Tournament")
	assert_false(mode.uses_economy(), "free placement, same as ClassicEliminationMode")
	assert_false(mode.uses_cross_map())
	assert_true(mode.get_arena_map() is SquareArenaMap)


func test_thrones_spawn_for_both_teams_once_battle_starts() -> void:
	var mode := HeroFootiesMode.new()
	GameManager.set_mode(mode)
	_place_one_unit_per_side()

	assert_null(mode.blue_throne, "a throne shouldn't exist before the battle starts")
	GameManager.start_battle()

	assert_true(is_instance_valid(mode.blue_throne))
	assert_true(is_instance_valid(mode.red_throne))
	assert_eq(mode.blue_throne.stats, THRONE_STATS)
	assert_eq(mode.blue_throne.player.team_id, GameManager.BLUE_TEAM_ID)
	assert_eq(mode.red_throne.player.team_id, GameManager.RED_TEAM_ID)
	assert_almost_eq(mode.blue_throne.current_health, THRONE_STATS.max_health, 0.01)


func test_destroying_a_throne_ends_the_battle_for_the_other_team() -> void:
	var mode := HeroFootiesMode.new()
	GameManager.set_mode(mode)
	_place_one_unit_per_side()
	GameManager.start_battle()
	watch_signals(GameManager)

	mode.blue_throne.take_damage(DamageInstance.new(THRONE_STATS.max_health + 100.0))

	assert_true(GameManager.is_game_over())
	assert_signal_emitted_with_parameters(GameManager, "battle_ended", [GameManager.RED_TEAM_ID, false])


func test_both_thrones_falling_at_once_is_a_draw() -> void:
	var mode := HeroFootiesMode.new()
	GameManager.set_mode(mode)
	_place_one_unit_per_side()
	GameManager.start_battle()

	# Not two real die() calls: the first one alone already ends the
	# battle for real (GameManager._on_unit_died() -> check_victory() sees
	# only one throne down and declares the other team the winner right
	# there), which would call on_battle_ended() and null out both throne
	# refs before the second die() ever ran. check_victory() itself is
	# what needs proving here -- setting life_state directly (bypassing
	# the death event pipeline entirely) isolates it, same "direct call
	# for exactness" style test_game_modes.gd's own draw test uses.
	mode.blue_throne.life_state = Unit.LifeState.DEAD
	mode.red_throne.life_state = Unit.LifeState.DEAD

	var result := mode.check_victory()
	assert_eq(result["result"], GameMode.VictoryResult.DRAW)


func test_wave_spawner_does_nothing_before_battle_starts() -> void:
	var mode := HeroFootiesMode.new()
	GameManager.set_mode(mode)
	_place_one_unit_per_side()

	mode.tick(1000.0) # way past even a huge wave_interval

	for unit in GameManager.get_all_units():
		assert_ne(unit.stats, FOOTMAN_STATS, "no wave should spawn during PLACEMENT")


func test_wave_spawner_spawns_a_footman_squad_for_each_side_on_an_attack_move_order() -> void:
	var mode := HeroFootiesMode.new()
	mode.wave_interval = 5.0
	GameManager.set_mode(mode)
	_place_one_unit_per_side()
	GameManager.start_battle()

	mode.tick(5.1) # cross the wave_interval threshold in one call

	var blue_footmen := GameManager.get_all_units().filter(
		func(u: Unit) -> bool: return u.stats == FOOTMAN_STATS and u.player.team_id == GameManager.BLUE_TEAM_ID
	)
	var red_footmen := GameManager.get_all_units().filter(
		func(u: Unit) -> bool: return u.stats == FOOTMAN_STATS and u.player.team_id == GameManager.RED_TEAM_ID
	)
	assert_eq(blue_footmen.size(), FOOTMAN_STATS.squad_size)
	assert_eq(red_footmen.size(), FOOTMAN_STATS.squad_size)
	for unit in blue_footmen:
		assert_not_null(unit.current_order)
		assert_eq(unit.current_order.type, Unit.OrderType.ATTACK_MOVE)


func test_wave_spawner_does_not_spawn_again_before_the_next_interval() -> void:
	var mode := HeroFootiesMode.new()
	mode.wave_interval = 5.0
	GameManager.set_mode(mode)
	_place_one_unit_per_side()
	GameManager.start_battle()

	mode.tick(5.1)
	var count_after_first_wave := GameManager.get_all_units().size()
	mode.tick(1.0) # well short of another full wave_interval
	assert_eq(GameManager.get_all_units().size(), count_after_first_wave, "a second wave shouldn't spawn until wave_interval elapses again")


## Integration through the actual HUD button handler (what a player
## clicking "Hero Footies" in the Match card actually triggers), and the
## mutual-exclusivity guard with Blood Tournament -- both toggles claim
## GameManager.current_mode, so turning one on must turn the other off.
func test_toggling_hero_footies_on_switches_the_active_mode() -> void:
	_main._on_hero_footies_toggled(true)
	assert_true(GameManager.current_mode is HeroFootiesMode)


func test_toggling_hero_footies_on_turns_off_an_active_blood_tournament() -> void:
	_main._on_tournament_toggled(true)
	assert_true(GameManager.current_mode is BloodTournamentMode)

	_main._on_hero_footies_toggled(true)
	assert_true(GameManager.current_mode is HeroFootiesMode)


func test_toggling_blood_tournament_on_turns_off_an_active_hero_footies_mode() -> void:
	_main._on_hero_footies_toggled(true)
	assert_true(GameManager.current_mode is HeroFootiesMode)

	_main._on_tournament_toggled(true)
	assert_true(GameManager.current_mode is BloodTournamentMode)
