## Tests for Scripts/Combat/ArchetypeUpgrade.gd -- distinct from
## UnitUpgrade (test_economy.gd's own buy_roster_upgrade() tests):
## scoped to one archetype, can change squad composition, not just stats.
extends GutTest

const ARCHER_STATS: UnitStats = preload("res://Resources/Units/ArcherStats.tres")
const FIGHTER_STATS: UnitStats = preload("res://Resources/Units/FighterStats.tres")
const TANK_STATS: UnitStats = preload("res://Resources/Units/TankStats.tres")
const HERO_STATS: UnitStats = preload("res://Resources/Units/HeroStats.tres")
const PRIEST_STATS: UnitStats = preload("res://Resources/Units/PriestStats.tres")
const AXE_THROWER_STATS: UnitStats = preload("res://Resources/Units/AxeThrowerStats.tres")
const BAT_RIDER_STATS: UnitStats = preload("res://Resources/Units/BatRiderStats.tres")
const GIANT_STATS: UnitStats = preload("res://Resources/Units/GiantStats.tres")
const SPITTER_STATS: UnitStats = preload("res://Resources/Units/SpitterStats.tres")
const MORTAR_STATS: UnitStats = preload("res://Resources/Units/MortarStats.tres")
const CATAPULT_STATS: UnitStats = preload("res://Resources/Units/CatapultStats.tres")
const MORTAR_SUPPORT_UPGRADE: ArchetypeUpgrade = preload("res://Resources/Upgrades/ArcherMortarSupportUpgrade.tres")
const BATTLE_STANDARD_UPGRADE: ArchetypeUpgrade = preload("res://Resources/Upgrades/FighterBattleStandardUpgrade.tres")
const SIEGE_WORKSHOP_UPGRADE: ArchetypeUpgrade = preload("res://Resources/Upgrades/TankSiegeWorkshopUpgrade.tres")
const WAR_HORNS_UPGRADE: ArchetypeUpgrade = preload("res://Resources/Upgrades/AxeThrowerWarHornsUpgrade.tres")
const HONOR_GUARD_UPGRADE: ArchetypeUpgrade = preload("res://Resources/Upgrades/HeroHonorGuardUpgrade.tres")
const ZEALOUS_FAITH_UPGRADE: ArchetypeUpgrade = preload("res://Resources/Upgrades/PriestZealousFaithUpgrade.tres")
const WING_SQUADRON_UPGRADE: ArchetypeUpgrade = preload("res://Resources/Upgrades/BatRiderWingSquadronUpgrade.tres")
const RALLY_POINT_UPGRADE: ArchetypeUpgrade = preload("res://Resources/Upgrades/GiantRallyPointUpgrade.tres")
const BROOD_SWARM_UPGRADE: ArchetypeUpgrade = preload("res://Resources/Upgrades/SpitterBroodSwarmUpgrade.tres")

var _main: Node3D


func before_each() -> void:
	GameManager.reset_battle()
	GameManager.current_mode = ClassicEliminationMode.new()
	var blue := GameManager.get_player(GameManager.BLUE_TEAM_ID)
	var red := GameManager.get_player(GameManager.RED_TEAM_ID)
	blue.reset_for_new_match()
	red.reset_for_new_match()
	_main = load("res://Scenes/Main.tscn").instantiate()
	add_child_autofree(_main)
	await wait_physics_frames(2)


## Directly seeds an owned roster slot (bypassing the real gold-purchase
## gate, same "set player.roster directly" idiom this whole test suite
## already relies on) and returns its squad_id -- every archetype-upgrade
## purchase needs a real owned squad of the matching archetype to target
## (see GameManager.buy_archetype_upgrade()'s own doc comment for why).
func _seed_owned_squad(player: Player, stats: UnitStats) -> int:
	player.roster.append(stats)
	var squad_id := player.next_squad_id()
	player.roster_squad_ids.append(squad_id)
	return squad_id


func test_buy_archetype_upgrade_spends_blood_points_and_records_the_purchase() -> void:
	GameManager.set_mode(BloodTournamentMode.new())
	var blue := GameManager.get_player(GameManager.BLUE_TEAM_ID)
	var squad_id := _seed_owned_squad(blue, ARCHER_STATS)
	blue.blood_points = MORTAR_SUPPORT_UPGRADE.cost

	var bought := GameManager.buy_archetype_upgrade(blue, MORTAR_SUPPORT_UPGRADE, squad_id)

	assert_true(bought)
	assert_eq(blue.blood_points, 0)
	assert_eq(blue.archetype_upgrades[squad_id], [MORTAR_SUPPORT_UPGRADE])


func test_buy_archetype_upgrade_fails_outside_blood_tournament_and_without_enough_blood_points() -> void:
	var blue := GameManager.get_player(GameManager.BLUE_TEAM_ID)
	var squad_id := _seed_owned_squad(blue, ARCHER_STATS)

	assert_false(GameManager.buy_archetype_upgrade(blue, MORTAR_SUPPORT_UPGRADE, squad_id), "classic mode doesn't use economy at all")

	GameManager.set_mode(BloodTournamentMode.new())
	# set_mode() calls reset_battle(), which never touches roster/roster_squad_ids -- squad_id is still valid.
	blue.blood_points = MORTAR_SUPPORT_UPGRADE.cost - 1

	assert_false(GameManager.buy_archetype_upgrade(blue, MORTAR_SUPPORT_UPGRADE, squad_id), "one blood point short should fail the purchase")
	assert_eq(blue.blood_points, MORTAR_SUPPORT_UPGRADE.cost - 1, "a failed purchase must not spend anything")
	assert_true(blue.archetype_upgrades.is_empty())


func test_buy_archetype_upgrade_fails_for_a_squad_that_is_not_the_upgrades_own_archetype() -> void:
	GameManager.set_mode(BloodTournamentMode.new())
	var blue := GameManager.get_player(GameManager.BLUE_TEAM_ID)
	var squad_id := _seed_owned_squad(blue, TANK_STATS) # Mortar Support is Archer-only
	blue.blood_points = MORTAR_SUPPORT_UPGRADE.cost

	assert_false(GameManager.buy_archetype_upgrade(blue, MORTAR_SUPPORT_UPGRADE, squad_id), "a squad of the wrong archetype should never be a valid purchase target")


func test_buy_archetype_upgrade_fails_for_an_unknown_squad_id() -> void:
	GameManager.set_mode(BloodTournamentMode.new())
	var blue := GameManager.get_player(GameManager.BLUE_TEAM_ID)
	blue.blood_points = MORTAR_SUPPORT_UPGRADE.cost

	assert_false(GameManager.buy_archetype_upgrade(blue, MORTAR_SUPPORT_UPGRADE, 999), "a squad_id the player doesn't own should never be a valid purchase target")


func test_buying_the_same_archetype_upgrade_twice_fails_and_spends_nothing_the_second_time() -> void:
	GameManager.set_mode(BloodTournamentMode.new())
	var blue := GameManager.get_player(GameManager.BLUE_TEAM_ID)
	var squad_id := _seed_owned_squad(blue, ARCHER_STATS)
	blue.blood_points = MORTAR_SUPPORT_UPGRADE.cost * 2

	assert_true(GameManager.buy_archetype_upgrade(blue, MORTAR_SUPPORT_UPGRADE, squad_id))
	var blood_points_after_first_buy := blue.blood_points

	var bought_again := GameManager.buy_archetype_upgrade(blue, MORTAR_SUPPORT_UPGRADE, squad_id)

	assert_false(bought_again, "an already-owned archetype upgrade should refuse a second purchase")
	assert_eq(blue.blood_points, blood_points_after_first_buy)
	assert_eq(blue.archetype_upgrades[squad_id].size(), 1, "should never stack two copies of the same upgrade")


## The actual mechanic the whole feature exists for: an Archer roster
## slot with Mortar Support owned deploys as more than just
## ARCHER_STATS.squad_size plain Archers.
func test_a_squad_with_a_matching_archetype_upgrade_deploys_the_expanded_composition() -> void:
	GameManager.set_mode(BloodTournamentMode.new())
	var blue := GameManager.get_player(GameManager.BLUE_TEAM_ID)
	var squad_id := _seed_owned_squad(blue, ARCHER_STATS)
	blue.blood_points = MORTAR_SUPPORT_UPGRADE.cost
	GameManager.buy_archetype_upgrade(blue, MORTAR_SUPPORT_UPGRADE, squad_id)

	GameManager.sync_courtyard_to_roster(blue)

	var squad: Array = blue.courtyard_units[0]
	var archer_count := squad.filter(func(u: Unit) -> bool: return u.stats == ARCHER_STATS).size()
	var mortar_count := squad.filter(func(u: Unit) -> bool: return u.stats == MORTAR_STATS).size()
	assert_eq(archer_count, ARCHER_STATS.squad_size + MORTAR_SUPPORT_UPGRADE.extra_base_units, "base archetype count should include the upgrade's extra_base_units")
	assert_eq(mortar_count, MORTAR_SUPPORT_UPGRADE.bonus_unit_count, "the bonus unit type should also be present")
	assert_eq(squad.size(), archer_count + mortar_count, "no unaccounted-for extra members")


## Regression guard: an archetype upgrade must never leak onto a
## DIFFERENT squad, whether that squad is a different archetype or just a
## second squad of the SAME archetype -- an upgrade is now scoped to the
## one squad_id it was bought for, not "every squad of this archetype."
func test_an_archetype_upgrade_does_not_affect_a_different_archetypes_squad() -> void:
	GameManager.set_mode(BloodTournamentMode.new())
	var blue := GameManager.get_player(GameManager.BLUE_TEAM_ID)
	var archer_squad_id := _seed_owned_squad(blue, ARCHER_STATS)
	blue.blood_points = MORTAR_SUPPORT_UPGRADE.cost
	GameManager.buy_archetype_upgrade(blue, MORTAR_SUPPORT_UPGRADE, archer_squad_id)
	blue.roster.append(TANK_STATS) # a second, untouched squad -- roster_squad_ids backfills below

	GameManager.sync_courtyard_to_roster(blue)

	var squad: Array = blue.courtyard_units[1]
	assert_eq(squad.size(), TANK_STATS.squad_size, "Tank should deploy exactly its own squad_size, unaffected by the Archer squad's own upgrade")
	for unit in squad:
		assert_eq(unit.stats, TANK_STATS)


## The other half of the feature: an aura, not a composition change.
func test_a_squad_with_an_aura_archetype_upgrade_has_the_aura_granted_to_every_member() -> void:
	GameManager.set_mode(BloodTournamentMode.new())
	var blue := GameManager.get_player(GameManager.BLUE_TEAM_ID)
	var squad_id := _seed_owned_squad(blue, FIGHTER_STATS)
	blue.blood_points = BATTLE_STANDARD_UPGRADE.cost
	GameManager.buy_archetype_upgrade(blue, BATTLE_STANDARD_UPGRADE, squad_id)

	GameManager.sync_courtyard_to_roster(blue)

	var squad: Array = blue.courtyard_units[0]
	assert_eq(squad.size(), FIGHTER_STATS.squad_size, "an aura-only upgrade should not change squad composition")
	for unit in squad:
		assert_eq(unit.granted_aura_ability, BATTLE_STANDARD_UPGRADE.aura_ability)


## Buying the upgrade AFTER a squad is already standing in the courtyard
## should still grant the aura to those already-live units, same
## "instant feedback, not just future purchases" guarantee
## buy_roster_upgrade() already gives account-wide upgrades.
func test_buying_an_aura_upgrade_retroactively_grants_it_to_an_already_standing_squad() -> void:
	GameManager.set_mode(BloodTournamentMode.new())
	var blue := GameManager.get_player(GameManager.BLUE_TEAM_ID)
	blue.roster = [FIGHTER_STATS]
	GameManager.sync_courtyard_to_roster(blue)
	var squad_id: int = blue.roster_squad_ids[0]
	var squad: Array = blue.courtyard_units[0]
	for unit in squad:
		assert_null(unit.granted_aura_ability, "sanity check -- no aura before the upgrade is bought")

	blue.blood_points = BATTLE_STANDARD_UPGRADE.cost
	GameManager.buy_archetype_upgrade(blue, BATTLE_STANDARD_UPGRADE, squad_id)

	for unit in squad:
		assert_eq(unit.granted_aura_ability, BATTLE_STANDARD_UPGRADE.aura_ability, "an already-standing squad should get the aura immediately, not just future squads")


func test_archetype_upgrades_persist_across_reset_battle() -> void:
	GameManager.set_mode(BloodTournamentMode.new())
	var blue := GameManager.get_player(GameManager.BLUE_TEAM_ID)
	var squad_id := _seed_owned_squad(blue, ARCHER_STATS)
	blue.blood_points = MORTAR_SUPPORT_UPGRADE.cost
	GameManager.buy_archetype_upgrade(blue, MORTAR_SUPPORT_UPGRADE, squad_id)

	GameManager.reset_battle()

	assert_eq(blue.archetype_upgrades[squad_id], [MORTAR_SUPPORT_UPGRADE], "archetype upgrades should persist for the whole match, same as roster/roster_upgrades")


func test_granted_aura_actually_buffs_nearby_allies_in_combat() -> void:
	var blue := GameManager.get_player(GameManager.BLUE_TEAM_ID)
	var caster := GameManager.spawn_unit(FIGHTER_STATS, blue, Vector3.ZERO)
	var ally := GameManager.spawn_unit(FIGHTER_STATS, blue, Vector3(1, 0, 0))
	caster.granted_aura_ability = BATTLE_STANDARD_UPGRADE.aura_ability
	var damage_before := ally.stat_block.damage()

	for i in range(20): # comfortably past Unit._AURA_TICK_INTERVAL (0.25s)
		await wait_physics_frames(1)

	assert_gt(ally.stat_block.damage(), damage_before, "the granted aura should actually buff a nearby ally's stats, not just be recorded as a field")


# ---------------------------------------------------------------------
# One upgrade per remaining archetype. Each test confirms the one thing
# that upgrade does, not every field -- the mechanics themselves
# (composition expansion, granted auras) are covered above.
# ---------------------------------------------------------------------

func test_tank_siege_workshop_adds_an_extra_tank_and_a_catapult() -> void:
	GameManager.set_mode(BloodTournamentMode.new())
	var blue := GameManager.get_player(GameManager.BLUE_TEAM_ID)
	var squad_id := _seed_owned_squad(blue, TANK_STATS)
	blue.blood_points = SIEGE_WORKSHOP_UPGRADE.cost
	GameManager.buy_archetype_upgrade(blue, SIEGE_WORKSHOP_UPGRADE, squad_id)

	GameManager.sync_courtyard_to_roster(blue)

	var squad: Array = blue.courtyard_units[0]
	var tank_count := squad.filter(func(u: Unit) -> bool: return u.stats == TANK_STATS).size()
	var catapult_count := squad.filter(func(u: Unit) -> bool: return u.stats == CATAPULT_STATS).size()
	assert_eq(tank_count, TANK_STATS.squad_size + 1)
	assert_eq(catapult_count, 1)


func test_axe_thrower_war_horns_grants_the_squad_a_move_speed_aura() -> void:
	GameManager.set_mode(BloodTournamentMode.new())
	var blue := GameManager.get_player(GameManager.BLUE_TEAM_ID)
	var squad_id := _seed_owned_squad(blue, AXE_THROWER_STATS)
	blue.blood_points = WAR_HORNS_UPGRADE.cost
	GameManager.buy_archetype_upgrade(blue, WAR_HORNS_UPGRADE, squad_id)

	GameManager.sync_courtyard_to_roster(blue)

	for unit in blue.courtyard_units[0]:
		assert_eq(unit.granted_aura_ability, WAR_HORNS_UPGRADE.aura_ability)


func test_hero_honor_guard_adds_a_bonus_tank() -> void:
	GameManager.set_mode(BloodTournamentMode.new())
	var blue := GameManager.get_player(GameManager.BLUE_TEAM_ID)
	var squad_id := _seed_owned_squad(blue, HERO_STATS)
	blue.blood_points = HONOR_GUARD_UPGRADE.cost
	GameManager.buy_archetype_upgrade(blue, HONOR_GUARD_UPGRADE, squad_id)

	GameManager.sync_courtyard_to_roster(blue)

	var squad: Array = blue.courtyard_units[0]
	assert_eq(squad.size(), HERO_STATS.squad_size + 1)
	var hero_count := squad.filter(func(u: Unit) -> bool: return u.stats == HERO_STATS).size()
	var guard_count := squad.filter(func(u: Unit) -> bool: return u.stats == TANK_STATS).size()
	assert_eq(hero_count, HERO_STATS.squad_size)
	assert_eq(guard_count, 1)


## Priest already has its own baked-in aura (Healing Word, via
## PriestStats.aura_ability) -- Zealous Faith is a SECOND, independent
## aura layered on top via granted_aura_ability, not a replacement.
func test_priest_zealous_faith_stacks_with_the_archetypes_own_baked_in_aura() -> void:
	GameManager.set_mode(BloodTournamentMode.new())
	var blue := GameManager.get_player(GameManager.BLUE_TEAM_ID)
	var squad_id := _seed_owned_squad(blue, PRIEST_STATS)
	blue.blood_points = ZEALOUS_FAITH_UPGRADE.cost
	GameManager.buy_archetype_upgrade(blue, ZEALOUS_FAITH_UPGRADE, squad_id)

	GameManager.sync_courtyard_to_roster(blue)

	for unit in blue.courtyard_units[0]:
		assert_eq(unit.granted_aura_ability, ZEALOUS_FAITH_UPGRADE.aura_ability)
		assert_eq(unit.stats.aura_ability.ability_name, "Healing Word", "the archetype's own baked-in aura should be untouched")


func test_bat_rider_wing_squadron_adds_two_extra_bat_riders() -> void:
	GameManager.set_mode(BloodTournamentMode.new())
	var blue := GameManager.get_player(GameManager.BLUE_TEAM_ID)
	var squad_id := _seed_owned_squad(blue, BAT_RIDER_STATS)
	blue.blood_points = WING_SQUADRON_UPGRADE.cost
	GameManager.buy_archetype_upgrade(blue, WING_SQUADRON_UPGRADE, squad_id)

	GameManager.sync_courtyard_to_roster(blue)

	assert_eq(blue.courtyard_units[0].size(), BAT_RIDER_STATS.squad_size + 2)


func test_giant_rally_point_grants_an_armor_aura() -> void:
	GameManager.set_mode(BloodTournamentMode.new())
	var blue := GameManager.get_player(GameManager.BLUE_TEAM_ID)
	var squad_id := _seed_owned_squad(blue, GIANT_STATS)
	blue.blood_points = RALLY_POINT_UPGRADE.cost
	GameManager.buy_archetype_upgrade(blue, RALLY_POINT_UPGRADE, squad_id)

	GameManager.sync_courtyard_to_roster(blue)

	for unit in blue.courtyard_units[0]:
		assert_eq(unit.granted_aura_ability, RALLY_POINT_UPGRADE.aura_ability)


func test_spitter_brood_swarm_adds_two_extra_spitters() -> void:
	GameManager.set_mode(BloodTournamentMode.new())
	var blue := GameManager.get_player(GameManager.BLUE_TEAM_ID)
	var squad_id := _seed_owned_squad(blue, SPITTER_STATS)
	blue.blood_points = BROOD_SWARM_UPGRADE.cost
	GameManager.buy_archetype_upgrade(blue, BROOD_SWARM_UPGRADE, squad_id)

	GameManager.sync_courtyard_to_roster(blue)

	assert_eq(blue.courtyard_units[0].size(), SPITTER_STATS.squad_size + 2)


## Every purchasable archetype should have at least one upgrade
## available -- a missing entry would silently leave a unit with
## nothing to spend blood points on.
func test_every_purchasable_archetype_has_at_least_one_upgrade_defined() -> void:
	var purchasable_archetypes: Array[UnitStats] = [
		TANK_STATS, FIGHTER_STATS, AXE_THROWER_STATS, ARCHER_STATS,
		HERO_STATS, PRIEST_STATS, BAT_RIDER_STATS, GIANT_STATS, SPITTER_STATS,
	]
	var pool: Array = _main._hud.ARCHETYPE_UPGRADE_POOL # HUD.gd has no class_name, so this reads the const off the real instance rather than the type
	for stats in purchasable_archetypes:
		var has_upgrade: bool = pool.any(func(upgrade: ArchetypeUpgrade) -> bool: return upgrade.archetype == stats)
		assert_true(has_upgrade, "%s should have at least one ArchetypeUpgrade defined" % stats.unit_name)
