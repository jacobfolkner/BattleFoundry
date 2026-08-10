## Tests for UI/MainMenu.gd (the front screen before Scenes/Main.tscn,
## see project.godot's run/main_scene) and its hand-off to Main.gd via the
## MenuSelection autoload (see Scripts/MenuSelection.gd,
## Main._apply_menu_selection()).
extends GutTest


func before_each() -> void:
	GameManager.reset_battle()
	GameManager.current_mode = ClassicEliminationMode.new() # don't let an earlier test's mode leak into this one
	GameManager.get_player(GameManager.RED_TEAM_ID).is_human = true
	MenuSelection.start_with_tournament = false
	MenuSelection.start_with_hero_footies = false
	MenuSelection.start_with_ai_opponent = false


func test_toggling_options_and_pressing_play_records_the_selection() -> void:
	var menu: Control = load("res://Scenes/MainMenu.tscn").instantiate()
	add_child_autofree(menu)
	await wait_physics_frames(1)

	menu._tournament_toggle.button_pressed = true
	menu._ai_toggle.button_pressed = true
	menu.apply_selection_to_menu_state()

	assert_true(MenuSelection.start_with_tournament)
	assert_true(MenuSelection.start_with_ai_opponent)


func test_leaving_both_options_off_records_a_plain_classic_match() -> void:
	var menu: Control = load("res://Scenes/MainMenu.tscn").instantiate()
	add_child_autofree(menu)
	await wait_physics_frames(1)

	menu.apply_selection_to_menu_state()

	assert_false(MenuSelection.start_with_tournament)
	assert_false(MenuSelection.start_with_ai_opponent)


## Full hand-off: Main.gd's _ready() should consume MenuSelection's flags
## (set here as if the menu had just run) and end up with Blood Tournament
## active, Red AI-controlled, and Red's round-1 roster already placed --
## exactly as if a human had clicked both HUD toggles themselves after the
## scene loaded.
func test_main_honors_menu_selection_and_clears_it_afterward() -> void:
	MenuSelection.start_with_tournament = true
	MenuSelection.start_with_ai_opponent = true

	var main: Node3D = load("res://Scenes/Main.tscn").instantiate()
	add_child_autofree(main)
	await wait_physics_frames(2)

	assert_true(GameManager.current_mode.uses_economy(), "Blood Tournament should already be active")
	assert_false(GameManager.get_player(GameManager.RED_TEAM_ID).is_human, "the AI opponent should already be controlling Red")
	assert_false(GameManager.get_player(GameManager.RED_TEAM_ID).roster.is_empty(), "the AI should have bought Red's round 1 roster already")
	assert_false(MenuSelection.start_with_tournament, "the hand-off should be one-shot -- consumed and cleared")
	assert_false(MenuSelection.start_with_ai_opponent)


## Both game-mode toggles claim GameManager.current_mode, so the menu itself
## (not just Main.gd's runtime handlers) must not let a player leave both
## pressed -- see _build_options()'s toggle wiring in Scripts/MainMenu.gd.
func test_hero_footies_and_tournament_toggles_are_mutually_exclusive_in_the_menu() -> void:
	var menu: Control = load("res://Scenes/MainMenu.tscn").instantiate()
	add_child_autofree(menu)
	await wait_physics_frames(1)

	menu._tournament_toggle.button_pressed = true
	assert_false(menu._hero_footies_toggle.button_pressed)

	menu._hero_footies_toggle.button_pressed = true
	assert_false(menu._tournament_toggle.button_pressed, "turning on Hero Footies should turn Blood Tournament back off")


func test_toggling_hero_footies_and_pressing_play_records_the_selection() -> void:
	var menu: Control = load("res://Scenes/MainMenu.tscn").instantiate()
	add_child_autofree(menu)
	await wait_physics_frames(1)

	menu._hero_footies_toggle.button_pressed = true
	menu.apply_selection_to_menu_state()

	assert_true(MenuSelection.start_with_hero_footies)
	assert_false(MenuSelection.start_with_tournament)


## Full hand-off: Main.gd's _ready() should consume the flag and actually
## activate HeroFootiesMode, the same as clicking the HUD's own toggle
## mid-session would (see Main._on_hero_footies_toggled()).
func test_main_honors_hero_footies_menu_selection_and_clears_it_afterward() -> void:
	MenuSelection.start_with_hero_footies = true

	var main: Node3D = load("res://Scenes/Main.tscn").instantiate()
	add_child_autofree(main)
	await wait_physics_frames(2)

	assert_true(GameManager.current_mode is HeroFootiesMode)
	assert_false(MenuSelection.start_with_hero_footies, "the hand-off should be one-shot -- consumed and cleared")


func test_main_defaults_to_classic_mode_with_no_menu_selection() -> void:
	var main: Node3D = load("res://Scenes/Main.tscn").instantiate()
	add_child_autofree(main)
	await wait_physics_frames(2)

	assert_false(GameManager.current_mode.uses_economy())
	assert_true(GameManager.get_player(GameManager.RED_TEAM_ID).is_human)


func test_team_selector_defaults_to_blue_and_lists_all_8_teams() -> void:
	var menu: Control = load("res://Scenes/MainMenu.tscn").instantiate()
	add_child_autofree(menu)
	await wait_physics_frames(1)

	assert_eq(menu._team_option.selected, GameManager.BLUE_TEAM_ID)
	assert_eq(menu._team_option.item_count, GameManager.TEAM_COUNT)


func test_selecting_a_different_team_records_it() -> void:
	var menu: Control = load("res://Scenes/MainMenu.tscn").instantiate()
	add_child_autofree(menu)
	await wait_physics_frames(1)

	menu._team_option.selected = 3 # Yellow
	menu.apply_selection_to_menu_state()

	assert_eq(MenuSelection.human_team_id, 3)


## Full hand-off with a non-default team pick: every OTHER registered
## team should become AI-controlled, not just Red -- generalizes the
## single Blue-human/AI-Red assumption test_main_honors_menu_selection_and_clears_it_afterward()
## already covers for the default case.
func test_main_honors_a_non_blue_team_selection_and_ai_controls_every_other_team() -> void:
	MenuSelection.start_with_tournament = true
	MenuSelection.start_with_ai_opponent = true
	MenuSelection.human_team_id = 3 # Yellow

	var main: Node3D = load("res://Scenes/Main.tscn").instantiate()
	add_child_autofree(main)
	await wait_physics_frames(2)

	assert_true(GameManager.get_player(3).is_human, "Yellow (the picked team) should stay human")
	assert_false(GameManager.get_player(GameManager.BLUE_TEAM_ID).is_human, "every other team, Blue included, should be AI-controlled now")
	assert_false(GameManager.get_player(GameManager.RED_TEAM_ID).is_human)
	assert_false(GameManager.get_player(GameManager.RED_TEAM_ID).roster.is_empty(), "the AI should have bought a roster for a non-Blue AI team too")
	assert_eq(MenuSelection.human_team_id, GameManager.BLUE_TEAM_ID, "the hand-off should be one-shot -- consumed and reset to the default")
