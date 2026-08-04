## Displays a live snapshot of whatever unit Scripts/DebugInspector.gd
## has selected.
##
## Purely observational UI: it renders whatever key/value pairs
## Unit.get_debug_info() returns without knowing what any of them mean.
## Any future object exposing that same contract -- a get_debug_info()
## method returning Dictionary[String, String] -- is displayed here with
## zero changes to this file.
extends Control

const _MARGIN := 16.0
const _WIDTH := 260.0

var _panel: PanelContainer
var _info_label: Label


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE

	_panel = PanelContainer.new()
	add_child(_panel)
	_panel.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	_panel.position = Vector2(-_WIDTH - _MARGIN, _MARGIN)
	_panel.custom_minimum_size = Vector2(_WIDTH, 0)
	_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_panel.visible = false

	_info_label = Label.new()
	_panel.add_child(_info_label)

	DebugInspector.selection_changed.connect(_on_selection_changed)


func _process(_delta: float) -> void:
	if not DebugInspector.has_valid_selection():
		return
	_refresh(DebugInspector.selected_unit.get_debug_info())


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
