## Front screen shown before Scenes/Main.tscn (see project.godot's
## run/main_scene). Offers the same pre-match toggles Main.tscn's own HUD
## does mid-session (Blood Tournament, Hero Footies, AI Opponent -- see
## UI/HUD.gd's _build_tournament_toggle()/_build_hero_footies_toggle()/
## _build_ai_toggle()) plus a plain-text controls reference, since the
## input surface (drag-select, right-click orders, Q/W/E abilities with
## click-to-target, control groups, U/I upgrades...) has grown well past
## "click to place, click to fight" since this was the only screen anyone
## saw. Blood Tournament and Hero Footies are mutually exclusive here too
## (see _build_options()' own toggle wiring), matching the guard
## Main._on_tournament_toggled()/_on_hero_footies_toggled() already
## enforce mid-match -- both claim GameManager.current_mode.
##
## Built in code, same as UI/HUD.gd and for the same reason: a handful of
## controls is just as readable this way and keeps it in one file. Choices
## are handed off via the MenuSelection autoload (see its own doc comment
## for why that's a separate tiny autoload rather than fields on
## GameManager) -- Main.gd consumes and clears them in _ready(). A
## "Settings" button (below "Play") leads to Scenes/SettingsMenu.tscn,
## Phase 10's keybind remap screen.
extends Control

var _tournament_toggle: Button
var _ai_toggle: Button
var _hero_footies_toggle: Button
var _settings_button: Button
var _team_option: OptionButton
var _team_count_option: OptionButton


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)

	var background := ColorRect.new()
	background.color = Color(0.08, 0.09, 0.08)
	background.set_anchors_preset(Control.PRESET_FULL_RECT)
	background.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(background)

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(center)

	var column := VBoxContainer.new()
	column.alignment = BoxContainer.ALIGNMENT_CENTER
	column.add_theme_constant_override("separation", 18)
	center.add_child(column)

	_build_title(column)
	_build_options(column)
	_build_controls_reference(column)
	_build_play_button(column)
	_build_settings_button(column)


func _build_title(parent: Control) -> void:
	var title := Label.new()
	title.text = "BattleFoundry"
	title.add_theme_font_size_override("font_size", 40)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	parent.add_child(title)


func _build_options(parent: Control) -> void:
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 12)
	parent.add_child(row)

	_tournament_toggle = _add_toggle(row, "Blood Tournament: Off", "Blood Tournament: On")
	_hero_footies_toggle = _add_toggle(row, "Hero Footies: Off", "Hero Footies: On")
	_ai_toggle = _add_toggle(row, "AI Opponent: Off", "AI Opponent: On")
	_build_team_selector(row)
	_build_team_count_selector(row)

	# Both game-mode toggles claim GameManager.current_mode (same mutual
	# exclusion Main._on_tournament_toggled()/_on_hero_footies_toggled()
	# already enforce mid-match) -- mirrored here so the menu's own
	# checkbox state can't silently disagree with what Play would actually
	# start once Main._apply_menu_selection() runs.
	_tournament_toggle.toggled.connect(func(enabled: bool):
		if enabled:
			_hero_footies_toggle.set_pressed_no_signal(false)
			_hero_footies_toggle.text = "Hero Footies: Off"
	)
	_hero_footies_toggle.toggled.connect(func(enabled: bool):
		if enabled:
			_tournament_toggle.set_pressed_no_signal(false)
			_tournament_toggle.text = "Blood Tournament: Off"
	)


## Which of the 8 registered teams the player plays as -- only meaningful
## alongside the AI Opponent toggle above (every OTHER team becomes AI,
## see Main._apply_menu_selection()); harmless to leave at its default
## otherwise, same as picking a team in classic mode with no AI opponent
## on does nothing different from today. Defaults to index 0
## (GameManager.BLUE_TEAM_ID), matching the original hardcoded behavior.
func _build_team_selector(parent: Control) -> void:
	_team_option = OptionButton.new()
	_team_option.custom_minimum_size = Vector2(140, 40)
	for team_id in GameManager.all_team_ids():
		_team_option.add_item(GameManager.get_team_display_name(team_id))
	_team_option.selected = GameManager.BLUE_TEAM_ID
	parent.add_child(_team_option)


## How many total teams (the player's own plus AI-filled slots) play this
## match, 2 to GameManager.TEAM_COUNT -- confirmed design: "fill all
## slots with bots or just some of them," not always a full 8. Item index
## 0 -> 2 teams, ..., last index -> TEAM_COUNT teams; defaults selected to
## the last item (the full 8-team experience stays the default, this just
## lets the player dial it down).
func _build_team_count_selector(parent: Control) -> void:
	_team_count_option = OptionButton.new()
	_team_count_option.custom_minimum_size = Vector2(110, 40)
	for count in range(2, GameManager.TEAM_COUNT + 1):
		_team_count_option.add_item("%d Teams" % count)
	_team_count_option.selected = _team_count_option.item_count - 1
	parent.add_child(_team_count_option)


func _add_toggle(parent: Control, off_text: String, on_text: String) -> Button:
	var button := Button.new()
	button.text = off_text
	button.custom_minimum_size = Vector2(190, 40)
	button.toggle_mode = true
	button.toggled.connect(func(enabled: bool): button.text = on_text if enabled else off_text)
	button.toggled.connect(func(_enabled: bool): Sfx.play_ui_click()) # only ever fires on real interaction -- the mutual-exclusion resets in _build_options() use set_pressed_no_signal() specifically to avoid re-triggering this
	parent.add_child(button)
	return button


func _build_controls_reference(parent: Control) -> void:
	var panel := PanelContainer.new()
	parent.add_child(panel)

	var label := Label.new()
	label.text = "Controls\n\n" \
		+ "Left-click: place a unit / select a unit (drag for box-select)\n" \
		+ "Right-click: attack / follow / attack-move -- sells a unit during placement\n" \
		+ "S / H: stop / hold position\n" \
		+ "P: patrol (click a destination) -- right-click or Esc cancels\n" \
		+ "Q / W / E: cast ability slot 0/1/2 (click a unit to target it)\n" \
		+ "1-9: recall a control group -- Ctrl+1-9: assign the current selection\n" \
		+ "U / I: buy a shop upgrade for your whole roster (Blood Tournament only)\n" \
		+ "Mouse wheel / right-drag: zoom / orbit the camera"
	label.add_theme_font_size_override("font_size", 16)
	panel.add_child(label)


func _build_play_button(parent: Control) -> void:
	var button := Button.new()
	button.text = "Play"
	button.custom_minimum_size = Vector2(190, 48)
	button.pressed.connect(_on_play_pressed)
	button.pressed.connect(func(): Sfx.play_ui_click()) # Sfx is an autoload, so this keeps playing across the change_scene_to_file() below without issue
	parent.add_child(button)


## Split from the scene-change call itself so tests can exercise the
## selection hand-off without also making a GUT test's own SceneTree tear
## down and reload a whole new scene.
func apply_selection_to_menu_state() -> void:
	MenuSelection.start_with_tournament = _tournament_toggle.button_pressed
	MenuSelection.start_with_hero_footies = _hero_footies_toggle.button_pressed
	MenuSelection.start_with_ai_opponent = _ai_toggle.button_pressed
	MenuSelection.human_team_id = _team_option.selected
	MenuSelection.team_count = _team_count_option.selected + 2


func _on_play_pressed() -> void:
	apply_selection_to_menu_state()
	get_tree().change_scene_to_file("res://Scenes/Main.tscn")


## Roadmap Phase 10's "settings/keybind remapping UI" -- Scripts/Hotkeys.gd
## already has the actual InputMap-rebind mechanism (rebind(), tested by
## tests/test_hotkeys.gd); Scripts/SettingsMenu.gd is the screen that
## finally calls into it. A separate scene (not a panel bolted onto this
## one) since it needs its own full-screen key-capture input handling
## (_unhandled_input()) that would otherwise compete with this menu's own.
func _build_settings_button(parent: Control) -> void:
	_settings_button = Button.new()
	_settings_button.text = "Settings"
	_settings_button.custom_minimum_size = Vector2(190, 40)
	_settings_button.pressed.connect(_on_settings_pressed)
	_settings_button.pressed.connect(func(): Sfx.play_ui_click())
	parent.add_child(_settings_button)


func _on_settings_pressed() -> void:
	get_tree().change_scene_to_file("res://Scenes/SettingsMenu.tscn")
