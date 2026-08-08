## Placement and battle controls: pick a unit type, pick a team, click
## the arena to place, then start the fight.
##
## The UI tree is built in code rather than laid out in the .tscn file.
## For a handful of buttons this is just as readable as a scene and
## keeps the whole control surface in one place.
##
## HUD never drives GameManager's battle lifecycle directly -- placement,
## team selection, and Start Battle all flow out as signals for Main.gd
## to act on, so it stays reusable if a future game mode needs different
## wiring. It does read GameManager's plain identity constants/lookups
## (BLUE_TEAM_ID/RED_TEAM_ID, get_team_display_name()) -- those aren't
## mutable battle state, just where team_id's single source of truth lives.
extends Control

signal unit_type_selected(stats: UnitStats)
signal team_selected(team_id: int)
signal start_battle_pressed
signal tournament_mode_toggled(enabled: bool)

const TANK_STATS: UnitStats = preload("res://Resources/TankStats.tres")
const FIGHTER_STATS: UnitStats = preload("res://Resources/FighterStats.tres")
const ARCHER_STATS: UnitStats = preload("res://Resources/ArcherStats.tres")
const BAT_RIDER_STATS: UnitStats = preload("res://Resources/BatRiderStats.tres")
const GIANT_STATS: UnitStats = preload("res://Resources/GiantStats.tres")

var _start_button: Button
var _winner_label: Label
var _drag_box: ColorRect
var _tournament_toggle: Button
var _tournament_score_label: Label


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE

	# One outer VBoxContainer stacks the unit panel above the team panel,
	# so the team panel's position is never a hand-computed pixel offset
	# that silently goes stale (and overlaps the row above) every time a
	# unit-type button is added -- it just follows whatever height the
	# panel above it ends up with.
	var root := VBoxContainer.new()
	root.position = Vector2(16, 16)
	add_child(root)

	_build_unit_panel(root)
	_add_spacer(root, 12)
	_build_team_panel(root)
	_build_winner_label()
	_build_drag_box()

	# Sensible defaults so a click places a unit immediately.
	unit_type_selected.emit(TANK_STATS)
	team_selected.emit(GameManager.BLUE_TEAM_ID)


func _build_unit_panel(parent: Control) -> void:
	var panel := VBoxContainer.new()
	parent.add_child(panel)

	var group := ButtonGroup.new()
	_add_toggle_button(panel, "Tank", group, true, func(): unit_type_selected.emit(TANK_STATS))
	_add_toggle_button(panel, "Fighter", group, false, func(): unit_type_selected.emit(FIGHTER_STATS))
	_add_toggle_button(panel, "Archer", group, false, func(): unit_type_selected.emit(ARCHER_STATS))
	_add_toggle_button(panel, "Bat Rider", group, false, func(): unit_type_selected.emit(BAT_RIDER_STATS))
	_add_toggle_button(panel, "Giant", group, false, func(): unit_type_selected.emit(GIANT_STATS))


func _build_team_panel(parent: Control) -> void:
	var panel := VBoxContainer.new()
	parent.add_child(panel)

	var group := ButtonGroup.new()
	_add_toggle_button(panel, "Blue Team", group, true, func(): team_selected.emit(GameManager.BLUE_TEAM_ID))
	_add_toggle_button(panel, "Red Team", group, false, func(): team_selected.emit(GameManager.RED_TEAM_ID))

	_add_spacer(panel, 12)
	_build_tournament_toggle(panel)
	_add_spacer(panel, 12)
	_build_start_button(panel)


func _add_spacer(parent: Control, height: float) -> void:
	var spacer := Control.new()
	spacer.custom_minimum_size = Vector2(0, height)
	parent.add_child(spacer)


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


## Off by default -- toggling swaps GameManager.current_mode between
## ClassicEliminationMode (single battle, current default) and
## BloodTournamentMode (best-of-N rounds, arena auto-resets between them)
## via Main.gd. Not grouped with the Blue/Red buttons above -- it's an
## independent on/off, not a third mutually-exclusive choice.
func _build_tournament_toggle(parent: Control) -> void:
	_tournament_toggle = Button.new()
	_tournament_toggle.text = "Blood Tournament: Off"
	_tournament_toggle.custom_minimum_size = Vector2(140, 36)
	_tournament_toggle.toggle_mode = true
	_tournament_toggle.toggled.connect(_on_tournament_toggled)
	parent.add_child(_tournament_toggle)


func _on_tournament_toggled(enabled: bool) -> void:
	_tournament_toggle.text = "Blood Tournament: On" if enabled else "Blood Tournament: Off"
	if not enabled:
		hide_tournament_score()
	tournament_mode_toggled.emit(enabled)


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

	# Added directly to self (like _drag_box), not nested inside the
	## CenterContainer above -- a Container overrides/ignores a child's own
	## `position`, which is exactly the manual top-center placement this
	## needs and the winner banner doesn't.
	_tournament_score_label = Label.new()
	_tournament_score_label.visible = false
	_tournament_score_label.add_theme_font_size_override("font_size", 22)
	_tournament_score_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	add_child(_tournament_score_label)


## A plain translucent fill, not a bordered rectangle (StyleBoxFlat's
## border draws inside the box's own size, requiring the container's own
## fudged sizing to look right at 1px drag widths) -- box-select is a
## momentary drag gesture, not something that needs to look polished.
func _build_drag_box() -> void:
	_drag_box = ColorRect.new()
	_drag_box.color = Color(0.6, 0.9, 1.0, 0.15)
	_drag_box.visible = false
	_drag_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_drag_box)


## Called by Main.gd every frame a left-drag is in progress. `rect` is in
## this Control's own coordinate space (screen space, since HUD fills the
## viewport) -- Main.gd builds it directly from mouse event positions.
func show_drag_box(rect: Rect2) -> void:
	_drag_box.position = rect.position
	_drag_box.size = rect.size
	_drag_box.visible = true


func hide_drag_box() -> void:
	_drag_box.visible = false


func _on_start_pressed() -> void:
	start_battle_pressed.emit()
	_start_button.disabled = true


## Called by Main.gd when GameManager reports the battle is over.
## winning_team_id is ignored when is_draw is true -- see GameManager.battle_ended.
func show_winner(winning_team_id: int, is_draw: bool) -> void:
	_winner_label.text = "DRAW" if is_draw else "%s TEAM WINS!" % GameManager.get_team_display_name(winning_team_id).to_upper()
	_winner_label.visible = true


## Called by Main.gd on every BloodTournamentMode.round_ended. Positioned
## from get_viewport_rect().size directly rather than anchors -- a bare
## Label parented straight to this full-rect Control (not inside a
## layout Container) never resolves a real position from anchors alone,
## same gotcha _build_drag_box()'s sibling _drag_box would hit if it
## needed to be centered instead of just stretched to a drag rect.
func show_tournament_score(round_number: int, blue_wins: int, red_wins: int) -> void:
	_tournament_score_label.text = "Round %d — Blue %d : %d Red" % [round_number, blue_wins, red_wins]
	_tournament_score_label.reset_size()
	var viewport_width := get_viewport_rect().size.x
	_tournament_score_label.position = Vector2((viewport_width - _tournament_score_label.size.x) * 0.5, 24)
	_tournament_score_label.visible = true


func hide_tournament_score() -> void:
	_tournament_score_label.visible = false


## Called by Main.gd right before starting the next round of a Blood
## Tournament -- reset_battle() alone puts GameManager back in
## PLACEMENT, but nothing else re-enables the Start Battle button
## (_on_start_pressed() disables it and, before rounds existed, nothing
## ever needed to undo that) or clears the previous round's banner.
func reset_for_new_round() -> void:
	_winner_label.visible = false
	_start_button.disabled = false
