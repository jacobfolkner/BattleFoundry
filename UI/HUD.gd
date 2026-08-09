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
signal ai_opponent_toggled(enabled: bool)
## Emitted when a hotbar slot button is clicked (see _build_ability_hotbar()) --
## Main.gd routes this through the exact same _try_cast_or_target() the
## Q/W/E hotkeys use, so clicking and pressing the key are equivalent.
signal ability_slot_pressed(index: int)
## Emitted when a roster line-up slot is clicked (see _build_roster_row())
## -- Main.gd routes this to GameManager.sell_roster_slot(), the
## staging-area equivalent of the old click-a-live-unit-to-sell flow.
signal roster_slot_sold(index: int)
## Emitted when the player toggles a candidate in the hero ability draft
## panel (see _build_hero_draft_panel()) -- Main.gd routes this to
## GameManager.pick_hero_ability(). `stats` is the hero archetype (e.g.
## HeroStats.tres) the drafted slot belongs to.
signal hero_ability_picked(stats: UnitStats, slot_index: int, chosen_index: int)

const TANK_STATS: UnitStats = preload("res://Resources/Units/TankStats.tres")
const FIGHTER_STATS: UnitStats = preload("res://Resources/Units/FighterStats.tres")
const ARCHER_STATS: UnitStats = preload("res://Resources/Units/ArcherStats.tres")
const BAT_RIDER_STATS: UnitStats = preload("res://Resources/Units/BatRiderStats.tres")
const GIANT_STATS: UnitStats = preload("res://Resources/Units/GiantStats.tres")
const HERO_STATS: UnitStats = preload("res://Resources/Units/HeroStats.tres")

var _start_button: Button
var _winner_label: Label
var _drag_box: ColorRect
var _tournament_toggle: Button
var _tournament_score_label: Label
var _gold_label: Label
var _ai_toggle: Button
var _blue_team_button: Button
var _red_team_button: Button
## Parallel to each other, built once in _build_unit_panel() -- lets
## refresh_affordability() grey out whichever unit-type buttons the
## currently active placement side can't afford, without a separate
## lookup structure.
var _unit_type_buttons: Array[Button] = []
var _unit_type_stats: Array[UnitStats] = []

var _roster_row: HBoxContainer
## Grow-only pool, same pattern as the ability hotbar/buff row -- see
## refresh_roster_row().
var _roster_slot_buttons: Array[Button] = []

var _hero_draft_panel: VBoxContainer
## The PanelContainer _hero_draft_panel lives inside -- toggled by
## refresh_hero_draft_panel() itself, since a VBoxContainer with no
## children takes no layout space but still leaves its OWN card
## background/header visible as an empty box. See _wrap_in_card().
var _hero_draft_card: PanelContainer

var _ability_hotbar: HBoxContainer
var _ability_slot_buttons: Array[Button] = []
var _buff_row: HBoxContainer
var _targeting_label: Label
var _hero_level_label: Label
var _minimap: MiniMap
## Whichever unit SelectionManager last reported as selected (see
## track_unit()) -- the hotbar/buff row always reflect this one unit, not
## the whole selection, same simplification a WC3-style command card makes
## for a mixed selection.
var _tracked_unit: Unit = null


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE

	# One outer VBoxContainer stacks the cards below, so each card's
	# position is never a hand-computed pixel offset that silently goes
	# stale (and overlaps the row above) every time a button is added --
	# it just follows whatever height the card above it ends up with.
	var root := VBoxContainer.new()
	root.position = Vector2(24, 24)
	root.add_theme_constant_override("separation", 16)
	add_child(root)

	var shop_card := _wrap_in_card(root, "Shop")
	_build_unit_panel(shop_card)
	_add_spacer(shop_card, 8)
	_build_roster_row(shop_card)

	var hero_draft_content := _wrap_in_card(root, "Hero Ability Draft")
	_hero_draft_card = hero_draft_content.get_parent() as PanelContainer
	_build_hero_draft_panel(hero_draft_content)

	var match_card := _wrap_in_card(root, "Match")
	_build_team_panel(match_card)

	_build_winner_label()
	_build_drag_box()
	_build_ability_hotbar()
	_build_buff_row()
	_build_targeting_prompt()
	_build_hero_level_label()
	_build_minimap()

	# Sensible defaults so a click places a unit immediately.
	unit_type_selected.emit(TANK_STATS)
	team_selected.emit(GameManager.BLUE_TEAM_ID)


## Every frame, not just on selection_changed -- cooldowns and Effect
## durations tick continuously, so the hotbar/buff row need to visibly
## count down even while the selection itself hasn't changed.
func _process(_delta: float) -> void:
	_refresh_ability_hotbar()
	_refresh_buff_row()
	_refresh_hero_level_label()


## Wraps a titled group of controls in a background PanelContainer, so
## the placement screen reads as distinct sections instead of one flat
## column of buttons with nothing but spacers between unrelated
## controls -- the "cluttered" feedback this whole card system exists to
## fix. Returns the inner VBoxContainer callers actually add their own
## content to; `parent` is returned separately as the card's own
## PanelContainer node only where a caller needs to toggle the whole
## card's visibility (see _hero_draft_card).
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


func _build_unit_panel(parent: Control) -> void:
	var panel := GridContainer.new()
	panel.columns = 2
	panel.add_theme_constant_override("h_separation", 8)
	panel.add_theme_constant_override("v_separation", 8)
	parent.add_child(panel)

	var group := ButtonGroup.new()
	_add_unit_type_button(panel, group, TANK_STATS, true)
	_add_unit_type_button(panel, group, FIGHTER_STATS, false)
	_add_unit_type_button(panel, group, ARCHER_STATS, false)
	_add_unit_type_button(panel, group, BAT_RIDER_STATS, false)
	_add_unit_type_button(panel, group, GIANT_STATS, false)
	_add_unit_type_button(panel, group, HERO_STATS, false)


## Label includes cost (e.g. "Tank (150g)") so a player can see what they
## can afford at a glance -- only meaningful while economy is active, but
## shown unconditionally since it's just informational text; affordability
## itself is enforced by refresh_affordability() disabling the button.
func _add_unit_type_button(parent: Control, group: ButtonGroup, stats: UnitStats, is_pressed: bool) -> void:
	var button := _add_toggle_button(parent, "%s (%dg)" % [stats.unit_name, stats.cost], group, is_pressed, func(): unit_type_selected.emit(stats))
	_unit_type_buttons.append(button)
	_unit_type_stats.append(stats)


func _build_team_panel(parent: Control) -> void:
	var panel := VBoxContainer.new()
	parent.add_child(panel)

	var group := ButtonGroup.new()
	_blue_team_button = _add_toggle_button(panel, "Blue Team", group, true, func(): team_selected.emit(GameManager.BLUE_TEAM_ID))
	_red_team_button = _add_toggle_button(panel, "Red Team", group, false, func(): team_selected.emit(GameManager.RED_TEAM_ID))

	_add_spacer(panel, 12)
	_build_tournament_toggle(panel)
	_build_ai_toggle(panel)
	_add_spacer(panel, 12)
	_build_start_button(panel)


func _add_spacer(parent: Control, height: float) -> void:
	var spacer := Control.new()
	spacer.custom_minimum_size = Vector2(0, height)
	parent.add_child(spacer)


func _add_toggle_button(parent: Control, label: String, group: ButtonGroup, is_pressed: bool, on_pressed: Callable) -> Button:
	var button := Button.new()
	button.text = label
	button.custom_minimum_size = Vector2(140, 36)
	button.toggle_mode = true
	button.button_group = group
	button.button_pressed = is_pressed
	button.pressed.connect(on_pressed)
	parent.add_child(button)
	return button


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


## Off by default -- Main.gd flips Red's Player.is_human accordingly and
## has AIController take Red's placement turns instead of a human clicking
## around (see Main._run_ai_turn_if_needed()). Locks the Red Team button
## while on: there's no sense letting a human also try to place/command
## the side the AI is now playing, and force-selects Blue if Red happened
## to be selected already.
func _build_ai_toggle(parent: Control) -> void:
	_ai_toggle = Button.new()
	_ai_toggle.text = "AI Opponent: Off"
	_ai_toggle.custom_minimum_size = Vector2(140, 36)
	_ai_toggle.toggle_mode = true
	_ai_toggle.toggled.connect(_on_ai_toggled)
	parent.add_child(_ai_toggle)


## Called by Main.gd to apply UI/MainMenu.gd's pre-match selection --
## set_pressed_no_signal() (not a plain button_pressed assignment) so this
## has one deterministic effect: update the button's own visual state,
## then invoke the exact same handler a real click would, exactly once.
## A plain `button_pressed = enabled` would rely on Godot's own toggled-on-
## script-set behavior, which this deliberately doesn't need to trust.
func set_tournament_toggle(enabled: bool) -> void:
	_tournament_toggle.set_pressed_no_signal(enabled)
	_on_tournament_toggled(enabled)


## Pure visual sync -- unlike set_tournament_toggle() above, does NOT
## re-run _on_tournament_toggled()/emit tournament_mode_toggled. For a
## caller (Main._apply_menu_selection()) that already drove the actual
## mode change itself with data this button's own toggled signal has no
## way to carry (active_team_ids -- see Main._on_tournament_toggled()'s
## own doc comment) and just needs the button's look to match afterward,
## without triggering a second, redundant activation.
func sync_tournament_toggle_visual(enabled: bool) -> void:
	_tournament_toggle.set_pressed_no_signal(enabled)
	_tournament_toggle.text = "Blood Tournament: On" if enabled else "Blood Tournament: Off"


func set_ai_toggle(enabled: bool) -> void:
	_ai_toggle.set_pressed_no_signal(enabled)
	_on_ai_toggled(enabled)


func _on_ai_toggled(enabled: bool) -> void:
	_ai_toggle.text = "AI Opponent: On" if enabled else "AI Opponent: Off"
	_red_team_button.disabled = enabled
	if enabled and not _blue_team_button.button_pressed:
		_blue_team_button.button_pressed = true
		team_selected.emit(GameManager.BLUE_TEAM_ID)
	ai_opponent_toggled.emit(enabled)


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

	# Positioned just below the score label (see show_gold()) rather than
	# stacked in a Container with it -- same bare-Label-on-a-parentless-
	# Control gotcha as _tournament_score_label itself, so it gets the
	# same manual get_viewport_rect().size positioning.
	_gold_label = Label.new()
	_gold_label.visible = false
	_gold_label.add_theme_font_size_override("font_size", 18)
	_gold_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	add_child(_gold_label)


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


## Called by Main.gd on every BloodTournamentMode.round_ended --
## score_text is a fully pre-formatted "TeamName wins : TeamName wins : ..."
## string (Main._scoreboard_text() builds it, sorted, for however many of
## the up to 8 teams are actually playing) so this stays a generic
## "display whatever text you're given" renderer, same boundary this
## class's own doc comment already describes for GameManager lookups --
## HUD doesn't know how many teams exist or how ranking works. Positioned
## from get_viewport_rect().size directly rather than anchors -- a bare
## Label parented straight to this full-rect Control (not inside a
## layout Container) never resolves a real position from anchors alone,
## same gotcha _build_drag_box()'s sibling _drag_box would hit if it
## needed to be centered instead of just stretched to a drag rect.
func show_tournament_score(round_number: int, score_text: String) -> void:
	_tournament_score_label.text = "Round %d — %s" % [round_number, score_text]
	_tournament_score_label.reset_size()
	var viewport_width := get_viewport_rect().size.x
	_tournament_score_label.position = Vector2((viewport_width - _tournament_score_label.size.x) * 0.5, 24)
	_tournament_score_label.visible = true


func hide_tournament_score() -> void:
	_tournament_score_label.visible = false


## Called by Main.gd whenever Blood Tournament gold/blood points change
## (toggled on, a round ending, a kill, or a placement/sell/upgrade spend)
## -- only meaningful while economy is active, see GameMode.uses_economy().
## One label for both currencies rather than two separately-positioned
## ones -- they always change together often enough (round income touches
## gold, a kill touches blood points, but a player wants to see both at a
## glance either way) that a second label would just be more UI to keep
## in sync for no real benefit.
func show_gold(blue_gold: int, red_gold: int, blue_blood_points: int, red_blood_points: int) -> void:
	_gold_label.text = "Gold — Blue %d : %d Red   |   Blood Points — Blue %d : %d Red" % [blue_gold, red_gold, blue_blood_points, red_blood_points]
	_gold_label.reset_size()
	var viewport_width := get_viewport_rect().size.x
	_gold_label.position = Vector2((viewport_width - _gold_label.size.x) * 0.5, 52)
	_gold_label.visible = true


func hide_gold() -> void:
	_gold_label.visible = false


## Called by Main.gd alongside every gold change/team switch -- greys out
## whichever unit-type buttons `player` can't currently afford. A no-op
## grey-out (never disables anything) while current_mode.uses_economy()
## is false, matching every other gold-gated behavior in this codebase.
func refresh_affordability(player: Player) -> void:
	var use_gold := GameManager.current_mode.uses_economy()
	for i in _unit_type_buttons.size():
		_unit_type_buttons[i].disabled = use_gold and not player.can_afford(_unit_type_stats[i].cost)


## The "rectangle" -- a literal separate staging area's line-up display,
## not the arena itself. Shows the currently active placement side's
## roster in purchase order (see Player.roster); clicking a slot sells
## it (roster_slot_sold, routed by Main.gd to
## GameManager.sell_roster_slot()). Hidden entirely outside Blood
## Tournament via refresh_roster_row([]) -- Main.gd is what decides that,
## same as show_gold()/hide_gold().
func _build_roster_row(parent: Control) -> void:
	_roster_row = HBoxContainer.new()
	_roster_row.add_theme_constant_override("separation", 4)
	parent.add_child(_roster_row)


## Grow-only Button pool (same reasoning as the buff row's Label pool --
## see _refresh_buff_row()'s doc comment): rebuilding every call would
## double-count still-present-until-idle-cleanup nodes if this container's
## size were measured again the same frame.
func refresh_roster_row(roster: Array[UnitStats]) -> void:
	while _roster_slot_buttons.size() < roster.size():
		var index := _roster_slot_buttons.size()
		var button := Button.new()
		button.custom_minimum_size = Vector2(72, 32)
		button.pressed.connect(func(): roster_slot_sold.emit(index))
		_roster_row.add_child(button)
		_roster_slot_buttons.append(button)

	for i in _roster_slot_buttons.size():
		var button := _roster_slot_buttons[i]
		if i < roster.size():
			button.text = roster[i].unit_name
			button.visible = true
		else:
			button.visible = false


func _build_hero_draft_panel(parent: Control) -> void:
	_hero_draft_panel = VBoxContainer.new()
	parent.add_child(_hero_draft_panel)


## Rebuilt from scratch every call (free every child, then re-add) rather
## than a grow-only pool -- unlike the ability hotbar/buff row, this is
## only ever called from a discrete PLACEMENT-state-change event (see
## Main._refresh_gold_display()), never every frame, so there's no
## same-frame double-measurement risk from a freed-but-not-yet-cleaned-up
## child (the reason the buff row/ability hotbar use a pool instead). The
## shape here (variable rows, variable candidates per row) also doesn't
## fit a simple index-aligned pool the way a flat button row does.
##
## One row per undrafted-or-already-drafted-but-still-visible slot across
## every hero UnitStats in player.roster -- a slot with fewer than 2
## candidates has nothing to choose between, so it's skipped entirely
## (identical to today's plain fixed-unlock behavior). Whole panel stays
## empty (and so effectively invisible -- a VBoxContainer with no
## children takes no space) when the player owns no hero with any
## drafted slot at all, same self-hiding convention show_gold()/
## hide_tournament_score() already use.
func refresh_hero_draft_panel(player: Player) -> void:
	for child in _hero_draft_panel.get_children():
		child.queue_free()

	# Tracked locally, not read back via _hero_draft_panel.get_child_count()
	# after the queue_free() loop above -- a queue_free()'d child is still
	# present in the tree (and so still counted) until end-of-frame idle
	# cleanup, the same trap _refresh_buff_row()'s own doc comment already
	# documents for this exact reason.
	var built_any_row := false
	for stats in player.roster:
		if not stats.is_hero:
			continue
		var picks: Dictionary = player.hero_ability_picks.get(stats, {})
		for slot_index in stats.ability_draft_choices.size():
			var choice_set: AbilityChoiceSet = stats.ability_draft_choices[slot_index]
			if choice_set == null or choice_set.candidates.size() < 2:
				continue
			_build_ability_draft_row(stats, slot_index, choice_set, picks.get(slot_index, 0))
			built_any_row = true

	# _hero_draft_panel itself (a VBoxContainer) already takes no layout
	# space with no children, but the CARD's own background/header would
	# still show as an empty box without this -- toggle the whole card,
	# not just the row container.
	_hero_draft_card.visible = built_any_row


func _build_ability_draft_row(stats: UnitStats, slot_index: int, choice_set: AbilityChoiceSet, chosen_index: int) -> void:
	var row := HBoxContainer.new()
	_hero_draft_panel.add_child(row)

	var unlock_level := stats.ability_unlock_levels[slot_index] if slot_index < stats.ability_unlock_levels.size() else 1
	var label := Label.new()
	label.text = "Lv.%d:" % unlock_level
	row.add_child(label)

	var group := ButtonGroup.new()
	for candidate_index in choice_set.candidates.size():
		var candidate := choice_set.candidates[candidate_index]
		_add_toggle_button(row, candidate.ability_name, group, candidate_index == chosen_index,
			func(): hero_ability_picked.emit(stats, slot_index, candidate_index))


## Bottom-center, one button per ability slot (Q/W/E). Fixed at 3 buttons
## always present (never added/removed) -- _refresh_ability_hotbar() just
## updates each one's text/disabled state in place every frame, so there's
## no node-churn/pooling concern the way the variable-length buff row has.
func _build_ability_hotbar() -> void:
	_ability_hotbar = HBoxContainer.new()
	_ability_hotbar.add_theme_constant_override("separation", 6)
	add_child(_ability_hotbar)

	for i in range(3):
		var button := Button.new()
		button.custom_minimum_size = Vector2(96, 56)
		button.text = "-"
		button.disabled = true
		button.pressed.connect(func(): ability_slot_pressed.emit(i))
		_ability_hotbar.add_child(button)
		_ability_slot_buttons.append(button)

	_ability_hotbar.reset_size()
	var viewport_size := get_viewport_rect().size
	_ability_hotbar.position = Vector2((viewport_size.x - _ability_hotbar.size.x) * 0.5, viewport_size.y - 80)


## Told which unit to reflect by Main.gd, forwarding SelectionManager's
## own selection_changed signal -- HUD stays decoupled from selection
## bookkeeping itself (see this file's own class doc comment), it only
## ever reads whichever Unit it's handed via its public getters.
func track_unit(unit: Unit) -> void:
	_tracked_unit = unit


## "-" / disabled means: no ability in this slot for the tracked unit, on
## cooldown, or not a player-triggerable cast type (PASSIVE/ON_HIT/AURA --
## Unit.cast_ability() enforces the same gate; this just reflects it
## visually rather than letting a click silently no-op with no feedback).
func _refresh_ability_hotbar() -> void:
	var unit := _tracked_unit
	var alive := unit != null and is_instance_valid(unit) and unit.life_state == Unit.LifeState.ALIVE

	for i in _ability_slot_buttons.size():
		var button := _ability_slot_buttons[i]
		if not alive or i >= unit.resolved_abilities.size() or unit.resolved_abilities[i] == null:
			button.text = "-"
			button.disabled = true
			continue

		var ability: Ability = unit.resolved_abilities[i]
		var locked := unit.stats.is_hero and i < unit.stats.ability_unlock_levels.size() and unit.level < unit.stats.ability_unlock_levels[i]
		if locked:
			button.text = "%s\n(Lv.%d)" % [ability.ability_name, unit.stats.ability_unlock_levels[i]]
			button.disabled = true
			continue

		var not_player_triggerable := ability.cast_type == Ability.CastType.PASSIVE \
			or ability.cast_type == Ability.CastType.ON_HIT \
			or ability.cast_type == Ability.CastType.AURA
		var cooldown := unit.get_ability_cooldown_remaining(i)
		if not_player_triggerable:
			button.text = ability.ability_name
			button.disabled = true
		elif cooldown > 0.0:
			button.text = "%s\n%.1fs" % [ability.ability_name, cooldown]
			button.disabled = true
		else:
			button.text = ability.ability_name
			button.disabled = false


func _build_buff_row() -> void:
	_buff_row = HBoxContainer.new()
	_buff_row.add_theme_constant_override("separation", 4)
	add_child(_buff_row)


## Grow-only Label pool (same pattern DebugInspector/SelectionManager use
## for their 3D indicators, just for 2D Labels here) rather than
## queue_free()-ing and rebuilding every frame -- a queue_free()'d child is
## still present in the tree until end-of-frame idle cleanup, so measuring
## this container's size again in the same frame (reset_size(), right
## below) would double-count it. Hidden pool entries cost nothing: a
## Container doesn't allocate layout space for an invisible child.
func _refresh_buff_row() -> void:
	var unit := _tracked_unit
	var alive := unit != null and is_instance_valid(unit) and unit.life_state == Unit.LifeState.ALIVE
	var effects: Array[Effect] = []
	if alive:
		effects = unit.get_active_effects()

	while _buff_row.get_child_count() < effects.size():
		var label := Label.new()
		label.add_theme_font_size_override("font_size", 14)
		_buff_row.add_child(label)

	for i in _buff_row.get_child_count():
		var label: Label = _buff_row.get_child(i)
		if i < effects.size():
			var effect := effects[i]
			var remaining := "%.1fs" % (effect.duration - effect.elapsed) if effect.duration > 0.0 else "perm"
			label.text = "%s (%s)" % [effect.id, remaining]
			label.visible = true
		else:
			label.visible = false

	_buff_row.reset_size()
	var viewport_size := get_viewport_rect().size
	_buff_row.position = Vector2((viewport_size.x - _buff_row.size.x) * 0.5, viewport_size.y - 106)


func _build_targeting_prompt() -> void:
	_targeting_label = Label.new()
	_targeting_label.visible = false
	_targeting_label.add_theme_font_size_override("font_size", 20)
	_targeting_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	add_child(_targeting_label)


## Called by Main.gd while a UNIT_TARGET ability is awaiting a click (see
## Main._pending_ability_target).
func show_targeting_prompt(ability_name: String) -> void:
	_targeting_label.text = "Select a target for %s (right-click or Esc to cancel)" % ability_name
	_targeting_label.reset_size()
	var viewport_width := get_viewport_rect().size.x
	_targeting_label.position = Vector2((viewport_width - _targeting_label.size.x) * 0.5, 80)
	_targeting_label.visible = true


func hide_targeting_prompt() -> void:
	_targeting_label.visible = false


func _build_hero_level_label() -> void:
	_hero_level_label = Label.new()
	_hero_level_label.visible = false
	_hero_level_label.add_theme_font_size_override("font_size", 16)
	_hero_level_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	add_child(_hero_level_label)


## Hidden entirely for a non-hero tracked unit (or none selected) --
## Unit.level/xp are unused fields for anything else, see UnitStats.is_hero.
func _refresh_hero_level_label() -> void:
	var unit := _tracked_unit
	var alive := unit != null and is_instance_valid(unit) and unit.life_state == Unit.LifeState.ALIVE
	if not alive or not unit.stats.is_hero:
		_hero_level_label.visible = false
		return

	_hero_level_label.text = "Level %d (%d / %d XP)" % [unit.level, int(unit.xp), int(unit.get_xp_to_next_level())]
	_hero_level_label.reset_size()
	var viewport_size := get_viewport_rect().size
	_hero_level_label.position = Vector2((viewport_size.x - _hero_level_label.size.x) * 0.5, viewport_size.y - 128)
	_hero_level_label.visible = true


func _build_minimap() -> void:
	_minimap = MiniMap.new()
	add_child(_minimap)


## Called by Main.gd right before starting the next round of a Blood
## Tournament -- reset_battle() alone puts GameManager back in
## PLACEMENT, but nothing else re-enables the Start Battle button
## (_on_start_pressed() disables it and, before rounds existed, nothing
## ever needed to undo that) or clears the previous round's banner.
func reset_for_new_round() -> void:
	_winner_label.visible = false
	_start_button.disabled = false
