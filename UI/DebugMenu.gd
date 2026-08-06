## Toggleable panel (backtick) with one checkbox per Scripts/DebugSettings.gd
## flag, built generically from get_flag_names() -- adding a new flag
## there is all a new toggle needs, no changes here. Backtick, not F1:
## F1 is commonly intercepted by the OS/window manager as "Help" before
## it ever reaches the game window (confirmed via WSLg during dev).
extends Control

const _MARGIN := 16.0
const _WIDTH := 200.0

var _panel: PanelContainer


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE

	_panel = PanelContainer.new()
	add_child(_panel)
	_panel.custom_minimum_size = Vector2(_WIDTH, 0)
	_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	_panel.visible = false

	var list := VBoxContainer.new()
	_panel.add_child(list)

	var title := Label.new()
	title.text = "Debug (`)"
	list.add_child(title)

	for flag_name in DebugSettings.get_flag_names():
		_add_flag_checkbox(list, flag_name)

	list.add_child(HSeparator.new())
	var legend_title := Label.new()
	legend_title.text = "Legend"
	list.add_child(legend_title)
	_add_legend_row(list, DebugInspector.SELECTION_COLOR, "Selection / target line")
	_add_legend_row(list, DebugInspector.TARGET_HIGHLIGHT_COLOR, "Targeted enemy")
	_add_legend_row(list, DebugInspector.ATTACK_RANGE_COLOR, "Attack range")
	_add_legend_row(list, DebugInspector.DESIRED_VELOCITY_COLOR, "Desired velocity")
	_add_legend_row(list, DebugInspector.SAFE_VELOCITY_COLOR, "Actual velocity")

	_reposition()


## _panel is a Container with no parent Container of its own to drive its
## layout, so its size never leaves (0, 0) -- and a zero-size Control
## renders nothing, even while visible -- until something forces a size
## recalculation. Positioned from get_viewport_rect() directly rather
## than anchors: this Control's own rect (set_anchors_preset(FULL_RECT))
## never actually resolves to the viewport size either (same root issue,
## one level up -- confirmed via inspection, not just an assumption), so
## anchoring _panel relative to *this* node's size silently breaks too.
func _reposition() -> void:
	_panel.reset_size()
	var viewport_size := get_viewport_rect().size
	_panel.position = viewport_size - _panel.size - Vector2(_MARGIN, _MARGIN)


## _input (not _unhandled_input) so a focused Control can never swallow
## this before it's seen -- a global dev-tool toggle should never depend
## on UI focus state. Checks physical_keycode, keycode, AND unicode for
## the same physical key: WSLg's virtual keyboard layer can deliver a
## non-alphanumeric key like backtick inconsistently across those three,
## depending on host keyboard layout translation.
func _input(event: InputEvent) -> void:
	if not (event is InputEventKey and event.pressed and not event.echo):
		return
	var is_backtick: bool = (
		event.physical_keycode == KEY_QUOTELEFT
		or event.keycode == KEY_QUOTELEFT
		or event.unicode == 96 # backtick
	)
	if is_backtick:
		_panel.visible = not _panel.visible


func _add_flag_checkbox(parent: Control, flag_name: String) -> void:
	var checkbox := CheckBox.new()
	checkbox.text = flag_name.capitalize()
	checkbox.button_pressed = DebugSettings.is_enabled(flag_name)
	checkbox.toggled.connect(func(pressed): DebugSettings.set_enabled(flag_name, pressed))
	parent.add_child(checkbox)


func _add_legend_row(parent: Control, color: Color, label_text: String) -> void:
	var row := HBoxContainer.new()
	parent.add_child(row)

	var swatch := ColorRect.new()
	swatch.color = color
	swatch.custom_minimum_size = Vector2(14, 14)
	row.add_child(swatch)

	var label := Label.new()
	label.text = " " + label_text
	row.add_child(label)
