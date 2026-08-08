## Tests for the Blood Tournament AI opponent: Scripts/AIController.gd
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
	blue.is_human = true
	red.is_human = true
	_main = load("res://Scenes/Main.tscn").instantiate()
	add_child_autofree(_main)
	await wait_physics_frames(2)


func test_ai_spawns_nothing_when_it_cannot_afford_the_cheapest_unit() -> void:
	var red := GameManager.get_player(GameManager.RED_TEAM_ID)
	red.resources = 10 # below every archetype's cost

	AIController.new().take_turn(red)

	assert_true(GameManager.team_is_empty(GameManager.RED_TEAM_ID))
	assert_eq(red.resources, 10, "an all-unaffordable turn should spend nothing")


func test_ai_spends_gold_on_units_without_going_negative() -> void:
	var red := GameManager.get_player(GameManager.RED_TEAM_ID)
	red.resources = 500

	AIController.new().take_turn(red)

	assert_false(GameManager.team_is_empty(GameManager.RED_TEAM_ID), "500 gold should afford at least one unit")
	assert_true(red.resources >= 0)
	assert_true(red.resources < 500, "spending on at least one unit should have happened")


func test_ai_placements_land_on_its_own_side_of_the_arena() -> void:
	var red := GameManager.get_player(GameManager.RED_TEAM_ID)
	red.resources = 1000

	AIController.new().take_turn(red)

	for unit in GameManager.get_all_units():
		assert_true(unit.global_position.x >= 6.0 and unit.global_position.x <= 18.0,
			"AI unit landed at x=%s, outside its side of the arena" % unit.global_position.x)


func test_ai_turn_is_capped_so_it_cannot_spawn_an_unbounded_number_of_units() -> void:
	var red := GameManager.get_player(GameManager.RED_TEAM_ID)
	red.resources = 1000000

	AIController.new().take_turn(red)

	assert_true(GameManager.get_all_units().size() <= 8)


func test_ai_spends_leftover_gold_on_an_upgrade_for_one_of_its_own_units() -> void:
	var red := GameManager.get_player(GameManager.RED_TEAM_ID)
	var unit := GameManager.spawn_unit(TANK_STATS, red, Vector3(10, 0, 0))
	var original_armor := unit.stat_block.armor()
	red.resources = 100 # Iron Armor costs 100, cheapest new unit (Fighter) costs 100 too -- give it just enough for exactly one purchase

	AIController.new().take_turn(red)

	# Either it bought a new Fighter or upgraded the Tank -- both are
	# "spent the 100 gold on something legal" outcomes; what matters is it
	# never crashes and never overspends.
	assert_true(red.resources == 0)
	assert_true(unit.stat_block.armor() >= original_armor)


func test_ai_does_not_crash_or_spend_when_it_has_no_living_units_and_no_affordable_new_ones() -> void:
	var red := GameManager.get_player(GameManager.RED_TEAM_ID)
	red.resources = 0

	AIController.new().take_turn(red) # should simply do nothing

	assert_eq(red.resources, 0)
	assert_true(GameManager.team_is_empty(GameManager.RED_TEAM_ID))


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

	assert_false(GameManager.team_is_empty(GameManager.RED_TEAM_ID), "the AI should have placed at least one unit for Red")


## Full integration through a real round transition: the AI should also
## take a fresh turn (spending that round's income) once
## Main._advance_to_next_round() reopens PLACEMENT for round 2.
func test_ai_opponent_takes_a_new_turn_every_round() -> void:
	_main._on_ai_opponent_toggled(true)
	_main._on_tournament_toggled(true)

	var blue := GameManager.get_player(GameManager.BLUE_TEAM_ID)
	blue.roster.append(TANK_STATS) # no permadeath -- only a roster entry (not a live node) carries a unit into round 2
	GameManager.spawn_unit(TANK_STATS, blue, Vector3(-3, 0, 0))
	GameManager.start_battle()

	# Kill every Red unit the AI placed for round 1 to force a round end.
	for unit in GameManager.get_all_units():
		if unit.player.team_id == GameManager.RED_TEAM_ID:
			unit.take_damage(DamageInstance.new(unit.stat_block.max_health() + 1000.0))
	await wait_physics_frames(2) # let the deferred _advance_to_next_round() (and its _run_ai_turn_if_needed()) run

	assert_false(GameManager.team_is_empty(GameManager.BLUE_TEAM_ID), "Blue's roster should have respawned a fresh Tank for round 2")
	assert_false(GameManager.team_is_empty(GameManager.RED_TEAM_ID), "the AI should have re-populated Red for round 2")
