## Tests for Blood Tournament's economy: starting gold, flat round income
## (equal for everyone, no win bonus), blood points from kills, unit cost,
## sell, and the no-permadeath roster (what actually persists between
## rounds now -- see Scripts/Player.gd's `roster` field and
## Main._respawn_rosters(); round-transition integration for that lives
## in test_game_modes.gd) -- plus its shop upgrades (a blood-point-cost
## permanent Effect applied to an owned unit, reusing
## Ability.cast_unit_target() rather than a new framework -- see
## Scripts/UnitUpgrade.gd/GameManager.buy_upgrade()).
extends GutTest

const TANK_STATS: UnitStats = preload("res://Resources/Units/TankStats.tres")
const FIGHTER_STATS: UnitStats = preload("res://Resources/Units/FighterStats.tres")
const IRON_ARMOR_UPGRADE: UnitUpgrade = preload("res://Resources/Upgrades/IronArmorUpgrade.tres")

var _main: Node3D


func before_each() -> void:
	GameManager.reset_battle()
	GameManager.current_mode = ClassicEliminationMode.new() # don't let an earlier test's mode leak in
	# Player is a plain RefCounted that outlives each test same as GameManager
	# itself -- zero it explicitly so gold/blood-points/roster state from
	# an earlier test (set_mode(BloodTournamentMode.new())'s on_activated()
	# grants STARTING_GOLD, a buy appends to roster, etc.) never leaks
	# into this one's assertions.
	var blue := GameManager.get_player(GameManager.BLUE_TEAM_ID)
	var red := GameManager.get_player(GameManager.RED_TEAM_ID)
	blue.resources = 0
	red.resources = 0
	blue.blood_points = 0
	red.blood_points = 0
	blue.roster.clear()
	red.roster.clear()
	_main = load("res://Scenes/Main.tscn").instantiate()
	add_child_autofree(_main)
	await wait_physics_frames(2)


func test_player_gold_ledger() -> void:
	var player := GameManager.get_player(GameManager.BLUE_TEAM_ID)
	assert_false(player.can_afford(50), "starts at 0 -- nothing is affordable yet")

	player.add_gold(100)
	assert_eq(player.resources, 100)
	assert_true(player.can_afford(100))
	assert_false(player.can_afford(101))

	player.spend(40)
	assert_eq(player.resources, 60)


func test_classic_mode_does_not_use_economy_but_blood_tournament_does() -> void:
	assert_false(GameManager.current_mode.uses_economy())
	assert_true(BloodTournamentMode.new().uses_economy())


## set_mode() -> GameMode.on_activated() is what grants starting gold, not
## BloodTournamentMode's constructor -- see GameMode.on_activated()'s doc
## comment for why that timing matters (it must exist before round 1's
## PLACEMENT phase, which happens before Start Battle / on_battle_started()).
func test_activating_blood_tournament_grants_starting_gold_to_both_teams() -> void:
	GameManager.set_mode(BloodTournamentMode.new())

	assert_eq(GameManager.get_player(GameManager.BLUE_TEAM_ID).resources, BloodTournamentMode.STARTING_GOLD)
	assert_eq(GameManager.get_player(GameManager.RED_TEAM_ID).resources, BloodTournamentMode.STARTING_GOLD)


func test_merely_constructing_blood_tournament_mode_does_not_grant_gold() -> void:
	BloodTournamentMode.new() # never activated via GameManager.set_mode()
	assert_eq(GameManager.get_player(GameManager.BLUE_TEAM_ID).resources, 0)


## Win or draw, income is identical -- see test_round_income_is_flat_and_equal_regardless_of_who_won()
## further down for the direct win-vs-lose comparison.
func test_a_draw_grants_participation_income_same_as_a_win() -> void:
	var mode := BloodTournamentMode.new()
	GameManager.set_mode(mode)
	var blue_before := GameManager.get_player(GameManager.BLUE_TEAM_ID).resources

	mode.on_battle_ended(GameManager.BLUE_TEAM_ID, true)

	assert_eq(GameManager.get_player(GameManager.BLUE_TEAM_ID).resources, blue_before + BloodTournamentMode.PARTICIPATION_INCOME)


## Regression guard: outside Blood Tournament, placement must stay exactly
## as free as it always was, even though Player.resources is a real int
## sitting at 0 by default -- cost is only ever consulted while
## current_mode.uses_economy() is true.
func test_classic_mode_placement_stays_free_regardless_of_gold() -> void:
	_main._try_place_unit(_main.get_viewport().get_visible_rect().size / 2)
	assert_eq(GameManager.get_all_units().size(), 1)
	assert_eq(GameManager.get_player(GameManager.BLUE_TEAM_ID).resources, 0, "classic mode must never spend gold")


func test_blood_tournament_placement_is_blocked_when_unaffordable_and_spends_when_affordable() -> void:
	GameManager.set_mode(BloodTournamentMode.new()) # grants STARTING_GOLD (300)
	GameManager.get_player(GameManager.BLUE_TEAM_ID).resources = TANK_STATS.cost - 1

	var screen_position := _main.get_viewport().get_visible_rect().size / 2
	_main._try_place_unit(screen_position)
	assert_eq(GameManager.get_all_units().size(), 0, "one gold short of Tank's cost should block placement")

	GameManager.get_player(GameManager.BLUE_TEAM_ID).resources = TANK_STATS.cost
	_main._try_place_unit(screen_position)
	assert_eq(GameManager.get_all_units().size(), 1, "exactly enough gold should place it")
	assert_eq(GameManager.get_player(GameManager.BLUE_TEAM_ID).resources, 0, "the Tank's cost should be spent")


func test_selling_a_unit_removes_it_and_refunds_only_when_economy_is_active() -> void:
	var blue := GameManager.get_player(GameManager.BLUE_TEAM_ID)
	var unit := GameManager.spawn_unit(TANK_STATS, blue, Vector3(-3, 0, 0))

	GameManager.sell_unit(unit) # classic mode: no economy, no refund
	assert_true(unit.is_queued_for_deletion())
	assert_eq(blue.resources, 0)

	GameManager.set_mode(BloodTournamentMode.new())
	var second_unit := GameManager.spawn_unit(TANK_STATS, blue, Vector3(-3, 0, 0))
	var gold_before := blue.resources

	GameManager.sell_unit(second_unit)

	assert_true(second_unit.is_queued_for_deletion())
	assert_eq(blue.resources, gold_before + int(TANK_STATS.cost * GameManager.SELL_REFUND_FRACTION))


func test_selling_only_works_during_placement() -> void:
	var blue := GameManager.get_player(GameManager.BLUE_TEAM_ID)
	var red := GameManager.get_player(GameManager.RED_TEAM_ID)
	var unit := GameManager.spawn_unit(TANK_STATS, blue, Vector3(-3, 0, 0))
	GameManager.spawn_unit(FIGHTER_STATS, red, Vector3(3, 0, 0))
	GameManager.start_battle()

	GameManager.sell_unit(unit)

	assert_false(unit.is_queued_for_deletion(), "sell_unit should no-op once BATTLE has started")


func test_right_click_on_owned_unit_sells_it_during_placement() -> void:
	var blue := GameManager.get_player(GameManager.BLUE_TEAM_ID)
	GameManager.set_mode(BloodTournamentMode.new())
	var unit := GameManager.spawn_unit(TANK_STATS, blue, Vector3(-3, 0, 0))
	await wait_physics_frames(1) # let the physics server register the new collision shape before raycasting it
	var camera: Camera3D = _main.get_node("Camera3D")
	var gold_before := blue.resources

	_main._try_sell_unit_at(camera.unproject_position(unit.global_position))

	assert_true(unit.is_queued_for_deletion())
	assert_eq(blue.resources, gold_before + int(TANK_STATS.cost * GameManager.SELL_REFUND_FRACTION))


func test_buy_upgrade_spends_blood_points_and_applies_a_permanent_effect() -> void:
	GameManager.set_mode(BloodTournamentMode.new())
	var blue := GameManager.get_player(GameManager.BLUE_TEAM_ID)
	blue.blood_points = IRON_ARMOR_UPGRADE.cost
	var unit := GameManager.spawn_unit(TANK_STATS, blue, Vector3(-3, 0, 0))
	var original_armor := unit.stat_block.armor()
	var blood_points_before := blue.blood_points

	var bought := GameManager.buy_upgrade(unit, IRON_ARMOR_UPGRADE)

	assert_true(bought)
	assert_eq(blue.blood_points, blood_points_before - IRON_ARMOR_UPGRADE.cost)
	assert_almost_eq(unit.stat_block.armor(), original_armor + IRON_ARMOR_UPGRADE.ability.effect_stat_value, 0.01)


func test_buy_upgrade_fails_outside_blood_tournament_and_without_enough_blood_points() -> void:
	var blue := GameManager.get_player(GameManager.BLUE_TEAM_ID)
	var unit := GameManager.spawn_unit(TANK_STATS, blue, Vector3(-3, 0, 0))

	assert_false(GameManager.buy_upgrade(unit, IRON_ARMOR_UPGRADE), "classic mode doesn't use economy at all")

	GameManager.set_mode(BloodTournamentMode.new())
	unit = GameManager.spawn_unit(TANK_STATS, blue, Vector3(-3, 0, 0))
	blue.blood_points = IRON_ARMOR_UPGRADE.cost - 1

	assert_false(GameManager.buy_upgrade(unit, IRON_ARMOR_UPGRADE), "one blood point short should fail the purchase")
	assert_eq(blue.blood_points, IRON_ARMOR_UPGRADE.cost - 1, "a failed purchase must not spend anything")


func test_upgrade_hotkey_buys_for_the_debug_inspected_owned_unit() -> void:
	GameManager.set_mode(BloodTournamentMode.new())
	var blue := GameManager.get_player(GameManager.BLUE_TEAM_ID)
	blue.blood_points = IRON_ARMOR_UPGRADE.cost
	var unit := GameManager.spawn_unit(TANK_STATS, blue, Vector3(-3, 0, 0))
	DebugInspector.select(unit) # stands in for the click that would normally select it
	var original_armor := unit.stat_block.armor()

	var key_event := InputEventKey.new()
	key_event.keycode = KEY_U
	key_event.pressed = true
	_main._handle_placement_key(key_event)

	assert_almost_eq(unit.stat_block.armor(), original_armor + IRON_ARMOR_UPGRADE.ability.effect_stat_value, 0.01)


# ---------------------------------------------------------------------
# Roster (no-permadeath persistence) and kill blood points
# ---------------------------------------------------------------------

func test_buying_a_unit_appends_it_to_the_players_roster() -> void:
	GameManager.set_mode(BloodTournamentMode.new()) # grants STARTING_GOLD
	var blue := GameManager.get_player(GameManager.BLUE_TEAM_ID)

	_main._try_place_unit(_main.get_viewport().get_visible_rect().size / 2)

	assert_eq(blue.roster, [TANK_STATS], "the default placement unit type (Tank) should have been appended to the roster")


func test_selling_a_unit_removes_it_from_the_players_roster() -> void:
	var blue := GameManager.get_player(GameManager.BLUE_TEAM_ID)
	var unit := GameManager.spawn_unit(TANK_STATS, blue, Vector3(-3, 0, 0))
	blue.roster.append(TANK_STATS) # simulate this unit having been bought earlier
	await wait_physics_frames(1) # let the physics server register the new collision shape before raycasting it
	var camera: Camera3D = _main.get_node("Camera3D")

	_main._try_sell_unit_at(camera.unproject_position(unit.global_position))

	assert_true(blue.roster.is_empty(), "selling should remove the matching entry from the roster, not just free the live unit")


## A second Red unit stays alive so this kill doesn't also empty Red's
## roster and end the round -- round-end grants its own separate
## PARTICIPATION_INCOME gold to everyone (correct, tested elsewhere), which
## would otherwise contaminate this test's "a kill itself grants no gold"
## assertion with an unrelated, also-correct gold change.
func test_kill_grants_blood_points_to_the_killers_player_not_gold() -> void:
	GameManager.set_mode(BloodTournamentMode.new())
	var blue := GameManager.get_player(GameManager.BLUE_TEAM_ID)
	var red := GameManager.get_player(GameManager.RED_TEAM_ID)
	var killer := GameManager.spawn_unit(TANK_STATS, blue, Vector3.ZERO)
	var victim := GameManager.spawn_unit(FIGHTER_STATS, red, Vector3(1, 0, 0))
	GameManager.spawn_unit(FIGHTER_STATS, red, Vector3(-5, 0, 0)) # keeps Red's roster non-empty after victim dies
	GameManager.start_battle()
	var blood_points_before := blue.blood_points
	var gold_before := blue.resources

	victim.take_damage(DamageInstance.new(victim.stat_block.max_health() + 100.0, killer))

	assert_eq(blue.blood_points, blood_points_before + BloodTournamentMode.KILL_BLOOD_POINTS)
	assert_eq(blue.resources, gold_before, "a kill should never grant gold -- gold stays flat/equal for everyone, only blood points reward kills")


func test_kills_do_not_grant_blood_points_outside_blood_tournament() -> void:
	var blue := GameManager.get_player(GameManager.BLUE_TEAM_ID)
	var red := GameManager.get_player(GameManager.RED_TEAM_ID)
	var killer := GameManager.spawn_unit(TANK_STATS, blue, Vector3.ZERO)
	var victim := GameManager.spawn_unit(FIGHTER_STATS, red, Vector3(1, 0, 0))
	GameManager.start_battle()

	victim.take_damage(DamageInstance.new(victim.stat_block.max_health() + 100.0, killer))

	assert_eq(blue.blood_points, 0, "classic mode's GameMode.on_unit_killed() is a no-op")


## The core Blood Tournament v2 correction: gold is flat/equal for every
## registered team every round, win or lose -- no win bonus.
func test_round_income_is_flat_and_equal_regardless_of_who_won() -> void:
	var mode := BloodTournamentMode.new()
	GameManager.set_mode(mode)
	var blue := GameManager.get_player(GameManager.BLUE_TEAM_ID)
	var red := GameManager.get_player(GameManager.RED_TEAM_ID)
	var blue_gold_before := blue.resources
	var red_gold_before := red.resources

	mode.on_battle_ended(GameManager.BLUE_TEAM_ID, false) # Blue wins this round

	assert_eq(blue.resources, blue_gold_before + BloodTournamentMode.PARTICIPATION_INCOME)
	assert_eq(red.resources, red_gold_before + BloodTournamentMode.PARTICIPATION_INCOME,
		"the losing team should get exactly the same gold as the winner -- no win bonus")
