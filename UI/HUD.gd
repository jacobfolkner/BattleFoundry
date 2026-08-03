## Placement and battle controls: pick a unit type, pick a team, click
## the arena to place, then start the fight.
##
## The UI tree is built in code rather than laid out in the .tscn file.
## For a handful of buttons this is just as readable as a scene and
## keeps the whole control surface in one place.
##
## HUD only emits signals -- it never touches GameManager directly --
## so it stays reusable if a future game mode needs different wiring.
extends Control

signal unit_type_selected(stats: UnitStats)
signal team_selected(team: Team.Type)
signal start_battle_pressed

const TANK_STATS: UnitStats = preload("res://Resources/TankStats.tres")
const FIGHTER_STATS: UnitStats = preload("res://Resources/FighterStats.tres")
const ARCHER_STATS: UnitStats = preload("res://Resources/ArcherStats.tres")

var _start_button: Button
var _winner_label: Label


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE

	_build_unit_panel()
	_build_team_panel()
	_build_start_button()
	_build_winner_label()

	# Sensible defaults so a click places a unit immediately.
	unit_type_selected.emit(TANK_STATS)
	team_selected.emit(Team.Type.BLUE)


func _build_unit_panel() -> void:
	var panel := VBoxContainer.new()
	panel.position = Vector2(16, 16)
	add_child(panel)

	var group := ButtonGroup.new()
	_add_toggle_button(panel, "Tank", group, true, func(): unit_type_selected.emit(TANK_STATS))
	_add_toggle_button(panel, "Fighter", group, false, func(): unit_type_selected.emit(FIGHTER_STATS))
	_add_toggle_button(panel, "Archer", group, false, func(): unit_type_selected.emit(ARCHER_STATS))


func _build_team_panel() -> void:
	var panel := VBoxContainer.new()
	panel.position = Vector2(16, 148)
	add_child(panel)

	var group := ButtonGroup.new()
	_add_toggle_button(panel, "Blue Team", group, true, func(): team_selected.emit(Team.Type.BLUE))
	_add_toggle_button(panel, "Red Team", group, false, func(): team_selected.emit(Team.Type.RED))


func _add_toggle_button(parent: Control, label: String, group: ButtonGroup, is_pressed: bool, on_pressed: Callable) -> void:
	var button := Button.new()
	button.text = label
	button.custom_minimum_size = Vector2(140, 36)
	button.toggle_mode = true
	button.button_group = group
	button.button_pressed = is_pressed
	button.pressed.connect(on_pressed)
	parent.add_child(button)


func _build_start_button() -> void:
	_start_button = Button.new()
	_start_button.text = "Start Battle"
	_start_button.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	_start_button.position = Vector2(-75, -60)
	_start_button.size = Vector2(150, 44)
	_start_button.pressed.connect(_on_start_pressed)
	add_child(_start_button)


func _build_winner_label() -> void:
	_winner_label = Label.new()
	_winner_label.visible = false
	_winner_label.set_anchors_preset(Control.PRESET_CENTER)
	_winner_label.position = Vector2(-200, -40)
	_winner_label.size = Vector2(400, 80)
	_winner_label.add_theme_font_size_override("font_size", 48)
	_winner_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_winner_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	add_child(_winner_label)


func _on_start_pressed() -> void:
	start_battle_pressed.emit()
	_start_button.disabled = true


## Called by Main.gd when GameManager reports the battle is over.
func show_winner(winning_team: Team.Type) -> void:
	_winner_label.text = "%s TEAM WINS!" % Team.get_display_name(winning_team).to_upper()
	_winner_label.visible = true
