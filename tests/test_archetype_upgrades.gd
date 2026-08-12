## Tests for Scripts/Combat/ArchetypeUpgrade.gd -- gameplay feedback,
## 2026-08-12: "we dont currently have much use for blood points.. in
## real blood tournament games you have optional upgrades for units,
## like for archers it may add 1 mortar unit and 2 additional archers
## for some cost or add an aura." Distinct from UnitUpgrade
## (test_economy.gd's own buy_roster_upgrade() tests): scoped to one
## archetype, can change squad composition (bonus units), not just
## stats.
extends GutTest

const ARCHER_STATS: UnitStats = preload("res://Resources/Units/ArcherStats.tres")
const FIGHTER_STATS: UnitStats = preload("res://Resources/Units/FighterStats.tres")
const TANK_STATS: UnitStats = preload("res://Resources/Units/TankStats.tres")
const MORTAR_STATS: UnitStats = preload("res://Resources/Units/MortarStats.tres")
const MORTAR_SUPPORT_UPGRADE: ArchetypeUpgrade = preload("res://Resources/Upgrades/ArcherMortarSupportUpgrade.tres")
const BATTLE_STANDARD_UPGRADE: ArchetypeUpgrade = preload("res://Resources/Upgrades/FighterBattleStandardUpgrade.tres")

var _main: Node3D


func before_each() -> void:
	GameManager.reset_battle()
	GameManager.current_mode = ClassicEliminationMode.new()
	var blue := GameManager.get_player(GameManager.BLUE_TEAM_ID)
	var red := GameManager.get_player(GameManager.RED_TEAM_ID)
	blue.resources = 0
	red.resources = 0
	blue.blood_points = 0
	red.blood_points = 0
	blue.roster.clear()
	red.roster.clear()
	blue.roster_upgrades.clear()
	red.roster_upgrades.clear()
	blue.archetype_upgrades.clear()
	red.archetype_upgrades.clear()
	_main = load("res://Scenes/Main.tscn").instantiate()
	add_child_autofree(_main)
	await wait_physics_frames(2)


func test_buy_archetype_upgrade_spends_blood_points_and_records_the_purchase() -> void:
	GameManager.set_mode(BloodTournamentMode.new())
	var blue := GameManager.get_player(GameManager.BLUE_TEAM_ID)
	blue.blood_points = MORTAR_SUPPORT_UPGRADE.cost

	var bought := GameManager.buy_archetype_upgrade(blue, MORTAR_SUPPORT_UPGRADE)

	assert_true(bought)
	assert_eq(blue.blood_points, 0)
	assert_eq(blue.archetype_upgrades, [MORTAR_SUPPORT_UPGRADE])


func test_buy_archetype_upgrade_fails_outside_blood_tournament_and_without_enough_blood_points() -> void:
	var blue := GameManager.get_player(GameManager.BLUE_TEAM_ID)

	assert_false(GameManager.buy_archetype_upgrade(blue, MORTAR_SUPPORT_UPGRADE), "classic mode doesn't use economy at all")

	GameManager.set_mode(BloodTournamentMode.new())
	blue.blood_points = MORTAR_SUPPORT_UPGRADE.cost - 1

	assert_false(GameManager.buy_archetype_upgrade(blue, MORTAR_SUPPORT_UPGRADE), "one blood point short should fail the purchase")
	assert_eq(blue.blood_points, MORTAR_SUPPORT_UPGRADE.cost - 1, "a failed purchase must not spend anything")
	assert_true(blue.archetype_upgrades.is_empty())


func test_buying_the_same_archetype_upgrade_twice_fails_and_spends_nothing_the_second_time() -> void:
	GameManager.set_mode(BloodTournamentMode.new())
	var blue := GameManager.get_player(GameManager.BLUE_TEAM_ID)
	blue.blood_points = MORTAR_SUPPORT_UPGRADE.cost * 2

	assert_true(GameManager.buy_archetype_upgrade(blue, MORTAR_SUPPORT_UPGRADE))
	var blood_points_after_first_buy := blue.blood_points

	var bought_again := GameManager.buy_archetype_upgrade(blue, MORTAR_SUPPORT_UPGRADE)

	assert_false(bought_again, "an already-owned archetype upgrade should refuse a second purchase")
	assert_eq(blue.blood_points, blood_points_after_first_buy)
	assert_eq(blue.archetype_upgrades.size(), 1, "should never stack two copies of the same upgrade")


## The actual mechanic the whole feature exists for: an Archer roster
## slot with Mortar Support owned deploys as more than just
## ARCHER_STATS.squad_size plain Archers.
func test_a_squad_with_a_matching_archetype_upgrade_deploys_the_expanded_composition() -> void:
	GameManager.set_mode(BloodTournamentMode.new())
	var blue := GameManager.get_player(GameManager.BLUE_TEAM_ID)
	blue.blood_points = MORTAR_SUPPORT_UPGRADE.cost
	GameManager.buy_archetype_upgrade(blue, MORTAR_SUPPORT_UPGRADE)
	blue.roster = [ARCHER_STATS]

	GameManager.sync_courtyard_to_roster(blue)

	var squad: Array = blue.courtyard_units[0]
	var archer_count := squad.filter(func(u: Unit) -> bool: return u.stats == ARCHER_STATS).size()
	var mortar_count := squad.filter(func(u: Unit) -> bool: return u.stats == MORTAR_STATS).size()
	assert_eq(archer_count, ARCHER_STATS.squad_size + MORTAR_SUPPORT_UPGRADE.extra_base_units, "base archetype count should include the upgrade's extra_base_units")
	assert_eq(mortar_count, MORTAR_SUPPORT_UPGRADE.bonus_unit_count, "the bonus unit type should also be present")
	assert_eq(squad.size(), archer_count + mortar_count, "no unaccounted-for extra members")


## Regression guard: an archetype upgrade must never leak onto a
## DIFFERENT archetype's squad, even one purchased by the same player in
## the same match.
func test_an_archetype_upgrade_does_not_affect_a_different_archetypes_squad() -> void:
	GameManager.set_mode(BloodTournamentMode.new())
	var blue := GameManager.get_player(GameManager.BLUE_TEAM_ID)
	blue.blood_points = MORTAR_SUPPORT_UPGRADE.cost
	GameManager.buy_archetype_upgrade(blue, MORTAR_SUPPORT_UPGRADE)
	blue.roster = [TANK_STATS]

	GameManager.sync_courtyard_to_roster(blue)

	var squad: Array = blue.courtyard_units[0]
	assert_eq(squad.size(), TANK_STATS.squad_size, "Tank should deploy exactly its own squad_size, unaffected by an Archer-only upgrade")
	for unit in squad:
		assert_eq(unit.stats, TANK_STATS)


## The other half of the feature: an aura, not a composition change.
func test_a_squad_with_an_aura_archetype_upgrade_has_the_aura_granted_to_every_member() -> void:
	GameManager.set_mode(BloodTournamentMode.new())
	var blue := GameManager.get_player(GameManager.BLUE_TEAM_ID)
	blue.blood_points = BATTLE_STANDARD_UPGRADE.cost
	GameManager.buy_archetype_upgrade(blue, BATTLE_STANDARD_UPGRADE)
	blue.roster = [FIGHTER_STATS]

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
	var squad: Array = blue.courtyard_units[0]
	for unit in squad:
		assert_null(unit.granted_aura_ability, "sanity check -- no aura before the upgrade is bought")

	blue.blood_points = BATTLE_STANDARD_UPGRADE.cost
	GameManager.buy_archetype_upgrade(blue, BATTLE_STANDARD_UPGRADE)

	for unit in squad:
		assert_eq(unit.granted_aura_ability, BATTLE_STANDARD_UPGRADE.aura_ability, "an already-standing squad should get the aura immediately, not just future squads")


func test_archetype_upgrades_persist_across_reset_battle() -> void:
	GameManager.set_mode(BloodTournamentMode.new())
	var blue := GameManager.get_player(GameManager.BLUE_TEAM_ID)
	blue.blood_points = MORTAR_SUPPORT_UPGRADE.cost
	GameManager.buy_archetype_upgrade(blue, MORTAR_SUPPORT_UPGRADE)

	GameManager.reset_battle()

	assert_eq(blue.archetype_upgrades, [MORTAR_SUPPORT_UPGRADE], "archetype upgrades should persist for the whole match, same as roster/roster_upgrades")


func test_granted_aura_actually_buffs_nearby_allies_in_combat() -> void:
	var blue := GameManager.get_player(GameManager.BLUE_TEAM_ID)
	var caster := GameManager.spawn_unit(FIGHTER_STATS, blue, Vector3.ZERO)
	var ally := GameManager.spawn_unit(FIGHTER_STATS, blue, Vector3(1, 0, 0))
	caster.granted_aura_ability = BATTLE_STANDARD_UPGRADE.aura_ability
	var damage_before := ally.stat_block.damage()

	for i in range(20): # comfortably past Unit._AURA_TICK_INTERVAL (0.25s)
		await wait_physics_frames(1)

	assert_gt(ally.stat_block.damage(), damage_before, "the granted aura should actually buff a nearby ally's stats, not just be recorded as a field")
