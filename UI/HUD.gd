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
const BAT_RIDER_STATS: UnitStats = preload("res://Resources/BatRiderStats.tres")
const GIANT_STATS: UnitStats = preload("res://Resources/GiantStats.tres")

var _start_button: Button
var _winner_label: Label


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE

	_build_unit_panel()
	_build_team_panel()
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
	_add_toggle_button(panel, "Bat Rider", group, false, func(): unit_type_selected.emit(BAT_RIDER_STATS))
	_add_toggle_button(panel, "Giant", group, false, func(): unit_type_selected.emit(GIANT_STATS))


func _build_team_panel() -> void:
	var panel := VBoxContainer.new()
	panel.position = Vector2(16, 236) # below 5 unit-type buttons in the panel above
	add_child(panel)

	var group := ButtonGroup.new()
	_add_toggle_button(panel, "Blue Team", group, true, func(): team_selected.emit(Team.Type.BLUE))
	_add_toggle_button(panel, "Red Team", group, false, func(): team_selected.emit(Team.Type.RED))

	var spacer := Control.new()
	spacer.custom_minimum_size = Vector2(0, 12)
	panel.add_child(spacer)

	_build_start_button(panel)


func _add_toggle_button(parent: Control, label: String, group: ButtonGroup, is_pressed: bool, on_pressed: Callable) -> void:
	var button := Button.new()
	button.text = label
	button.custom_minimum_size = Vector2(140, 36)
	button.toggle_mode = true
	button.button_group = group
	button.button_pressed = is_pressed
	button.pressed.connect(on_pressed)
	parent.add_child(button)


## Placed inside the team panel (as its own VBoxContainer flow) rather than
## anchored independently -- anchoring a Control via position/size before it
## is inside the tree resolves against a zero-size parent rect in Godot 4.7,
## which left this button laid out with an empty/degenerate rect.
func _build_start_button(parent: Control) -> void:
	_start_button = Button.new()
	_start_button.text = "Start Battle"
	_start_button.custom_minimum_size = Vector2(140, 40)
	_start_button.pressed.connect(_on_start_pressed)
	parent.add_child(_start_button)


## Uses a CenterContainer (rather than manual anchors/position/size on the
## label itself) so the banner is centered by layout, not by pixel math --
## the same category of bug that previously made the Start Battle button
## invisible: setting position/size on a Control before it's in the tree
## resolves against a zero-size parent rect in Godot 4.7.
func _build_winner_label() -> void:
	var center := CenterContainer.new()
	add_child(center)
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE

	_winner_label = Label.new()
	_winner_label.visible = false
	_winner_label.add_theme_font_size_override("font_size", 48)
	_winner_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_winner_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	center.add_child(_winner_label)


func _on_start_pressed() -> void:
	start_battle_pressed.emit()
	_start_button.disabled = true


## Called by Main.gd when GameManager reports the battle is over.
func show_winner(winning_team: Team.Type) -> void:
	_winner_label.text = "%s TEAM WINS!" % Team.get_display_name(winning_team).to_upper()
	_winner_label.visible = true
