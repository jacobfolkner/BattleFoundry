## Displays a live snapshot of whatever unit Scripts/DebugInspector.gd
## has selected.
##
## Purely observational UI: it renders whatever key/value pairs
## get_debug_info() returns without knowing what any of them mean. Any
## future object exposing that same contract is displayed here with zero
## changes to this file. If the selected object also has an optional
## get_debug_info_detailed() -> Dictionary, those keys are appended too,
## but only while DebugSettings.FLAG_DETAILED_STATS is on -- basic info
## always shows, detail is opt-in.
extends Control

const _MARGIN := 16.0
const _WIDTH := 260.0

var _panel: PanelContainer
var _info_label: Label


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE

	_panel = PanelContainer.new()
	add_child(_panel)
	_panel.custom_minimum_size = Vector2(_WIDTH, 0)
	_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_panel.visible = false

	_info_label = Label.new()
	_panel.add_child(_info_label)

	_reposition()

	DebugInspector.selection_changed.connect(_on_selection_changed)


## _panel is a Container with no parent Container of its own to drive its
## layout, so its size never leaves (0, 0) -- and a zero-size Control
## renders nothing, even while visible -- until something forces a size
## recalculation. Positioned from get_viewport_rect() directly rather
## than anchors: this Control's own rect (set_anchors_preset(FULL_RECT))
## never actually resolves to the viewport size either (same root issue,
## one level up), so anchoring _panel relative to *this* node's size
## silently breaks too. Called again from _refresh() since the label's
## text (and thus the panel's ideal width/height) changes with the
## selected unit.
func _reposition() -> void:
	_panel.reset_size()
	var viewport_width := get_viewport_rect().size.x
	_panel.position = Vector2(viewport_width - _panel.size.x - _MARGIN, _MARGIN)


func _process(_delta: float) -> void:
	if not DebugInspector.has_valid_selection():
		return

	var selected := DebugInspector.selected_unit
	var info: Dictionary = selected.get_debug_info()
	if DebugSettings.is_enabled(DebugSettings.FLAG_DETAILED_STATS) and selected.has_method("get_debug_info_detailed"):
		info.merge(selected.get_debug_info_detailed())

	_refresh(info)


func _on_selection_changed(unit: Unit) -> void:
	_panel.visible = unit != null


## Generic renderer: one "Key: Value" line per dictionary entry, in
## whatever order the source method returned them. No field is special-
## cased, so this never needs to change when a new field (or a whole new
## inspectable object type) is added elsewhere.
func _refresh(info: Dictionary) -> void:
	var lines: Array[String] = ["Selected Unit", ""]
	for key in info:
		lines.append("%s: %s" % [key, info[key]])
	_info_label.text = "\n".join(lines)
	_reposition()
