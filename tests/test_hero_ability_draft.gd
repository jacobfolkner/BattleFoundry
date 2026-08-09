## Tests for the hero ability draft -- roadmap Phase 4's last item.
## UnitStats.ability_draft_choices/Player.hero_ability_picks/
## Unit.resolved_abilities/GameManager.pick_hero_ability(). Draft choices
## are made ahead of time during PLACEMENT (confirmed with the user --
## Blood Tournament heroes fight in full auto-battle, so there's no
## live mid-fight moment for a choice popup), auto-applied the moment a
## drafted slot's level is reached; an unresolved slot just uses its
## first candidate, so nothing ever blocks.
extends GutTest

const HERO_STATS: UnitStats = preload("res://Resources/Units/HeroStats.tres")
const CLEAVE_STRIKE: Ability = preload("res://Resources/Abilities/CleaveStrikeAbility.tres")
const BATTLE_CRY: Ability = preload("res://Resources/Abilities/BattleCryAbility.tres")
const GROUND_SLAM: Ability = preload("res://Resources/Abilities/GroundSlamAbility.tres")
const IRON_WILL: Ability = preload("res://Resources/Abilities/IronWillAbility.tres")

var _main: Node3D


func before_each() -> void:
	GameManager.reset_battle()
	GameManager.current_mode = ClassicEliminationMode.new()
	GameManager.get_player(GameManager.BLUE_TEAM_ID).hero_ability_picks.clear()
	GameManager.get_player(GameManager.RED_TEAM_ID).hero_ability_picks.clear()
	_main = load("res://Scenes/Main.tscn").instantiate()
	add_child_autofree(_main)
	await wait_physics_frames(2)


func test_with_no_pick_resolved_abilities_matches_the_archetype_default() -> void:
	var hero := GameManager.spawn_unit(HERO_STATS, GameManager.get_player(GameManager.BLUE_TEAM_ID), Vector3.ZERO)

	assert_eq(hero.resolved_abilities[0], CLEAVE_STRIKE)
	assert_eq(hero.resolved_abilities[1], GROUND_SLAM)


func test_pick_hero_ability_only_works_during_placement() -> void:
	var blue := GameManager.get_player(GameManager.BLUE_TEAM_ID)
	GameManager.spawn_unit(HERO_STATS, blue, Vector3.ZERO)
	GameManager.spawn_unit(HERO_STATS, GameManager.get_player(GameManager.RED_TEAM_ID), Vector3(5, 0, 0))
	GameManager.start_battle() # can_start_battle() needs a unit on both teams first

	var picked := GameManager.pick_hero_ability(blue, HERO_STATS, 0, 1)

	assert_false(picked)
	assert_true(blue.hero_ability_picks.is_empty())


func test_a_freshly_spawned_hero_resolves_the_players_recorded_pick() -> void:
	var blue := GameManager.get_player(GameManager.BLUE_TEAM_ID)
	GameManager.pick_hero_ability(blue, HERO_STATS, 0, 1) # slot 0 -> candidate 1 (Battle Cry)

	var hero := GameManager.spawn_unit(HERO_STATS, blue, Vector3.ZERO)

	assert_eq(hero.resolved_abilities[0], BATTLE_CRY)
	assert_eq(hero.resolved_abilities[1], GROUND_SLAM, "an unpicked slot should still default to its own candidate 0")


## Proves the whole pipeline end to end -- cast_ability() actually
## invokes the DRAFTED ability, not the archetype default. Battle Cry
## (self NO_TARGET, +damage buff) is easy to distinguish from Cleave
## Strike (UNIT_TARGET, direct damage) by its observable effect.
func test_cast_ability_casts_the_drafted_ability_not_the_default() -> void:
	var blue := GameManager.get_player(GameManager.BLUE_TEAM_ID)
	GameManager.pick_hero_ability(blue, HERO_STATS, 0, 1) # Battle Cry
	var hero := GameManager.spawn_unit(HERO_STATS, blue, Vector3.ZERO)
	var original_damage := hero.stat_block.damage()

	var cast := hero.cast_ability(0) # NO_TARGET, no target argument needed

	assert_true(cast)
	assert_almost_eq(hero.stat_block.damage(), original_damage + 6.0, 0.01,
		"Battle Cry's damage buff should have applied -- Cleave Strike (the default) has no such self-buff")


## PlayerInputController.first_selected_ability() and HUD's hotbar both
## read unit.resolved_abilities directly (see Scripts/PlayerInputController.gd
## and UI/HUD.gd's _refresh_ability_hotbar()) -- this confirms the
## underlying field they both read is actually populated with the
## drafted pick, without reaching into Main's private _input field
## directly (which collides with Node's own built-in _input(event)
## virtual method when accessed off a plain Node3D-typed reference).
func test_a_drafted_pick_is_visible_on_the_units_resolved_abilities_for_a_different_slot() -> void:
	var blue := GameManager.get_player(GameManager.BLUE_TEAM_ID)
	GameManager.pick_hero_ability(blue, HERO_STATS, 1, 1) # slot 1 -> candidate 1 (Iron Will)
	var hero := GameManager.spawn_unit(HERO_STATS, blue, Vector3.ZERO)

	assert_eq(hero.resolved_abilities[1], IRON_WILL)


## End to end through the real Blood Tournament staggered-deployment
## flow -- proves a drafted pick survives a round boundary "for free"
## (Unit._resolve_abilities() runs inside setup(), which every spawn
## path already calls, unlike hero_progress's restore_hero_progress()
## which needed explicit wiring into 3 separate spawn call sites).
## Same direct BloodTournamentController.deploy_next_pending_slot()
## style test_heroes.gd's own round-boundary test uses, to stay
## deterministic (Blood Tournament is auto-battle -- a real
## GameManager.start_battle() could have the hero act on its own).
func test_a_drafted_pick_survives_a_round_boundary_redeployment() -> void:
	GameManager.set_mode(BloodTournamentMode.new())
	var blue := GameManager.get_player(GameManager.BLUE_TEAM_ID)
	blue.roster = [HERO_STATS]
	GameManager.pick_hero_ability(blue, HERO_STATS, 0, 1) # Battle Cry
	var bt_controller: BloodTournamentController = _main._bt_controller

	bt_controller._pending_deployments[blue.id] = [HERO_STATS]
	bt_controller.deploy_next_pending_slot(blue.id)
	var round_one_hero: Unit = GameManager.get_all_units().filter(func(u: Unit) -> bool: return u.player == blue)[0]
	assert_eq(round_one_hero.resolved_abilities[0], BATTLE_CRY)

	GameManager.reset_battle()
	bt_controller._pending_deployments[blue.id] = [HERO_STATS]
	bt_controller.deploy_next_pending_slot(blue.id)
	var round_two_hero: Unit = GameManager.get_all_units().filter(func(u: Unit) -> bool: return u.player == blue)[0]

	assert_ne(round_two_hero, round_one_hero, "sanity check: this really is a fresh Unit instance")
	assert_eq(round_two_hero.resolved_abilities[0], BATTLE_CRY, "the drafted pick should carry over into the next round's redeployment")
