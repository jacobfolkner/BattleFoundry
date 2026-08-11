## Keybind remapping screen -- closes roadmap Phase 10's "settings/
## keybind remapping UI" item. Scripts/Hotkeys.gd already proves the
## underlying InputMap-rebind mechanism works (rebind(), tested by
## tests/test_hotkeys.gd) but had no player-facing screen calling into it
## before this. Built in code, same convention as UI/HUD.gd/
## Scripts/MainMenu.gd -- reachable from MainMenu.gd's new "Settings"
## button.
##
## Rebinding flow: pressing a row's own "Rebind" button puts that row
## into "listening" mode (begin_rebind()) -- the next real key press
## (_unhandled_input()) either applies the rebind (Hotkeys.rebind()) or,
## if that key is already claimed by a different action
## (Hotkeys.find_conflicting_action()), refuses and shows an inline
## warning instead of silently letting two actions share one key. Escape
## cancels a pending rebind without changing anything.
extends Control

var _pending_rebind_action: String = ""
var _status_label: Label
var _key_labels: Dictionary = {} # action_name -> Label showing its current key
var _reset_button: Button
var _back_button: Button


func _ready() -> void:
	# Explicit size from the viewport rect, not anchors alone -- same
	# "scene root loaded from a .tscn never resolves a real size from
	# set_anchors_preset(FULL_RECT) alone" issue MainMenu.gd hit and
	# documents in its own _ready(); everything here was rendering
	# jammed at the top-left corner for the same reason.
	set_anchors_preset(Control.PRESET_FULL_RECT)
	size = get_viewport_rect().size

	var background := ColorRect.new()
	background.color = Color(0.08, 0.09, 0.08)
	background.size = size
	background.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(background)

	var center := CenterContainer.new()
	center.size = size
	add_child(center)

	var column := VBoxContainer.new()
	column.alignment = BoxContainer.ALIGNMENT_CENTER
	column.add_theme_constant_override("separation", 12)
	center.add_child(column)

	var title := Label.new()
	title.text = "Settings — Keybinds"
	title.add_theme_font_size_override("font_size", 32)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	column.add_child(title)

	# Same dark-card treatment as UI/HUD.gd's placement screen and
	# Scripts/MainMenu.gd -- previously a bare column of labels with no
	# visual grouping at all, one of the screens flagged as inconsistent
	# with the rest of the game's UI.
	var keybinds_card := _wrap_in_card(column, "")
	# Fixed-height scroll instead of letting the row list grow the whole
	# screen taller than the viewport -- already close to the 1080px
	# ceiling with today's 21 actions before adding any card padding, and
	# this stays correct if a future session adds more.
	var scroll := ScrollContainer.new()
	# Width matches one full row's natural size (220 name + 150 key + 100
	# Rebind button + 2x16 separation = 502) plus room for the vertical
	# scrollbar -- too narrow clips the Rebind column off entirely
	# instead of wrapping/scrolling it into view.
	scroll.custom_minimum_size = Vector2(540, 500)
	keybinds_card.add_child(scroll)
	var rows_column := VBoxContainer.new()
	rows_column.add_theme_constant_override("separation", 8)
	scroll.add_child(rows_column)

	for action_name in Hotkeys.DEFAULT_BINDINGS:
		_build_row(rows_column, action_name)

	_status_label = Label.new()
	_status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_status_label.add_theme_color_override("font_color", Color(1, 0.5, 0.4))
	column.add_child(_status_label)

	var actions_card := _wrap_in_card(column, "")
	var button_row := HBoxContainer.new()
	button_row.alignment = BoxContainer.ALIGNMENT_CENTER
	button_row.add_theme_constant_override("separation", 12)
	actions_card.add_child(button_row)

	_reset_button = Button.new()
	_reset_button.text = "Reset to Defaults"
	_reset_button.custom_minimum_size = Vector2(180, 40)
	_reset_button.pressed.connect(_on_reset_pressed)
	_reset_button.pressed.connect(func(): Sfx.play_ui_click())
	button_row.add_child(_reset_button)

	_back_button = Button.new()
	_back_button.text = "Back"
	_back_button.custom_minimum_size = Vector2(120, 40)
	_back_button.pressed.connect(_on_back_pressed)
	_back_button.pressed.connect(func(): Sfx.play_ui_click())
	button_row.add_child(_back_button)


## Same pattern as Scripts/MainMenu.gd's own _wrap_in_card() (itself
## copied from UI/HUD.gd's) -- kept as a 3rd private copy rather than a
## shared helper since none of these 3 classes share a common ancestor
## worth introducing just for this, matching this codebase's existing
## tolerance for a few duplicated lines over a premature abstraction.
func _wrap_in_card(parent: Control, title: String) -> VBoxContainer:
	var card := PanelContainer.new()
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.08, 0.08, 0.1, 0.75)
	style.set_corner_radius_all(6)
	style.set_content_margin_all(12)
	card.add_theme_stylebox_override("panel", style)
	parent.add_child(card)

	var content := VBoxContainer.new()
	content.add_theme_constant_override("separation", 8)
	card.add_child(content)

	if title != "":
		var header := Label.new()
		header.text = title
		header.add_theme_font_size_override("font_size", 16)
		content.add_child(header)

	return content


func _build_row(parent: Control, action_name: String) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 16)
	parent.add_child(row)

	var name_label := Label.new()
	name_label.text = Hotkeys.display_name(action_name)
	name_label.custom_minimum_size = Vector2(220, 0)
	row.add_child(name_label)

	var key_label := Label.new()
	key_label.custom_minimum_size = Vector2(150, 0)
	key_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	row.add_child(key_label)
	_key_labels[action_name] = key_label

	var rebind_button := Button.new()
	rebind_button.text = "Rebind"
	rebind_button.custom_minimum_size = Vector2(100, 32)
	rebind_button.pressed.connect(func(): begin_rebind(action_name))
	rebind_button.pressed.connect(func(): Sfx.play_ui_click())
	row.add_child(rebind_button)

	_refresh_key_label(action_name)


func _current_key_text(action_name: String) -> String:
	var events := InputMap.action_get_events(action_name)
	if events.is_empty():
		return "(unbound)"
	var event := events[0]
	if event is InputEventKey:
		return OS.get_keycode_string((event as InputEventKey).keycode)
	return "?"


func _refresh_key_label(action_name: String) -> void:
	var label: Label = _key_labels[action_name]
	label.text = "Press any key…" if _pending_rebind_action == action_name else _current_key_text(action_name)


func _refresh_all_key_labels() -> void:
	for action_name in _key_labels:
		_refresh_key_label(action_name)


## Split from _unhandled_input() so tests can drive the exact same logic
## directly (this project's established style for anything a key press
## ultimately triggers -- see Main._try_place_unit()/etc.'s own "thin
## input delegate, test calls the real logic directly" pattern) without
## needing to route a synthetic InputEvent through the whole SceneTree.
func begin_rebind(action_name: String) -> void:
	_pending_rebind_action = action_name
	_status_label.text = ""
	_refresh_all_key_labels()


func _unhandled_input(event: InputEvent) -> void:
	if _pending_rebind_action.is_empty():
		return
	if event is InputEventKey and event.pressed and not event.echo:
		_handle_rebind_key(event as InputEventKey)
		get_viewport().set_input_as_handled()


func _handle_rebind_key(event: InputEventKey) -> void:
	var action_name := _pending_rebind_action
	_pending_rebind_action = ""

	if event.keycode == KEY_ESCAPE:
		_refresh_all_key_labels()
		return

	var conflicting_action := Hotkeys.find_conflicting_action(action_name, event.keycode)
	if not conflicting_action.is_empty():
		_status_label.text = "%s is already bound to %s" % [OS.get_keycode_string(event.keycode), Hotkeys.display_name(conflicting_action)]
		_refresh_all_key_labels()
		return

	Hotkeys.rebind(action_name, event.keycode)
	_status_label.text = ""
	_refresh_all_key_labels()


func _on_reset_pressed() -> void:
	Hotkeys.reset_to_defaults()
	_status_label.text = ""
	_pending_rebind_action = ""
	_refresh_all_key_labels()


func _on_back_pressed() -> void:
	get_tree().change_scene_to_file("res://Scenes/MainMenu.tscn")
