## Tests for Blood Tournament's economy: starting gold, flat round income
## (equal for everyone, no win bonus), blood points from kills, unit cost,
## sell, and the no-permadeath roster (what actually persists between
## rounds now -- see Scripts/Players/Player.gd's `roster` field; round-transition
## integration for that lives in test_game_modes.gd) -- plus its shop
## upgrades (a blood-point-cost permanent Effect, reusing
## Ability.cast_unit_target() rather than a new framework -- see
## Scripts/Combat/UnitUpgrade.gd). GameManager.buy_upgrade() applies one
## immediately to a living unit; GameManager.buy_roster_upgrade() is the
## real PLACEMENT-time shop path under the staging-area model -- it
## records the purchase account-wide on Player.roster_upgrades and
## Main._deploy_next_pending_slot() applies it to every unit in every
## squad deployed afterward.
extends GutTest

const TANK_STATS: UnitStats = preload("res://Resources/Units/TankStats.tres")
const FIGHTER_STATS: UnitStats = preload("res://Resources/Units/FighterStats.tres")
const HERO_STATS: UnitStats = preload("res://Resources/Units/HeroStats.tres")
const IRON_ARMOR_UPGRADE: UnitUpgrade = preload("res://Resources/Upgrades/IronArmorUpgrade.tres")
const HEROIC_VIGOR_UPGRADE: UnitUpgrade = preload("res://Resources/Upgrades/HeroicVigorUpgrade.tres")
const HEROIC_MIGHT_UPGRADE: UnitUpgrade = preload("res://Resources/Upgrades/HeroicMightUpgrade.tres")

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
	blue.kills = 0
	red.kills = 0
	blue.roster.clear()
	red.roster.clear()
	blue.roster_upgrades.clear()
	red.roster_upgrades.clear()
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


func test_exchanging_gold_for_blood_points_spends_gold_and_grants_blood_points_at_the_fixed_rate() -> void:
	var player := GameManager.get_player(GameManager.BLUE_TEAM_ID)
	player.add_gold(Player.EXCHANGE_GOLD_PER_CLICK)

	assert_true(player.exchange_gold_for_blood_points())
	assert_eq(player.resources, 0)
	assert_eq(player.blood_points, Player.EXCHANGE_BLOOD_PER_CLICK)


func test_exchanging_blood_points_for_gold_spends_blood_points_and_grants_gold_at_the_fixed_rate() -> void:
	var player := GameManager.get_player(GameManager.BLUE_TEAM_ID)
	player.add_blood_points(Player.EXCHANGE_BLOOD_PER_CLICK)

	assert_true(player.exchange_blood_points_for_gold())
	assert_eq(player.blood_points, 0)
	assert_eq(player.resources, Player.EXCHANGE_GOLD_PER_CLICK)


func test_exchange_fails_and_spends_nothing_when_unaffordable() -> void:
	var player := GameManager.get_player(GameManager.BLUE_TEAM_ID)

	assert_false(player.exchange_gold_for_blood_points())
	assert_eq(player.resources, 0)
	assert_eq(player.blood_points, 0)

	assert_false(player.exchange_blood_points_for_gold())
	assert_eq(player.resources, 0)
	assert_eq(player.blood_points, 0)


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
	var blue := GameManager.get_player(GameManager.BLUE_TEAM_ID)
	var camera: Camera3D = _main.get_node("Camera3D")
	var target := CrossArenaMap.get_courtyard_unit_anchor(GameManager.BLUE_TEAM_ID)
	camera._focus_point = Vector3(target.x, 0, target.z)
	camera._update_transform()
	blue.resources = TANK_STATS.cost - 1

	_main._on_unit_type_selected(TANK_STATS) # arms the ghost regardless of affordability -- the real gate is at confirm time
	_main._try_left_click_at(camera.unproject_position(target))
	assert_true(blue.roster.is_empty(), "one gold short of Tank's cost should block the purchase even once confirmed")

	blue.resources = TANK_STATS.cost
	_main._on_unit_type_selected(TANK_STATS)
	_main._try_left_click_at(camera.unproject_position(target))
	assert_eq(blue.roster, [TANK_STATS], "exactly enough gold should buy the slot")
	assert_eq(blue.resources, 0, "the Tank's cost should be spent")


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
	var unit := GameManager.spawn_unit(TANK_STATS, blue, Vector3(-3, 0, 0))
	await wait_physics_frames(1) # let the physics server register the new collision shape before raycasting it
	var camera: Camera3D = _main.get_node("Camera3D")
	var gold_before := blue.resources

	_main._try_sell_unit_at(camera.unproject_position(unit.global_position))

	assert_true(unit.is_queued_for_deletion())
	assert_eq(blue.resources, gold_before, "classic mode (no economy active) should never refund anything")


## Lineup-courtyard model: a roster slot's live squad is standing in the
## courtyard the moment it's bought -- right-clicking ANY one of its
## members must sell the WHOLE squad, not just the unit actually clicked,
## and remove exactly one roster entry (see
## PlayerInputController.try_sell_unit_at()'s courtyard branch /
## GameManager.sell_roster_slot()).
func test_right_click_on_a_courtyard_unit_sells_its_whole_squad() -> void:
	GameManager.set_mode(BloodTournamentMode.new())
	var blue := GameManager.get_player(GameManager.BLUE_TEAM_ID)
	blue.resources = TANK_STATS.cost # squad_size 3
	var camera: Camera3D = _main.get_node("Camera3D")
	var target := CrossArenaMap.get_courtyard_unit_anchor(GameManager.BLUE_TEAM_ID)
	camera._focus_point = Vector3(target.x, 0, target.z)
	camera._update_transform()
	_main._on_unit_type_selected(TANK_STATS) # arms the ghost
	_main._try_left_click_at(camera.unproject_position(target)) # confirms it
	await wait_physics_frames(1) # let the physics server register the new collision shapes before raycasting
	var squad: Array = blue.courtyard_units[0]
	var clicked_unit: Unit = squad[0]
	var gold_before := blue.resources

	_main._try_sell_unit_at(camera.unproject_position(clicked_unit.global_position))

	assert_true(blue.roster.is_empty(), "the roster slot should be removed")
	assert_true(blue.courtyard_units.is_empty())
	assert_eq(blue.resources, gold_before + int(TANK_STATS.cost * GameManager.SELL_REFUND_FRACTION), "refund should happen exactly once per slot, not once per squad member")
	for unit in squad:
		assert_true(unit.is_queued_for_deletion(), "every squad member should be freed, not just the one clicked")


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


## The U/I hotkeys buy an account-wide upgrade (GameManager.buy_roster_upgrade())
## now, not a per-unit one -- nothing is alive to select/target during
## PLACEMENT under the staging-area deployment model, so this no longer
## needs a DebugInspector selection at all (see Main._handle_placement_key()).
func test_upgrade_hotkey_buys_an_account_wide_upgrade() -> void:
	GameManager.set_mode(BloodTournamentMode.new())
	var blue := GameManager.get_player(GameManager.BLUE_TEAM_ID)
	blue.blood_points = IRON_ARMOR_UPGRADE.cost

	var key_event := InputEventKey.new()
	key_event.keycode = KEY_U
	key_event.pressed = true
	_main._handle_placement_key(key_event)

	assert_eq(blue.roster_upgrades, [IRON_ARMOR_UPGRADE])
	assert_eq(blue.blood_points, 0)


func test_buy_roster_upgrade_fails_outside_blood_tournament_and_without_enough_blood_points() -> void:
	var blue := GameManager.get_player(GameManager.BLUE_TEAM_ID)

	assert_false(GameManager.buy_roster_upgrade(blue, IRON_ARMOR_UPGRADE), "classic mode doesn't use economy at all")

	GameManager.set_mode(BloodTournamentMode.new())
	blue.blood_points = IRON_ARMOR_UPGRADE.cost - 1

	assert_false(GameManager.buy_roster_upgrade(blue, IRON_ARMOR_UPGRADE), "one blood point short should fail the purchase")
	assert_eq(blue.blood_points, IRON_ARMOR_UPGRADE.cost - 1, "a failed purchase must not spend anything")
	assert_true(blue.roster_upgrades.is_empty())


func test_heroes_only_upgrade_hotkeys_buy_the_right_resource() -> void:
	GameManager.set_mode(BloodTournamentMode.new())
	var blue := GameManager.get_player(GameManager.BLUE_TEAM_ID)
	blue.blood_points = HEROIC_VIGOR_UPGRADE.cost

	var key_event := InputEventKey.new()
	key_event.keycode = KEY_O
	key_event.pressed = true
	_main._handle_placement_key(key_event)

	assert_eq(blue.roster_upgrades, [HEROIC_VIGOR_UPGRADE])
	assert_eq(blue.blood_points, 0)

	blue.blood_points = HEROIC_MIGHT_UPGRADE.cost
	key_event.keycode = KEY_L
	_main._handle_placement_key(key_event)

	assert_eq(blue.roster_upgrades, [HEROIC_VIGOR_UPGRADE, HEROIC_MIGHT_UPGRADE])
	assert_eq(blue.blood_points, 0)


## Buying a heroes_only upgrade while both a hero squad and a non-hero
## squad are already live in the courtyard should only buff the hero.
func test_heroes_only_upgrade_applies_only_to_a_live_hero_squad() -> void:
	GameManager.set_mode(BloodTournamentMode.new())
	var blue := GameManager.get_player(GameManager.BLUE_TEAM_ID)
	blue.blood_points = HEROIC_VIGOR_UPGRADE.cost
	blue.roster = [HERO_STATS, TANK_STATS]
	GameManager.sync_courtyard_to_roster(blue)
	var hero: Unit = blue.courtyard_units[0][0]
	var tank: Unit = blue.courtyard_units[1][0]
	var hero_health_before := hero.stat_block.max_health()
	var tank_health_before := tank.stat_block.max_health()

	assert_true(GameManager.buy_roster_upgrade(blue, HEROIC_VIGOR_UPGRADE))

	assert_almost_eq(hero.stat_block.max_health(), hero_health_before + HEROIC_VIGOR_UPGRADE.ability.effect_stat_value, 0.01)
	assert_almost_eq(tank.stat_block.max_health(), tank_health_before, 0.01, "a heroes_only upgrade must not touch a non-hero squad")


## A heroes_only upgrade bought before any hero is on the roster must
## still stay inert for existing non-hero squads and only apply once a
## hero squad is actually spawned afterward -- the deferred-application
## half of the same account-wide model test_staggered_deployment_applies_roster_upgrades_to_every_squad_member()
## already covers for the non-filtered case.
func test_heroes_only_upgrade_bought_before_a_hero_exists_applies_once_one_is_spawned() -> void:
	GameManager.set_mode(BloodTournamentMode.new())
	var blue := GameManager.get_player(GameManager.BLUE_TEAM_ID)
	blue.blood_points = HEROIC_VIGOR_UPGRADE.cost
	blue.roster = [TANK_STATS]
	GameManager.sync_courtyard_to_roster(blue)
	var tank: Unit = blue.courtyard_units[0][0]
	var tank_health_before := tank.stat_block.max_health()

	assert_true(GameManager.buy_roster_upgrade(blue, HEROIC_VIGOR_UPGRADE))
	assert_almost_eq(tank.stat_block.max_health(), tank_health_before, 0.01, "no hero squad exists yet -- nothing to apply to")

	blue.roster.append(HERO_STATS)
	GameManager.sync_courtyard_to_roster(blue)
	var hero: Unit = blue.courtyard_units[1][0]

	assert_almost_eq(hero.stat_block.max_health(), HERO_STATS.max_health + HEROIC_VIGOR_UPGRADE.ability.effect_stat_value, 0.01)
	assert_almost_eq(tank.stat_block.max_health(), tank_health_before, 0.01, "still untouched")


## The deferred-application half of the account-wide upgrade model: an
## upgrade bought during PLACEMENT (when nothing is alive to apply it to)
## gets applied to every member of every squad deployed afterward, not
## just one unit -- see Main._deploy_next_pending_slot().
func test_staggered_deployment_applies_roster_upgrades_to_every_squad_member() -> void:
	GameManager.set_mode(BloodTournamentMode.new())
	var blue := GameManager.get_player(GameManager.BLUE_TEAM_ID)
	var red := GameManager.get_player(GameManager.RED_TEAM_ID)
	blue.roster = [TANK_STATS] # squad_size 3
	blue.roster_upgrades = [IRON_ARMOR_UPGRADE]
	red.roster = [TANK_STATS] # can_start_battle() needs a second team's roster non-empty

	GameManager.start_battle()
	await wait_physics_frames(2)

	var blue_units := GameManager.get_all_units().filter(func(u: Unit) -> bool: return u.player == blue)
	assert_eq(blue_units.size(), TANK_STATS.squad_size)
	for unit in blue_units:
		assert_almost_eq(unit.stat_block.armor(), TANK_STATS.armor + IRON_ARMOR_UPGRADE.ability.effect_stat_value, 0.01,
			"every squad member should get the account-wide upgrade, not just one")


# ---------------------------------------------------------------------
# Roster (no-permadeath persistence) and kill blood points
# ---------------------------------------------------------------------

func test_buying_a_unit_appends_it_to_the_players_roster() -> void:
	GameManager.set_mode(BloodTournamentMode.new()) # grants STARTING_GOLD
	var blue := GameManager.get_player(GameManager.BLUE_TEAM_ID)
	var camera: Camera3D = _main.get_node("Camera3D")
	var target := CrossArenaMap.get_courtyard_unit_anchor(GameManager.BLUE_TEAM_ID)
	camera._focus_point = Vector3(target.x, 0, target.z)
	camera._update_transform()

	_main._on_unit_type_selected(TANK_STATS) # arms the ghost
	_main._try_left_click_at(camera.unproject_position(target)) # confirms it

	assert_eq(blue.roster, [TANK_STATS], "buying a unit type should append it to the roster")


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


func test_kill_increments_the_killers_player_kill_count() -> void:
	GameManager.set_mode(BloodTournamentMode.new())
	var blue := GameManager.get_player(GameManager.BLUE_TEAM_ID)
	var red := GameManager.get_player(GameManager.RED_TEAM_ID)
	var killer := GameManager.spawn_unit(TANK_STATS, blue, Vector3.ZERO)
	var victim := GameManager.spawn_unit(FIGHTER_STATS, red, Vector3(1, 0, 0))
	GameManager.spawn_unit(FIGHTER_STATS, red, Vector3(-5, 0, 0)) # keeps Red's roster non-empty after victim dies
	GameManager.start_battle()

	victim.take_damage(DamageInstance.new(victim.stat_block.max_health() + 100.0, killer))

	assert_eq(blue.kills, 1)


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


# ---------------------------------------------------------------------
# Squad deployment (UnitStats.squad_size / GameManager.spawn_squad())
# ---------------------------------------------------------------------

func _squad_test_stats(squad_size: int) -> UnitStats:
	var stats := UnitStats.new()
	stats.unit_name = "SquadTestUnit"
	stats.max_health = 50.0
	stats.damage = 5.0
	stats.attack_range = 1.0
	stats.attack_interval = 1.0
	stats.move_speed = 3.0
	stats.collision_radius = 0.4
	stats.squad_size = squad_size
	return stats


func test_spawn_squad_spawns_squad_size_units_at_distinct_positions() -> void:
	var blue := GameManager.get_player(GameManager.BLUE_TEAM_ID)
	var stats := _squad_test_stats(4)

	var squad := GameManager.spawn_squad(stats, blue, Vector3.ZERO)

	assert_eq(squad.size(), 4)
	assert_eq(GameManager.get_all_units().size(), 4)
	var distinct_positions := {}
	for unit in squad:
		distinct_positions[unit.global_position] = true
	assert_eq(distinct_positions.size(), 4, "squad members should not spawn stacked on the same point")


func test_spawn_squad_of_one_spawns_exactly_one_unit_at_the_anchor() -> void:
	var blue := GameManager.get_player(GameManager.BLUE_TEAM_ID)
	var stats := _squad_test_stats(1)

	var squad := GameManager.spawn_squad(stats, blue, Vector3(3, 0, 3))

	assert_eq(squad.size(), 1)
	assert_eq(squad[0].global_position, Vector3(3, 0, 3))


## Lineup-courtyard model: confirming a ghost placement charges gold once
## and records one roster slot, and spawns the full squad standing at the
## clicked spot (see PlayerInputController.begin_build_placement()/
## resolve_build_placement()/GameManager.buy_roster_slot_at()) -- visible
## before battle even starts, not deferred to a deployment queue.
func test_confirming_a_squad_purchase_charges_gold_once_and_spawns_the_full_squad() -> void:
	GameManager.set_mode(BloodTournamentMode.new()) # grants STARTING_GOLD
	var blue := GameManager.get_player(GameManager.BLUE_TEAM_ID)
	var camera: Camera3D = _main.get_node("Camera3D")
	var target := CrossArenaMap.get_courtyard_unit_anchor(GameManager.BLUE_TEAM_ID)
	camera._focus_point = Vector3(target.x, 0, target.z)
	camera._update_transform()
	var gold_before := blue.resources

	_main._on_unit_type_selected(FIGHTER_STATS) # squad_size 5 -- arms the ghost
	_main._try_left_click_at(camera.unproject_position(target)) # confirms it

	assert_eq(GameManager.get_all_units().size(), FIGHTER_STATS.squad_size, "the full squad should stand at the clicked spot")
	assert_eq(blue.resources, gold_before - FIGHTER_STATS.cost, "cost is charged once per purchase, not once per squad member")
	assert_eq(blue.roster, [FIGHTER_STATS], "the roster should record one slot, not one entry per squad member")


func test_classic_mode_placement_still_deploys_a_single_unit_regardless_of_squad_size() -> void:
	_main._selected_stats = FIGHTER_STATS # squad_size 5, but classic mode shouldn't care

	_main._try_place_unit(_main.get_viewport().get_visible_rect().size / 2)

	assert_eq(GameManager.get_all_units().size(), 1, "classic mode should never deploy a squad, regardless of UnitStats.squad_size")


## Exercises GameManager.start_battle()'s sync_courtyard_to_roster()
## safety net + BloodTournamentController.begin_march() end to end: a
## roster slot set directly (bypassing buy_roster_slot() entirely, same
## as this test does) still ends up as a live squad on the field once
## battle starts.
func test_starting_battle_deploys_the_full_squad_for_a_purchased_slot() -> void:
	GameManager.set_mode(BloodTournamentMode.new())
	var blue := GameManager.get_player(GameManager.BLUE_TEAM_ID)
	var red := GameManager.get_player(GameManager.RED_TEAM_ID)
	blue.roster = [FIGHTER_STATS] # squad_size 5
	red.roster = [TANK_STATS] # squad_size 3 -- can_start_battle() needs a second team's roster non-empty

	GameManager.start_battle()
	await wait_physics_frames(1)

	assert_eq(GameManager.get_all_units().size(), FIGHTER_STATS.squad_size + TANK_STATS.squad_size, "both teams' single roster slot should have marched out in full")


## Every roster slot's squad marches out simultaneously at battle start --
## no staggering, since nothing is being "produced" anymore, it's
## already-trained troops in the courtyard together (see
## BloodTournamentController.begin_march()).
func test_every_roster_slot_marches_out_simultaneously_not_staggered() -> void:
	GameManager.set_mode(BloodTournamentMode.new())
	var blue := GameManager.get_player(GameManager.BLUE_TEAM_ID)
	var red := GameManager.get_player(GameManager.RED_TEAM_ID)
	blue.roster = [FIGHTER_STATS, TANK_STATS] # two roster slots
	red.roster = [TANK_STATS] # can_start_battle() needs a second team's roster non-empty

	GameManager.start_battle()
	await wait_physics_frames(1)

	var blue_fighters := GameManager.get_all_units().filter(func(u: Unit) -> bool: return u.player == blue and u.stats == FIGHTER_STATS)
	var blue_tanks := GameManager.get_all_units().filter(func(u: Unit) -> bool: return u.player == blue and u.stats == TANK_STATS)
	assert_eq(blue_fighters.size(), FIGHTER_STATS.squad_size, "both of Blue's roster slots should be on the field already")
	assert_eq(blue_tanks.size(), TANK_STATS.squad_size)


## Blue/Red default to sharing the North arm (SPAWN_POINTS[0]/[1]) when
## assign_random_spawn_points() hasn't run -- begin_march() should order
## each marching unit to attack-move toward its same-arm rival's spawn
## point FIRST, with the center-push order only queued behind it, not
## active -- this is the fix for the "mess in the middle" bug (squads
## used to walk straight to the literal map center and only converge
## right at the destination instead of clashing at the arm ends).
func test_marching_squads_engage_the_same_arm_rival_before_the_queued_center_push() -> void:
	GameManager.set_mode(BloodTournamentMode.new())
	var blue := GameManager.get_player(GameManager.BLUE_TEAM_ID)
	var red := GameManager.get_player(GameManager.RED_TEAM_ID)
	blue.roster = [TANK_STATS]
	red.roster = [TANK_STATS]

	GameManager.start_battle()
	await wait_physics_frames(1)

	var blue_unit: Unit = GameManager.get_all_units().filter(func(u: Unit) -> bool: return u.player == blue)[0]
	assert_eq(blue_unit.current_order.target_position, CrossArenaMap.SPAWN_POINTS[GameManager.RED_TEAM_ID], "should attack-move toward the same-arm rival's spawn point first")
	assert_eq(blue_unit._order_queue.size(), 1, "the center-push order should be queued, not active yet")
	assert_eq(blue_unit._order_queue[0].target_position, Vector3.ZERO, "queued order should still push to the true map center once the arm fight resolves")


func test_arm_rival_anchor_returns_null_for_an_unrecognized_position() -> void:
	var controller := BloodTournamentController.new(autofree(Control.new()), Callable())
	assert_null(controller._arm_rival_anchor(GameManager.BLUE_TEAM_ID, Vector3(999, 0, 999)))
