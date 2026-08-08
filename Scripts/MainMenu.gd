## Front screen shown before Scenes/Main.tscn (see project.godot's
## run/main_scene). Offers the same two pre-match toggles Main.tscn's own
## HUD does mid-session (Blood Tournament, AI Opponent -- see
## UI/HUD.gd's _build_tournament_toggle()/_build_ai_toggle()) plus a
## plain-text controls reference, since the input surface (drag-select,
## right-click orders, Q/W/E abilities with click-to-target, control
## groups, U/I upgrades...) has grown well past "click to place, click to
## fight" since this was the only screen anyone saw.
##
## Built in code, same as UI/HUD.gd and for the same reason: a handful of
## controls is just as readable this way and keeps it in one file. Choices
## are handed off via the MenuSelection autoload (see its own doc comment
## for why that's a separate tiny autoload rather than fields on
## GameManager) -- Main.gd consumes and clears them in _ready().
extends Control

var _tournament_toggle: Button
var _ai_toggle: Button


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
	_ai_toggle = _add_toggle(row, "AI Opponent: Off", "AI Opponent: On")


func _add_toggle(parent: Control, off_text: String, on_text: String) -> Button:
	var button := Button.new()
	button.text = off_text
	button.custom_minimum_size = Vector2(190, 40)
	button.toggle_mode = true
	button.toggled.connect(func(enabled: bool): button.text = on_text if enabled else off_text)
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
		+ "Q / W / E: cast ability slot 0/1/2 (click a unit to target it)\n" \
		+ "1-9: recall a control group -- Ctrl+1-9: assign the current selection\n" \
		+ "U / I: buy a shop upgrade for the selected unit (Blood Tournament only)\n" \
		+ "Mouse wheel / right-drag: zoom / orbit the camera"
	label.add_theme_font_size_override("font_size", 16)
	panel.add_child(label)


func _build_play_button(parent: Control) -> void:
	var button := Button.new()
	button.text = "Play"
	button.custom_minimum_size = Vector2(190, 48)
	button.pressed.connect(_on_play_pressed)
	parent.add_child(button)


## Split from the scene-change call itself so tests can exercise the
## selection hand-off without also making a GUT test's own SceneTree tear
## down and reload a whole new scene.
func apply_selection_to_menu_state() -> void:
	MenuSelection.start_with_tournament = _tournament_toggle.button_pressed
	MenuSelection.start_with_ai_opponent = _ai_toggle.button_pressed


func _on_play_pressed() -> void:
	apply_selection_to_menu_state()
	get_tree().change_scene_to_file("res://Scenes/Main.tscn")
