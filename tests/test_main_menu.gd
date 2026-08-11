## Tests for UI/MainMenu.gd (the front screen before Scenes/Main.tscn,
## see project.godot's run/main_scene) and its hand-off to Main.gd via the
## MenuSelection autoload (see Scripts/Autoloads/MenuSelection.gd,
## Main._apply_menu_selection()).
extends GutTest


func before_each() -> void:
	GameManager.reset_battle()
	GameManager.current_mode = ClassicEliminationMode.new() # don't let an earlier test's mode leak into this one
	GameManager.get_player(GameManager.RED_TEAM_ID).is_human = true
	MenuSelection.start_with_tournament = false
	MenuSelection.start_with_hero_footies = false
	MenuSelection.human_team_id = GameManager.BLUE_TEAM_ID
	MenuSelection.bot_team_ids.clear()


func test_toggling_options_and_pressing_play_records_the_selection() -> void:
	var menu: Control = load("res://Scenes/MainMenu.tscn").instantiate()
	add_child_autofree(menu)
	await wait_physics_frames(1)

	menu._tournament_toggle.button_pressed = true
	menu._slot_options[GameManager.RED_TEAM_ID].select(MainMenu.SlotChoice.BOT)
	menu.apply_selection_to_menu_state()

	assert_true(MenuSelection.start_with_tournament)
	assert_eq(MenuSelection.bot_team_ids, [GameManager.RED_TEAM_ID])


## Doesn't exercise _on_settings_pressed() itself (it calls
## change_scene_to_file(), which would tear down this test's own scene
## tree) -- just confirms the button UI/SettingsMenu.gd's screen is
## reachable through actually exists and is wired to the right handler.
func test_settings_button_exists_and_is_wired_to_the_settings_scene() -> void:
	var menu: Control = load("res://Scenes/MainMenu.tscn").instantiate()
	add_child_autofree(menu)
	await wait_physics_frames(1)

	assert_not_null(menu._settings_button)
	assert_true(menu._settings_button.pressed.is_connected(menu._on_settings_pressed))


func test_leaving_both_options_off_records_a_plain_classic_match() -> void:
	var menu: Control = load("res://Scenes/MainMenu.tscn").instantiate()
	add_child_autofree(menu)
	await wait_physics_frames(1)

	menu.apply_selection_to_menu_state()

	assert_false(MenuSelection.start_with_tournament)
	assert_true(MenuSelection.bot_team_ids.is_empty())


## Full hand-off: Main.gd's _ready() should consume MenuSelection's flags
## (set here as if the menu had just run) and end up with Blood Tournament
## active, Red AI-controlled, and Red's round-1 roster already placed --
## exactly as if a human had marked Red "Bot" in the lobby and pressed Play.
func test_main_honors_menu_selection_and_clears_it_afterward() -> void:
	MenuSelection.start_with_tournament = true
	MenuSelection.bot_team_ids = [GameManager.RED_TEAM_ID]

	var main: Node3D = load("res://Scenes/Main.tscn").instantiate()
	add_child_autofree(main)
	await wait_physics_frames(2)

	assert_true(GameManager.current_mode.uses_economy(), "Blood Tournament should already be active")
	assert_false(GameManager.get_player(GameManager.RED_TEAM_ID).is_human, "the bot-marked slot should already be controlling Red")
	assert_false(GameManager.get_player(GameManager.RED_TEAM_ID).roster.is_empty(), "the AI should have bought Red's round 1 roster already")
	assert_false(MenuSelection.start_with_tournament, "the hand-off should be one-shot -- consumed and cleared")
	assert_true(MenuSelection.bot_team_ids.is_empty())


## Both game-mode toggles claim GameManager.current_mode, so the menu itself
## (not just Main.gd's runtime handlers) must not let a player leave both
## pressed -- see _build_options()'s toggle wiring in UI/MainMenu.gd.
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


func test_lobby_defaults_to_you_on_blue_and_empty_on_all_7_others() -> void:
	var menu: Control = load("res://Scenes/MainMenu.tscn").instantiate()
	add_child_autofree(menu)
	await wait_physics_frames(1)

	assert_eq(menu._slot_options.size(), GameManager.TEAM_COUNT)
	assert_eq(menu._slot_options[GameManager.BLUE_TEAM_ID].selected, MainMenu.SlotChoice.YOU)
	for team_id in GameManager.all_team_ids():
		if team_id == GameManager.BLUE_TEAM_ID:
			continue
		assert_eq(menu._slot_options[team_id].selected, MainMenu.SlotChoice.EMPTY, "team %d should default to Empty" % team_id)


func test_selecting_a_different_team_as_you_records_it() -> void:
	var menu: Control = load("res://Scenes/MainMenu.tscn").instantiate()
	add_child_autofree(menu)
	await wait_physics_frames(1)

	menu._slot_options[GameManager.BLUE_TEAM_ID].select(MainMenu.SlotChoice.EMPTY)
	menu._slot_options[3].select(MainMenu.SlotChoice.YOU) # Yellow
	menu.apply_selection_to_menu_state()

	assert_eq(MenuSelection.human_team_id, 3)


## "You" is exclusive across rows -- picking it on one row must reset
## whichever OTHER row currently has it, so exactly one slot is ever "You"
## at a time. Drives the real signal handler directly
## (OptionButton.select() doesn't itself emit item_selected -- only real
## user interaction does, same as HUD._add_toggle_button()'s own documented
## button_pressed-vs-pressed-signal distinction).
func test_picking_you_on_a_new_row_resets_the_previous_you_row() -> void:
	var menu: Control = load("res://Scenes/MainMenu.tscn").instantiate()
	add_child_autofree(menu)
	await wait_physics_frames(1)
	assert_eq(menu._slot_options[GameManager.BLUE_TEAM_ID].selected, MainMenu.SlotChoice.YOU, "sanity check: Blue starts as You")

	menu._slot_options[3].select(MainMenu.SlotChoice.YOU)
	menu._on_slot_option_selected(MainMenu.SlotChoice.YOU, 3)

	assert_eq(menu._slot_options[3].selected, MainMenu.SlotChoice.YOU)
	assert_eq(menu._slot_options[GameManager.BLUE_TEAM_ID].selected, MainMenu.SlotChoice.EMPTY, "Blue should have been reset off You")


## Any number of slots can independently become Bot -- not a single
## blanket on/off toggle or a fixed head-count, the actual point of the
## lobby rework.
func test_any_number_of_slots_can_be_marked_bot_independently() -> void:
	var menu: Control = load("res://Scenes/MainMenu.tscn").instantiate()
	add_child_autofree(menu)
	await wait_physics_frames(1)

	menu._slot_options[GameManager.RED_TEAM_ID].select(MainMenu.SlotChoice.BOT)
	menu._slot_options[2].select(MainMenu.SlotChoice.BOT)
	menu._slot_options[5].select(MainMenu.SlotChoice.BOT)
	menu.apply_selection_to_menu_state()

	assert_eq(MenuSelection.bot_team_ids, [GameManager.RED_TEAM_ID, 2, 5])
	assert_true(MenuSelection.human_team_id == GameManager.BLUE_TEAM_ID, "the untouched You row should still be Blue")


## Full hand-off with a non-default team pick: only the EXPLICITLY
## bot-marked teams should become AI-controlled -- generalizes the single
## Blue-human/AI-Red assumption test_main_honors_menu_selection_and_clears_it_afterward()
## already covers for the default case.
func test_main_honors_a_non_blue_team_selection_and_ai_controls_only_the_marked_bots() -> void:
	MenuSelection.start_with_tournament = true
	MenuSelection.human_team_id = 3 # Yellow
	MenuSelection.bot_team_ids = [GameManager.BLUE_TEAM_ID, GameManager.RED_TEAM_ID]

	var main: Node3D = load("res://Scenes/Main.tscn").instantiate()
	add_child_autofree(main)
	await wait_physics_frames(2)

	assert_true(GameManager.get_player(3).is_human, "Yellow (the picked team) should stay human")
	assert_false(GameManager.get_player(GameManager.BLUE_TEAM_ID).is_human, "explicitly bot-marked teams should be AI-controlled")
	assert_false(GameManager.get_player(GameManager.RED_TEAM_ID).is_human)
	assert_true(GameManager.get_player(2).is_human, "a team left off the bot list entirely (Empty) should stay is_human's inert default")
	assert_false(GameManager.get_player(GameManager.RED_TEAM_ID).roster.is_empty(), "the AI should have bought a roster for a non-Blue AI team too")
	assert_eq(MenuSelection.human_team_id, GameManager.BLUE_TEAM_ID, "the hand-off should be one-shot -- consumed and reset to the default")
	assert_true(MenuSelection.bot_team_ids.is_empty())
