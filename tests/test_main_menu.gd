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


func test_main_defaults_to_classic_mode_with_no_menu_selection() -> void:
	var main: Node3D = load("res://Scenes/Main.tscn").instantiate()
	add_child_autofree(main)
	await wait_physics_frames(2)

	assert_false(GameManager.current_mode.uses_economy())
	assert_true(GameManager.get_player(GameManager.RED_TEAM_ID).is_human)
