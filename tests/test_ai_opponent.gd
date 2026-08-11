## Tests for the Blood Tournament AI opponent: Scripts/BloodTournament/AIController.gd
## (spends a Player's gold on units/an upgrade during PLACEMENT) and its
## wiring into Main.gd (the "AI Opponent" HUD toggle flips Red's
## Player.is_human and triggers a turn at every PLACEMENT entry point).
extends GutTest

const TANK_STATS: UnitStats = preload("res://Resources/Units/TankStats.tres")

var _main: Node3D


func before_each() -> void:
	GameManager.reset_battle()
	GameManager.current_mode = ClassicEliminationMode.new() # don't let an earlier test's mode leak in
	var blue := GameManager.get_player(GameManager.BLUE_TEAM_ID)
	var red := GameManager.get_player(GameManager.RED_TEAM_ID)
	# Player is a plain RefCounted that outlives each test, same as
	# GameManager itself -- reset both fields an earlier test (or this
	# one's own AI-opponent toggling) could have left dirty.
	blue.resources = 0
	red.resources = 0
	blue.blood_points = 0
	red.blood_points = 0
	blue.roster.clear()
	red.roster.clear()
	blue.roster_upgrades.clear()
	red.roster_upgrades.clear()
	blue.is_human = true
	red.is_human = true
	_main = load("res://Scenes/Main.tscn").instantiate()
	add_child_autofree(_main)
	await wait_physics_frames(2)


func test_ai_spawns_nothing_when_it_cannot_afford_the_cheapest_unit() -> void:
	var red := GameManager.get_player(GameManager.RED_TEAM_ID)
	red.resources = 10 # below every archetype's cost

	AIController.new().take_turn(red)

	assert_true(red.roster.is_empty())
	assert_eq(red.resources, 10, "an all-unaffordable turn should spend nothing")


func test_ai_spends_gold_on_units_without_going_negative() -> void:
	var red := GameManager.get_player(GameManager.RED_TEAM_ID)
	red.resources = 500

	AIController.new().take_turn(red)

	assert_false(red.roster.is_empty(), "500 gold should afford at least one unit")
	assert_true(red.resources >= 0)
	assert_true(red.resources < 500, "spending on at least one unit should have happened")


## AIController._MAX_NEW_UNITS_PER_TURN (8) caps purchased roster slots per
## turn -- buying is data-only now (see AIController.take_turn()'s class
## doc comment), nothing spawns until the staggered deployment queue runs
## at battle start.
func test_ai_turn_is_capped_so_it_cannot_buy_an_unbounded_number_of_roster_slots() -> void:
	var red := GameManager.get_player(GameManager.RED_TEAM_ID)
	red.resources = 1000000

	AIController.new().take_turn(red)

	assert_true(red.roster.size() <= 8)


## Upgrades cost blood points, not gold (see GameManager.buy_upgrade()) --
## with no blood points ever set here, the AI should just spend all its
## gold on a new unit and never touch the upgrade branch at all.
func test_ai_spends_all_its_gold_on_units_not_upgrades() -> void:
	var red := GameManager.get_player(GameManager.RED_TEAM_ID)
	var unit := GameManager.spawn_unit(TANK_STATS, red, Vector3(10, 0, 0))
	var original_armor := unit.stat_block.armor()
	red.resources = 100 # exactly Fighter's cost -- one purchase, nothing left over

	AIController.new().take_turn(red)

	assert_eq(red.resources, 0)
	assert_almost_eq(unit.stat_block.armor(), original_armor, 0.01, "no blood points means the upgrade branch should never fire")


## AIController's upgrade purchase is account-wide now (GameManager.buy_roster_upgrade()),
## not targeted at a living unit -- no unit needs to exist at all for the
## AI to buy one, unlike the old model this replaced.
func test_ai_spends_blood_points_on_an_account_wide_upgrade() -> void:
	GameManager.set_mode(BloodTournamentMode.new()) # buy_roster_upgrade() itself gates on current_mode.uses_economy()
	var red := GameManager.get_player(GameManager.RED_TEAM_ID)
	red.resources = 0 # nothing affordable in _UNIT_POOL -- isolates the upgrade branch
	red.blood_points = 100 # Iron Armor's cost

	AIController.new().take_turn(red)

	assert_eq(red.blood_points, 0)
	assert_eq(red.roster_upgrades.size(), 1, "Iron Armor should have been bought for Red's account")


func test_ai_does_not_crash_or_spend_when_it_has_no_living_units_and_no_affordable_new_ones() -> void:
	var red := GameManager.get_player(GameManager.RED_TEAM_ID)
	red.resources = 0

	AIController.new().take_turn(red) # should simply do nothing

	assert_eq(red.resources, 0)
	assert_true(red.roster.is_empty())


func test_toggling_ai_opponent_flips_is_human_and_forces_blue_selection() -> void:
	_main._on_team_selected(GameManager.RED_TEAM_ID)
	assert_eq(SelectionManager.local_player, GameManager.get_player(GameManager.RED_TEAM_ID))

	_main._on_ai_opponent_toggled(true)

	assert_false(GameManager.get_player(GameManager.RED_TEAM_ID).is_human)
	assert_eq(SelectionManager.local_player, GameManager.get_player(GameManager.BLUE_TEAM_ID),
		"enabling the AI opponent should force the human back to Blue")

	_main._on_ai_opponent_toggled(false)
	assert_true(GameManager.get_player(GameManager.RED_TEAM_ID).is_human)


## Full integration: turning Blood Tournament on with the AI opponent
## already enabled should populate Red's roster automatically, with no
## human ever clicking a placement button for Red.
func test_ai_opponent_auto_populates_red_when_blood_tournament_starts() -> void:
	_main._on_ai_opponent_toggled(true)
	_main._on_tournament_toggled(true) # grants starting gold, then _run_ai_turn_if_needed() should spend it

	assert_false(GameManager.get_player(GameManager.RED_TEAM_ID).roster.is_empty(), "the AI should have bought at least one roster slot for Red")


## Full integration through a real round transition: the AI should also
## take a fresh turn (spending that round's income) once
## Main._advance_to_next_round() reopens PLACEMENT for round 2. Buying is
## data-only under the staggered/staging-area deployment model (see
## Main._begin_staggered_deployment()), so round 1's units only appear
## once battle actually starts, and round 2's roster is what's checked
## afterward -- not live units, which go back to empty the moment
## reset_battle() runs.
func test_ai_opponent_takes_a_new_turn_every_round() -> void:
	_main._on_ai_opponent_toggled(true)
	_main._on_tournament_toggled(true)

	var blue := GameManager.get_player(GameManager.BLUE_TEAM_ID)
	var red := GameManager.get_player(GameManager.RED_TEAM_ID)
	blue.roster.append(TANK_STATS) # no permadeath -- only a roster entry (not a live node) carries a unit into round 2
	assert_false(red.roster.is_empty(), "sanity check: the AI should already have bought into Red's roster")

	GameManager.start_battle()
	await wait_physics_frames(2) # let the staggered deployment queue spawn round 1's rosters

	# Kill every Red unit the AI placed for round 1 to force a round end.
	for unit in GameManager.get_all_units():
		if unit.player.team_id == GameManager.RED_TEAM_ID:
			unit.take_damage(DamageInstance.new(unit.stat_block.max_health() + 1000.0))
	await wait_physics_frames(2) # let the deferred _advance_to_next_round() (and its _run_ai_turn_if_needed()) run

	assert_true(GameManager.is_placement_phase())
	assert_false(blue.roster.is_empty(), "Blue's roster should still carry the Tank into round 2 -- no permadeath")
	assert_false(red.roster.is_empty(), "the AI should have re-populated Red's roster for round 2")


# ---------------------------------------------------------------------
# Mid-match HUD toggle visibility
# ---------------------------------------------------------------------

## Blood Tournament now decides every slot's human/bot status entirely at
## the main menu's per-slot lobby (see UI/MainMenu.gd) -- there's only
## ever one human team the whole match, so the mid-match "AI Opponent"
## toggle and the Blue/Red team-select buttons have nothing left to do
## once it's active. Hidden as soon as round 1's PLACEMENT opens, not
## only "once underway" -- see HUD.refresh_match_toggles_visibility().
func test_blue_red_and_ai_toggle_hide_once_blood_tournament_activates() -> void:
	assert_true(_main._hud._blue_team_button.visible, "sanity check: visible in classic mode")
	assert_true(_main._hud._red_team_button.visible)
	assert_true(_main._hud._ai_toggle.visible)

	_main._on_tournament_toggled(true)

	assert_false(_main._hud._blue_team_button.visible)
	assert_false(_main._hud._red_team_button.visible)
	assert_false(_main._hud._ai_toggle.visible)


## Classic mode (and, by extension, Hero Footies -- neither uses_economy())
## keeps all three, unchanged -- still useful for local hotseat-style
## manual testing.
func test_blue_red_and_ai_toggle_stay_visible_in_classic_mode() -> void:
	_main._on_tournament_toggled(true)
	assert_false(_main._hud._blue_team_button.visible, "sanity check: hidden once Blood Tournament is on")

	_main._on_tournament_toggled(false)

	assert_true(_main._hud._blue_team_button.visible)
	assert_true(_main._hud._red_team_button.visible)
	assert_true(_main._hud._ai_toggle.visible)
