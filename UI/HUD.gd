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
signal ai_opponent_toggled(enabled: bool)
## Emitted when a hotbar slot button is clicked (see _build_ability_hotbar()) --
## Main.gd routes this through the exact same _try_cast_or_target() the
## Q/E/R hotkeys use, so clicking and pressing the key are equivalent.
signal ability_slot_pressed(index: int)
## Emitted when a roster line-up slot is clicked (see _build_roster_row())
## -- Main.gd routes this to selecting that squad's own first live unit
## (same target set_courtyard_visible(true)/begin_march() always keeps
## visible/valid), NOT selling it. Used to sell immediately on click
## (usability feedback, 2026-08-11: "the Shop area is dumb, I don't like
## being able to sell there by clicking the unit name") -- selling now
## only ever happens via the explicit Sell action in _unit_action_bar,
## once a unit is actually selected, never as a surprise side effect of
## a single click meant to just look at/select something.
signal roster_slot_clicked(index: int)
## Emitted when the player toggles a candidate in the hero ability draft
## panel (see _build_hero_draft_panel()) -- Main.gd routes this to
## GameManager.pick_hero_ability(). `stats` is the hero archetype (e.g.
## HeroStats.tres) the drafted slot belongs to.
signal hero_ability_picked(stats: UnitStats, slot_index: int, chosen_index: int)
## Emitted by the two currency-exchange buttons next to the gold label
## (see show_gold()) -- Main.gd routes these to
## Player.exchange_gold_for_blood_points()/exchange_blood_points_for_gold().
signal gold_exchange_requested
signal blood_exchange_requested
## Emitted by the unit action bar's Sell button (see
## _build_unit_action_bar()/_refresh_unit_action_bar()) -- no payload,
## Main.gd's own handler reads whichever unit SelectionManager currently
## reports as selected, same source HUD's own track_unit()/_tracked_unit
## already reflects.
signal sell_requested
## Emitted by one of the unit action bar's upgrade buttons -- Main.gd
## routes this to GameManager.buy_roster_upgrade(). Account-wide (per
## UnitUpgrade.gd's own doc comment), not actually specific to whichever
## unit is selected -- shown alongside Sell anyway so "select a unit,
## see what you can do" is one consistent place for both, rather than
## upgrades living in yet another separate always-on control.
signal upgrade_requested(upgrade: UnitUpgrade)
## Emitted by one of the archetype upgrade row's buttons (see
## _build_archetype_upgrade_row()) -- Main.gd routes this to
## GameManager.buy_archetype_upgrade(). Scoped to the SELECTED unit's own
## archetype (ArchetypeUpgrade.archetype), unlike upgrade_requested's
## account-wide UnitUpgrade -- gameplay feedback, 2026-08-12: "we dont
## currently have much use for blood points.. like for archers it may
## add 1 mortar unit and 2 additional archers... or add an aura."
signal archetype_upgrade_requested(upgrade: ArchetypeUpgrade)

const TANK_STATS: UnitStats = preload("res://Resources/Units/TankStats.tres")
const FIGHTER_STATS: UnitStats = preload("res://Resources/Units/FighterStats.tres")
const ARCHER_STATS: UnitStats = preload("res://Resources/Units/ArcherStats.tres")
const BAT_RIDER_STATS: UnitStats = preload("res://Resources/Units/BatRiderStats.tres")
const GIANT_STATS: UnitStats = preload("res://Resources/Units/GiantStats.tres")
const HERO_STATS: UnitStats = preload("res://Resources/Units/HeroStats.tres")
const PRIEST_STATS: UnitStats = preload("res://Resources/Units/PriestStats.tres")
const AXE_THROWER_STATS: UnitStats = preload("res://Resources/Units/AxeThrowerStats.tres")
const SPITTER_STATS: UnitStats = preload("res://Resources/Units/SpitterStats.tres")

## Own copies, not a reach into PlayerInputController's own private
## _UPGRADES -- HUD stays decoupled from input internals (see this file's
## own class doc comment), same reasoning as the UnitStats consts above.
## Index order matches PlayerInputController._UPGRADES/_UPGRADE_ACTIONS
## purely so the U/I/O/L hotkeys and these buttons feel like the same
## four actions, not because anything here reads that array directly.
const IRON_ARMOR_UPGRADE: UnitUpgrade = preload("res://Resources/Upgrades/IronArmorUpgrade.tres")
const WHETSTONE_UPGRADE: UnitUpgrade = preload("res://Resources/Upgrades/WhetstoneUpgrade.tres")
const HEROIC_VIGOR_UPGRADE: UnitUpgrade = preload("res://Resources/Upgrades/HeroicVigorUpgrade.tres")
const HEROIC_MIGHT_UPGRADE: UnitUpgrade = preload("res://Resources/Upgrades/HeroicMightUpgrade.tres")

var _start_button: Button
var _winner_label: Label
var _drag_box: ColorRect
## The leaderboard -- an always-on, collapsible panel pinned to the right
## edge of the screen (usability feedback, 2026-08-11: "I'd like to see
## it be 'always on' on the right side... maybe collapsable/expandable"),
## not the dim-backdrop modal it started as. _leaderboard_card is
## positioned manually from get_viewport_rect().size (same pattern every
## other overlay in this file already uses), not a CenterContainer/anchors
## -- two different CenterContainer attempts (one nested inside an extra
## full-rect wrapper, one as a direct full-rect-anchored child of `self`)
## both rendered the card pinned to the top-left corner instead of
## centered when this was still a modal. Matches CLAUDE.md's documented
## "a Control's anchors don't reliably resolve in this codebase's setup"
## gotcha closely enough that manual positioning, not more anchor
## nesting, is the fix.
var _leaderboard_card: PanelContainer
var _leaderboard_collapse_button: Button
var _leaderboard_grid: GridContainer
## Collapsed by default -- see refresh_leaderboard()/show_tournament_score().
var _leaderboard_expanded: bool = false
## Wraps _gold_label/_gold_exchange_button/_blood_exchange_button in a
## real card background -- independent design review, 2026-08-12: this
## strip used to be 3 bare Controls floating directly over the 3D world
## (outline-only text, no backing panel, unlike every other HUD group
## here), and a dark/dimmed trade button (see _UNAFFORDABLE_MODULATE)
## could visually disappear against a similarly dark unit or courtyard
## tile rendered right behind it. See show_gold()/hide_gold().
var _gold_panel: PanelContainer
var _gold_label: Label
var _gold_exchange_button: Button
var _blood_exchange_button: Button
var _ai_toggle: Button
var _blue_team_button: Button
var _red_team_button: Button
## Parallel to each other, built once in _build_unit_panel() -- lets
## refresh_affordability() grey out whichever unit-type buttons the
## currently active placement side can't afford, without a separate
## lookup structure.
var _unit_type_buttons: Array[Button] = []
var _unit_type_stats: Array[UnitStats] = []
## Faction -> {header: Label, grid: GridContainer}, built once in
## _build_unit_panel() -- see refresh_unit_panel_for_faction().
var _faction_group_nodes: Dictionary = {}

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

## The build-menu popup (WC3-style "click the Builder, a build menu
## appears") -- hidden by default, shown by show_build_menu()/hidden by
## hide_build_menu() (see PlayerInputController.on_left_release()'s
## is_builder branch). Unlike _hero_draft_card, its contents
## (_build_unit_panel()'s 6 archetype buttons) are static -- built once
## in _ready(), never rebuilt -- so only .visible needs toggling, not a
## rebuild-children-from-scratch pass.
var _build_menu_card: PanelContainer

## Bottom-left WC3-style unit info panel (portrait/name/health/armor/
## status) -- gameplay feedback, 2026-08-11: "when selecting a unit you
## should be able to see a ui on the bottom... notice the health and
## stats." Distinct from the in-world floating health bar
## (Unit._health_bar) -- that one's a quick glance during a fight; this
## is the "look up the exact numbers for whatever I selected" panel WC3
## itself has, bottom-LEFT specifically so it never collides with the
## bottom-CENTER ability hotbar/unit action bar/buff row stack. Shows for
## ANY tracked unit regardless of ownership (matches WC3 -- inspecting an
## enemy's health/armor is normal, not a Sell-style owned-only action).
var _unit_info_card: PanelContainer
var _unit_info_portrait: TextureRect
var _unit_info_name_label: Label
var _unit_info_health_bar: ProgressBar
var _unit_info_health_label: Label
var _unit_info_armor_label: Label
var _unit_info_status_label: Label

var _ability_hotbar: HBoxContainer
var _ability_slot_buttons: Array[Button] = []
var _unit_action_bar: HBoxContainer
var _sell_button: Button
var _upgrade_buttons: Array[Button] = []
## Every ArchetypeUpgrade in the game -- small and fixed, same "one pool,
## filter/toggle per frame" shape the ability hotbar's 3 fixed slots
## already use, not a per-selection rebuild (see _build_archetype_upgrade_row()).
const ARCHETYPE_UPGRADE_POOL: Array[ArchetypeUpgrade] = [
	preload("res://Resources/Upgrades/ArcherMortarSupportUpgrade.tres"),
	preload("res://Resources/Upgrades/FighterBattleStandardUpgrade.tres"),
	preload("res://Resources/Upgrades/TankSiegeWorkshopUpgrade.tres"),
	preload("res://Resources/Upgrades/AxeThrowerWarHornsUpgrade.tres"),
	preload("res://Resources/Upgrades/HeroHonorGuardUpgrade.tres"),
	preload("res://Resources/Upgrades/PriestZealousFaithUpgrade.tres"),
	preload("res://Resources/Upgrades/BatRiderWingSquadronUpgrade.tres"),
	preload("res://Resources/Upgrades/GiantRallyPointUpgrade.tres"),
	preload("res://Resources/Upgrades/SpitterBroodSwarmUpgrade.tres"),
]
var _archetype_upgrade_row: HBoxContainer
## Index-aligned with ARCHETYPE_UPGRADE_POOL.
var _archetype_upgrade_buttons: Array[Button] = []
var _buff_row: HBoxContainer
var _targeting_label: Label
var _placement_hint_label: Label
var _hero_level_label: Label
var _hero_xp_bar: ProgressBar
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
	_build_roster_row(shop_card)

	var build_menu_content := _wrap_in_card(root, "Build")
	_build_menu_card = build_menu_content.get_parent() as PanelContainer
	_build_menu_card.visible = false
	_build_unit_panel(build_menu_content)

	var hero_draft_content := _wrap_in_card(root, "Hero Ability Draft")
	_hero_draft_card = hero_draft_content.get_parent() as PanelContainer
	_build_hero_draft_panel(hero_draft_content)

	var match_card := _wrap_in_card(root, "Match")
	_build_team_panel(match_card)

	_build_winner_label()
	_build_drag_box()
	_build_ability_hotbar()
	_build_unit_action_bar()
	_build_archetype_upgrade_row()
	_build_unit_info_panel()
	_build_buff_row()
	_build_targeting_prompt()
	_build_placement_hint()
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
	_refresh_unit_action_bar()
	_refresh_archetype_upgrade_row()
	_refresh_unit_info_panel()
	_refresh_buff_row()
	_refresh_hero_level_label()
	_refresh_placement_hint()
	refresh_match_toggles_visibility()


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


## Grouped by UnitStats.faction (Phase 11: "team-color/material per
## faction" -- the build menu grouping is the free/no-new-art half of
## that, the ground-ring accent in Unit._build_faction_accent() is the
## visual half) instead of one flat button list. Order here is fixed
## (not derived from the archetype list) so the same faction always
## renders in the same position across sessions rather than reshuffling
## based on iteration order. Each faction's {header, grid} pair is kept
## in _faction_group_nodes so refresh_unit_panel_for_faction() (race
## selection) can show/hide whole groups later without rebuilding
## anything -- this function still only ever runs once, in _ready().
func _build_unit_panel(parent: Control) -> void:
	var group := ButtonGroup.new()
	var archetypes: Array[UnitStats] = [
		TANK_STATS, FIGHTER_STATS, AXE_THROWER_STATS,
		ARCHER_STATS, HERO_STATS, PRIEST_STATS,
		BAT_RIDER_STATS, GIANT_STATS, SPITTER_STATS,
	]

	var by_faction: Dictionary = {} # Faction (or null) -> Array[UnitStats], insertion-ordered
	var faction_order: Array = []
	for stats in archetypes:
		if not by_faction.has(stats.faction):
			by_faction[stats.faction] = []
			faction_order.append(stats.faction)
		by_faction[stats.faction].append(stats)

	var first_button := true
	for faction in faction_order:
		var header: Label = null
		if faction != null:
			header = Label.new()
			header.text = (faction as Faction).faction_name
			header.add_theme_font_size_override("font_size", 13)
			header.modulate = Color(0.8, 0.8, 0.8)
			parent.add_child(header)

		var grid := GridContainer.new()
		grid.columns = 2
		grid.add_theme_constant_override("h_separation", 8)
		grid.add_theme_constant_override("v_separation", 8)
		parent.add_child(grid)
		if faction != null:
			_faction_group_nodes[faction] = {"header": header, "grid": grid}

		for stats in by_faction[faction]:
			_add_unit_type_button(grid, group, stats, first_button)
			first_button = false


## Race selection (see UI/MainMenu.gd's lobby faction picker): gates the
## build menu to only `faction`'s own units, hiding the other factions'
## header+grid entirely rather than just their buttons -- an empty
## faction section would still leave a dangling header label with
## nothing under it. `null` shows every faction (classic mode/Hero
## Footies, neither of which opens the build menu at all, and any GUT
## test that never goes through the menu -- Player.faction stays null
## for those, same fallback UnitStats.faction itself already documents).
func refresh_unit_panel_for_faction(faction: Faction) -> void:
	for other_faction in _faction_group_nodes:
		var visible_now: bool = faction == null or other_faction == faction
		var nodes: Dictionary = _faction_group_nodes[other_faction]
		nodes["header"].visible = visible_now
		nodes["grid"].visible = visible_now


## Label includes cost (e.g. "Tank (150g)") so a player can see what they
## can afford at a glance -- only meaningful while economy is active, but
## shown unconditionally since it's just informational text; affordability
## itself is enforced by refresh_affordability() disabling the button.
## tooltip_text is Godot's own built-in hover-tooltip rendering -- no
## custom tooltip UI exists anywhere in this codebase, and none is needed.
func _add_unit_type_button(parent: Control, group: ButtonGroup, stats: UnitStats, is_pressed: bool) -> void:
	var button := _add_toggle_button(parent, "%s (%dg)" % [stats.unit_name, stats.cost], group, is_pressed, func(): unit_type_selected.emit(stats))
	button.tooltip_text = _unit_tooltip_text(stats)
	_set_button_icon(button, stats.icon)
	_apply_faction_border(button, stats.faction)
	_unit_type_buttons.append(button)
	_unit_type_stats.append(stats)


## A colored left border matching the archetype's own Faction.accent_color
## -- the same color Unit._build_faction_accent() already renders as a
## ground ring under the unit in the arena. The shop and the battlefield
## previously shared no visual language at all: every build-menu icon was
## a faction-agnostic white silhouette, and a unit only ever read as
## "team-colored" once placed (usability review, 2026-08-11). A no-op
## when stats.faction is null.
##
## Covers "pressed" too, not just normal/hover/disabled -- independent
## design review, 2026-08-12 flagged Tank showing a solid yellow fill
## while its own Orc siblings (Fighter/Axe Thrower) showed green,
## reading as a faction-color bug. Root cause: _add_toggle_button()
## (called before this) already sets a generic solid-yellow "pressed"
## stylebox for every toggle button in this file (mode toggles, unit
## buttons alike) -- this just never overrode it for the accent-bordered
## case, so the CURRENTLY SELECTED unit type was the one button that
## silently lost its faction color entirely. Selected state now keeps
## the same accent-colored border/background family (a lighter tint of
## it, so "selected" still reads as distinct) instead of swapping to an
## unrelated color.
func _apply_faction_border(button: Button, faction: Faction) -> void:
	if faction == null:
		return
	for state in ["normal", "hover", "disabled"]:
		var style := StyleBoxFlat.new()
		style.bg_color = Color(0.13, 0.13, 0.15) if state != "hover" else Color(0.18, 0.18, 0.2)
		style.set_corner_radius_all(4)
		style.border_color = faction.accent_color
		style.border_width_left = 4
		button.add_theme_stylebox_override(state, style)

	var pressed_style := StyleBoxFlat.new()
	pressed_style.bg_color = faction.accent_color.darkened(0.35)
	pressed_style.set_corner_radius_all(4)
	pressed_style.border_color = faction.accent_color
	pressed_style.border_width_left = 4
	button.add_theme_stylebox_override("pressed", pressed_style)
	button.add_theme_color_override("font_pressed_color", Color.WHITE)
	button.add_theme_color_override("font_hover_pressed_color", Color.WHITE)


## Shared by every button-icon assignment in this file. Resources/Icons/*.svg
## import at a small native size (svg/scale=0.0625, ~32x32) specifically so
## a plain Button.icon assignment renders as a thumbnail already, with no
## runtime scaling needed.
func _set_button_icon(button: Button, icon: Texture2D) -> void:
	button.icon = icon


## The stat/cost summary shown on hover -- the fields most relevant to a
## buy decision (per UnitStats.gd's own doc comments): cost/squad size
## are already in the button label, so the tooltip covers the rest of
## what a player would want to compare before buying. Ability names are
## included when present; combat minutiae (turn_rate, splash_falloff,
## armor_type multipliers, etc.) are deliberately left out -- this is a
## quick-glance summary, not a full stat sheet.
func _unit_tooltip_text(stats: UnitStats) -> String:
	var lines: Array[String] = [
		"%s -- %dg" % [stats.unit_name, stats.cost],
		"Squad size: %d" % stats.squad_size,
		"Health: %.0f    Armor: %.0f" % [stats.max_health, stats.armor],
		"Damage: %.0f    Attack speed: %.1fs    Range: %.1f" % [stats.damage, stats.attack_interval, stats.attack_range],
		"Move speed: %.1f" % stats.move_speed,
	]
	if stats.is_flying:
		lines.append("Flying")
	if not stats.abilities.is_empty():
		var ability_names: Array[String] = []
		for ability in stats.abilities:
			ability_names.append(ability.ability_name)
		lines.append("Abilities: " + ", ".join(ability_names))
	return "\n".join(lines)


## Shown when the player left-clicks their own Builder (see
## PlayerInputController.on_left_release()) -- the always-hidden
## build-menu card becomes visible. Buttons/tooltips are already built
## (see _ready()); nothing to rebuild here, just the visibility flip.
func show_build_menu() -> void:
	_build_menu_card.visible = true


func hide_build_menu() -> void:
	_build_menu_card.visible = false


func is_build_menu_open() -> bool:
	return _build_menu_card.visible


func _build_team_panel(parent: Control) -> void:
	var panel := VBoxContainer.new()
	parent.add_child(panel)

	var group := ButtonGroup.new()
	_blue_team_button = _add_toggle_button(panel, "Blue Team", group, true, func(): team_selected.emit(GameManager.BLUE_TEAM_ID))
	_red_team_button = _add_toggle_button(panel, "Red Team", group, false, func(): team_selected.emit(GameManager.RED_TEAM_ID))

	_add_spacer(panel, 12)
	_build_ai_toggle(panel)
	_add_spacer(panel, 12)
	_build_start_button(panel)


func _add_spacer(parent: Control, height: float) -> void:
	var spacer := Control.new()
	spacer.custom_minimum_size = Vector2(0, height)
	parent.add_child(spacer)


## The default theme's own "pressed" look (a marginally lighter shade of
## the same dark charcoal) barely reads against these already-dark cards
## -- side-by-side, a selected and unselected toggle look nearly
## identical (usability review, 2026-08-11, same category of finding
## refresh_affordability()'s own _UNAFFORDABLE_MODULATE already fixed for
## affordability). A single warm-gold accent (matching the hero XP bar's
## existing fill color, the one deliberate accent color already in this
## UI) on the "pressed" stylebox gives every toggle group in this file --
## team select, build-menu unit selection, hero ability draft picks --
## an unambiguous selected state for free.
const _TOGGLE_SELECTED_COLOR := Color(0.85, 0.7, 0.2)

func _add_toggle_button(parent: Control, label: String, group: ButtonGroup, is_pressed: bool, on_pressed: Callable) -> Button:
	var button := Button.new()
	button.text = label
	button.custom_minimum_size = Vector2(140, 36)
	button.toggle_mode = true
	button.button_group = group
	button.button_pressed = is_pressed
	_style_toggle_button(button)
	button.pressed.connect(on_pressed)
	button.pressed.connect(func(): Sfx.play_ui_click()) # "pressed" only ever fires on real interaction (mouse/keyboard), never from setting button_pressed programmatically -- safe to wire unconditionally here
	parent.add_child(button)
	return button


func _style_toggle_button(button: Button) -> void:
	var pressed_style := StyleBoxFlat.new()
	pressed_style.bg_color = _TOGGLE_SELECTED_COLOR
	pressed_style.set_corner_radius_all(4)
	button.add_theme_stylebox_override("pressed", pressed_style)
	button.add_theme_color_override("font_pressed_color", Color.BLACK)
	button.add_theme_color_override("font_hover_pressed_color", Color.BLACK)


## Placed inside the team panel (as its own VBoxContainer flow) rather than
## anchored independently -- anchoring a Control via position/size before it
## is inside the tree resolves against a zero-size parent rect in Godot 4.7,
## which left this button laid out with an empty/degenerate rect.
func _build_start_button(parent: Control) -> void:
	_start_button = Button.new()
	_start_button.text = "Start Battle"
	_start_button.custom_minimum_size = Vector2(140, 40)
	# Every panel in this HUD shared the same neutral charcoal chrome, so
	# the one button that actually ends PLACEMENT looked no louder than a
	# team-select toggle (usability review, 2026-08-11) -- _style_primary_button()'s
	# filled accent background makes it read as the primary action, not
	# just another row in the Match card.
	_style_primary_button(_start_button)
	_start_button.pressed.connect(_on_start_pressed)
	_start_button.pressed.connect(func(): Sfx.play_ui_click())
	parent.add_child(_start_button)


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
	_ai_toggle.toggled.connect(func(_enabled: bool): Sfx.play_ui_click())
	parent.add_child(_ai_toggle)


## Game mode (Blood Tournament / Hero Footies / classic) is chosen once,
## on the main menu's lobby (UI/MainMenu.gd), before Play -- there is
## deliberately no mid-match way to change it anymore. A mid-match
## toggle used to exist here for quick dev testing, but re-activating an
## already-active mode re-ran GameMode.on_activated() (e.g.
## BloodTournamentMode spawning a fresh per-team Builder fixture) with
## no awareness anything from a previous activation was already live,
## silently duplicating those fixtures. `mode.uses_economy()` below is
## still what actually matters for hiding the AI/team-select controls;
## "is a Blood Tournament/Hero Footies match past its own first
## PLACEMENT" still matters for the AI toggle specifically. Public (no
## leading underscore) -- Main.gd calls this directly after a mode
## change now that there's no button click to trigger it internally.
func refresh_match_toggles_visibility() -> void:
	var mode := GameManager.current_mode
	var tournament_match_underway: bool = mode is BloodTournamentMode and (mode.round_number > 0 or not GameManager.is_placement_phase())
	var hero_footies_match_underway: bool = mode is HeroFootiesMode and not GameManager.is_placement_phase()
	var match_underway := tournament_match_underway or hero_footies_match_underway

	# Blood Tournament decides every slot's human/bot status entirely at
	# the main menu's per-slot lobby now (see UI/MainMenu.gd) -- there's
	# only ever one human team the whole match, so neither the mid-match
	# "AI Opponent" toggle nor the Blue/Red team-select buttons have
	# anything left to do once it's active. Hidden for the WHOLE match
	# (not just "once underway" like the mode toggles above), since
	# uses_economy() is already true from round 1's own PLACEMENT --
	# waiting for match_underway would leave them visible-but-pointless
	# through all of round 1's shopping phase. Classic mode (and Hero
	# Footies, which also doesn't uses_economy()) keeps both, unchanged --
	# still useful for local hotseat-style manual testing.
	var hide_team_and_ai := mode.uses_economy()
	_ai_toggle.visible = not match_underway and not hide_team_and_ai
	_blue_team_button.visible = not hide_team_and_ai
	_red_team_button.visible = not hide_team_and_ai


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
## These labels sit directly on top of the live 3D scene (no backing
## panel) -- the default theme's mid-gray font color barely holds up
## against whatever happens to be rendered underneath (usability review,
## 2026-08-11). A bright near-white fill plus a black outline keeps them
## legible against any background without needing to size/position a
## panel behind each one.
func _style_overlay_label(label: Label) -> void:
	label.add_theme_color_override("font_color", Color(0.95, 0.95, 0.9))
	label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
	label.add_theme_constant_override("outline_size", 6)


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
	_style_overlay_label(_winner_label)
	center.add_child(_winner_label)

	_build_leaderboard_panel()
	_build_gold_panel()


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


## Shared by Start Battle and the leaderboard modal's Continue button --
## both are "the one thing you actually click to move on" action in their
## respective screens, so both get the same filled-gold treatment
## (usability review, 2026-08-11) instead of blending into the rest of
## the charcoal chrome.
func _style_primary_button(button: Button) -> void:
	var style := StyleBoxFlat.new()
	style.bg_color = _TOGGLE_SELECTED_COLOR
	style.set_corner_radius_all(4)
	button.add_theme_stylebox_override("normal", style)
	var hover_style := StyleBoxFlat.new()
	hover_style.bg_color = _TOGGLE_SELECTED_COLOR.lightened(0.15)
	hover_style.set_corner_radius_all(4)
	button.add_theme_stylebox_override("hover", hover_style)
	button.add_theme_color_override("font_color", Color.BLACK)
	button.add_theme_color_override("font_hover_color", Color.BLACK)


## Same dark-card chrome every other HUD group uses -- independent design
## review, 2026-08-12: previously 3 bare Controls (a _style_overlay_label()
## outline-only label, 2 Buttons) floated directly over the 3D world with
## no backing panel, the one HUD group that didn't. A dimmed/disabled
## trade button (_UNAFFORDABLE_MODULATE) could read as visually "clipped"
## against a similarly dark unit or courtyard tile happening to render
## right behind it -- an opaque card backdrop makes that impossible
## regardless of what's in the 3D scene underneath. See show_gold()/
## hide_gold().
func _build_gold_panel() -> void:
	_gold_panel = PanelContainer.new()
	_gold_panel.visible = false
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.1, 0.1, 0.12, 0.85)
	style.set_corner_radius_all(8)
	style.set_content_margin_all(10)
	_gold_panel.add_theme_stylebox_override("panel", style)
	add_child(_gold_panel)

	var content := VBoxContainer.new()
	content.alignment = BoxContainer.ALIGNMENT_CENTER
	content.add_theme_constant_override("separation", 6)
	_gold_panel.add_child(content)

	_gold_label = Label.new()
	_gold_label.add_theme_font_size_override("font_size", 18)
	_gold_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	content.add_child(_gold_label)

	var button_row := HBoxContainer.new()
	button_row.alignment = BoxContainer.ALIGNMENT_CENTER
	button_row.add_theme_constant_override("separation", 8)
	content.add_child(button_row)

	_gold_exchange_button = Button.new()
	_gold_exchange_button.text = "Trade %dg -> %dbp" % [Player.EXCHANGE_GOLD_PER_CLICK, Player.EXCHANGE_BLOOD_PER_CLICK]
	_gold_exchange_button.pressed.connect(func(): gold_exchange_requested.emit())
	_gold_exchange_button.pressed.connect(func(): Sfx.play_ui_click())
	button_row.add_child(_gold_exchange_button)

	_blood_exchange_button = Button.new()
	_blood_exchange_button.text = "Trade %dbp -> %dg" % [Player.EXCHANGE_BLOOD_PER_CLICK, Player.EXCHANGE_GOLD_PER_CLICK]
	_blood_exchange_button.pressed.connect(func(): blood_exchange_requested.emit())
	_blood_exchange_button.pressed.connect(func(): Sfx.play_ui_click())
	button_row.add_child(_blood_exchange_button)


## 5, not 6 -- independent design review, 2026-08-12: Gold was shown
## here AND in the top-center gold panel simultaneously, the same number
## in two places on every in-match screen for no added information. Kept
## in BloodTournamentController.scoreboard_rows()'s own data (still a
## generic "team_id/display_name/color/wins/gold/kills/blood_points"
## row) since other callers may still want it -- only this table stopped
## rendering the column.
const _LEADERBOARD_COLUMNS := 5

## An always-on panel pinned to the right edge of the screen -- a real
## table (rank/team-color-swatch/wins/gold/kills/blood points), collapsed
## to just its header by default with a ▸/▾ toggle (same collapsible
## pattern UI/MainMenu.gd's own "Controls" section already established),
## expanding automatically on show_tournament_score() (a fresh round's
## result) so a player notices without having to go looking, but staying
## out of the way otherwise. Replaces what used to be a dim-backdrop
## modal shown only once per round end. Built once in _ready(); only the
## data rows get rebuilt per refresh_leaderboard() call, same "not every
## frame, so a from-scratch rebuild is safe" reasoning
## _build_ability_draft_row()'s own doc comment already uses -- refresh_leaderboard()
## itself IS called every time gold/kills/wins could plausibly have
## changed (Main._refresh_gold_display()'s own call sites), not just at
## round end, which is what makes this "always on" rather than a stale
## snapshot.
func _build_leaderboard_panel() -> void:
	_leaderboard_card = PanelContainer.new()
	_leaderboard_card.visible = false
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.1, 0.1, 0.12, 0.92)
	style.set_corner_radius_all(8)
	style.set_content_margin_all(16)
	style.border_color = _TOGGLE_SELECTED_COLOR
	style.set_border_width_all(1)
	_leaderboard_card.add_theme_stylebox_override("panel", style)
	add_child(_leaderboard_card)

	var content := VBoxContainer.new()
	content.add_theme_constant_override("separation", 10)
	_leaderboard_card.add_child(content)

	var header_row := HBoxContainer.new()
	header_row.add_theme_constant_override("separation", 8)
	content.add_child(header_row)
	var title := Label.new()
	title.text = "Leaderboard"
	title.add_theme_font_size_override("font_size", 18)
	header_row.add_child(title)
	_leaderboard_collapse_button = Button.new()
	_leaderboard_collapse_button.flat = true
	_leaderboard_collapse_button.pressed.connect(_on_leaderboard_collapse_pressed)
	header_row.add_child(_leaderboard_collapse_button)

	_leaderboard_grid = GridContainer.new()
	_leaderboard_grid.columns = _LEADERBOARD_COLUMNS
	_leaderboard_grid.add_theme_constant_override("h_separation", 18)
	_leaderboard_grid.add_theme_constant_override("v_separation", 6)
	content.add_child(_leaderboard_grid)
	for header in ["Rank", "Team", "Wins", "Kills", "Blood Points"]:
		var header_label := Label.new()
		header_label.text = header
		header_label.add_theme_color_override("font_color", Color(0.65, 0.65, 0.6))
		_leaderboard_grid.add_child(header_label)

	# Open by default -- gameplay feedback, 2026-08-11: players want the
	# standings visible without an extra click, collapsing it themselves
	# (▸/▾) only if they want the screen space back.
	_set_leaderboard_expanded(true)


func _on_leaderboard_collapse_pressed() -> void:
	Sfx.play_ui_click()
	_set_leaderboard_expanded(not _leaderboard_expanded)


func _set_leaderboard_expanded(expanded: bool) -> void:
	_leaderboard_expanded = expanded
	_leaderboard_grid.visible = expanded
	_leaderboard_collapse_button.text = "▾" if expanded else "▸"
	if _leaderboard_card.visible:
		_reposition_leaderboard()


## Called by Main._refresh_gold_display() -- every gold/blood-point/kill
## change, not just round transitions, is what keeps this "always on"
## instead of a stale once-per-round snapshot. `rows` is
## BloodTournamentController.scoreboard_rows(), already sorted by wins
## descending, so this stays a generic "render whatever rows you're
## given" table, same boundary this class's own doc comment already
## describes for GameManager lookups. Does NOT change the collapsed/
## expanded state -- see show_tournament_score() for the one case that
## should auto-expand it.
func refresh_leaderboard(rows: Array[Dictionary]) -> void:
	while _leaderboard_grid.get_child_count() > _LEADERBOARD_COLUMNS:
		_leaderboard_grid.get_child(_LEADERBOARD_COLUMNS).free()

	for i in rows.size():
		var row := rows[i]

		var rank_label := Label.new()
		rank_label.text = "#%d" % (i + 1)
		_leaderboard_grid.add_child(rank_label)

		var team_cell := HBoxContainer.new()
		team_cell.add_theme_constant_override("separation", 8)
		var swatch := ColorRect.new()
		swatch.color = row["color"]
		swatch.custom_minimum_size = Vector2(14, 14)
		team_cell.add_child(swatch)
		var team_label := Label.new()
		team_label.text = row["display_name"]
		team_cell.add_child(team_label)
		_leaderboard_grid.add_child(team_cell)

		var wins_label := Label.new()
		wins_label.text = "%d" % row["wins"]
		_leaderboard_grid.add_child(wins_label)

		var kills_label := Label.new()
		kills_label.text = "%d" % row["kills"]
		_leaderboard_grid.add_child(kills_label)

		var blood_label := Label.new()
		blood_label.text = "%dbp" % row["blood_points"]
		_leaderboard_grid.add_child(blood_label)

	_leaderboard_card.visible = true
	_reposition_leaderboard()


## Called by BloodTournamentController.on_round_ended() specifically --
## the one moment worth interrupting a collapsed panel for. Refreshes the
## same as refresh_leaderboard() (a round ending always changes standings
## anyway) and expands it.
func show_tournament_score(_round_number: int, rows: Array[Dictionary]) -> void:
	refresh_leaderboard(rows)
	_set_leaderboard_expanded(true)


## Hides the panel entirely -- classic mode/Hero Footies (neither has a
## leaderboard at all) and mode transitions. Collapsing is a separate,
## lesser action (_set_leaderboard_expanded(false)) the player drives via
## the ▸/▾ button; this is "nothing to show," not "user tucked it away."
func hide_tournament_score() -> void:
	_leaderboard_card.visible = false


## Repositioned every call rather than only in _ready() -- the card's own
## size changes when it expands/collapses or gains/loses rows, and a
## right-pinned panel needs to stay flush with the (possibly resized)
## viewport edge regardless.
func _reposition_leaderboard() -> void:
	_leaderboard_card.reset_size()
	var viewport_size := get_viewport_rect().size
	_leaderboard_card.position = Vector2(viewport_size.x - _leaderboard_card.size.x - 24, 24)


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

	_gold_panel.reset_size()
	var viewport_width := get_viewport_rect().size.x
	_gold_panel.position = Vector2((viewport_width - _gold_panel.size.x) * 0.5, 48)
	_gold_panel.visible = true


func hide_gold() -> void:
	_gold_panel.visible = false


## Called by Main.gd alongside every gold change/team switch -- greys out
## whichever unit-type buttons `player` can't currently afford. A no-op
## grey-out (never disables anything) while current_mode.uses_economy()
## is false, matching every other gold-gated behavior in this codebase.
## Independent design-review feedback: the default theme's own
## `.disabled` look barely reads against these already-dark cards --
## side-by-side, an affordable and an unaffordable button look nearly
## identical. `.disabled` still gates the actual click (kept, for the
## real behavior), but `modulate` alpha is what actually carries the
## visible "you can't afford this" signal now.
const _UNAFFORDABLE_MODULATE := Color(1, 1, 1, 0.4)

func refresh_affordability(player: Player) -> void:
	var use_gold := GameManager.current_mode.uses_economy()
	for i in _unit_type_buttons.size():
		var unaffordable := use_gold and not player.can_afford(_unit_type_stats[i].cost)
		_unit_type_buttons[i].disabled = unaffordable
		_unit_type_buttons[i].modulate = _UNAFFORDABLE_MODULATE if unaffordable else Color.WHITE
	var gold_unaffordable := use_gold and not player.can_afford(Player.EXCHANGE_GOLD_PER_CLICK)
	_gold_exchange_button.disabled = gold_unaffordable
	_gold_exchange_button.modulate = _UNAFFORDABLE_MODULATE if gold_unaffordable else Color.WHITE
	var blood_unaffordable := use_gold and not player.can_afford_blood_points(Player.EXCHANGE_BLOOD_PER_CLICK)
	_blood_exchange_button.disabled = blood_unaffordable
	_blood_exchange_button.modulate = _UNAFFORDABLE_MODULATE if blood_unaffordable else Color.WHITE


## The "rectangle" -- a literal separate staging area's line-up display,
## not the arena itself. Shows the currently active placement side's
## roster in purchase order (see Player.roster); clicking a slot selects
## that squad (roster_slot_clicked, routed by Main.gd to
## SelectionManager.select_single()) rather than selling it outright --
## selling now only happens via the explicit Sell action in
## _unit_action_bar once something's actually selected (usability
## feedback, 2026-08-11: a single click here silently selling was a real
## complaint, not just a hypothetical foot-gun). Hidden entirely outside
## Blood Tournament via refresh_roster_row([]) -- Main.gd is what decides
## that, same as show_gold()/hide_gold().
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
		button.pressed.connect(func(): roster_slot_clicked.emit(index))
		button.pressed.connect(func(): Sfx.play_ui_click())
		_roster_row.add_child(button)
		_roster_slot_buttons.append(button)

	for i in _roster_slot_buttons.size():
		var button := _roster_slot_buttons[i]
		if i < roster.size():
			var stats := roster[i]
			button.text = "%s x%d" % [stats.unit_name, stats.squad_size] if stats.squad_size > 1 else stats.unit_name
			_set_button_icon(button, stats.icon)
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

	# Chosen candidate gets a "✓ " prefix, not just the shared toggle-button
	## yellow fill -- independent design review, 2026-08-12: color alone
	## didn't clearly read as "this is your locked-in pick" vs. "just a
	## clickable alternative sitting first in the list" (also an
	## accessibility gap -- color-only state is a problem for colorblind
	## players specifically).
	var group := ButtonGroup.new()
	for candidate_index in choice_set.candidates.size():
		var candidate := choice_set.candidates[candidate_index]
		var is_chosen := candidate_index == chosen_index
		var label_text := ("✓ " + candidate.ability_name) if is_chosen else candidate.ability_name
		_add_toggle_button(row, label_text, group, is_chosen,
			func(): hero_ability_picked.emit(stats, slot_index, candidate_index))


## Bottom-center, one button per ability slot (Q/E/R). Fixed at 3 buttons
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
		button.pressed.connect(func(): Sfx.play_ui_click())
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
## The whole hotbar hides rather than showing 3 "-" placeholders when
## there's nothing selected or the selected unit has zero abilities
## (usability review, 2026-08-11: most archetypes have none, so this row
## was permanently visible noise across nearly every screenshot).
func _refresh_ability_hotbar() -> void:
	var unit := _tracked_unit
	var alive := unit != null and is_instance_valid(unit) and unit.life_state == Unit.LifeState.ALIVE
	var has_any_ability := alive and unit.resolved_abilities.any(func(a): return a != null)
	_ability_hotbar.visible = has_any_ability
	if not has_any_ability:
		return

	for i in _ability_slot_buttons.size():
		var button := _ability_slot_buttons[i]
		if not alive or i >= unit.resolved_abilities.size() or unit.resolved_abilities[i] == null:
			button.text = "-"
			button.icon = null
			button.disabled = true
			continue

		var ability: Ability = unit.resolved_abilities[i]
		_set_button_icon(button, ability.icon)
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


## A visible set of "what can I do with the thing I just selected"
## actions -- Sell (with its real refund price) plus, under Blood
## Tournament, the 4 account-wide upgrade purchases (previously only
## reachable via the U/I/O/L hotkeys, with zero visible affordance --
## usability feedback, 2026-08-11: "nothing shows up" when a unit is
## selected). Positioned at the very bottom of the screen -- clear of the
## ability hotbar (viewport_size.y - 80), buff row (-106), and hero
## level/XP bar (-140/-118), all of which only show for specific unit
## types, whereas this bar should be able to show for anything ownable
## regardless of what else is currently visible.
func _build_unit_action_bar() -> void:
	_unit_action_bar = HBoxContainer.new()
	_unit_action_bar.add_theme_constant_override("separation", 6)
	_unit_action_bar.visible = false
	add_child(_unit_action_bar)

	_sell_button = Button.new()
	_sell_button.custom_minimum_size = Vector2(120, 32)
	_style_primary_button(_sell_button)
	_sell_button.pressed.connect(func(): sell_requested.emit())
	_sell_button.pressed.connect(func(): Sfx.play_ui_click())
	_unit_action_bar.add_child(_sell_button)

	for upgrade in [IRON_ARMOR_UPGRADE, WHETSTONE_UPGRADE, HEROIC_VIGOR_UPGRADE, HEROIC_MIGHT_UPGRADE]:
		var button := Button.new()
		button.custom_minimum_size = Vector2(150, 32)
		button.pressed.connect(func(): upgrade_requested.emit(upgrade))
		button.pressed.connect(func(): Sfx.play_ui_click())
		_unit_action_bar.add_child(button)
		_upgrade_buttons.append(button)


## Selling was previously only a right-click-and-hope affordance with no
## visible price; upgrades were hotkey-only with no visible affordance at
## all -- both shown here now whenever a sellable unit is selected during
## PLACEMENT, refund/cost included, so a player can see what a click
## actually does before committing. "Sellable" mirrors
## PlayerInputController.try_sell_unit()'s own gate (own team, not the
## Builder, PLACEMENT only) -- kept in sync by hand since HUD doesn't
## reach into PlayerInputController directly (see this file's own class
## doc comment on staying decoupled from input/selection internals).
## Iron Armor/Whetstone apply to every squad and always show; Heroic
## Vigor/Heroic Might are heroes_only (UnitUpgrade.gd) and only show
## while the selected unit is actually a hero -- offering them against a
## Tank would silently no-op (buy_roster_upgrade() just skips non-hero
## squads) with no indication why.
func _refresh_unit_action_bar() -> void:
	var unit := _tracked_unit
	var sellable := unit != null and is_instance_valid(unit) and unit.life_state == Unit.LifeState.ALIVE \
		and unit.player == SelectionManager.local_player and not unit.stats.is_builder \
		and GameManager.is_placement_phase()
	_unit_action_bar.visible = sellable
	if not sellable:
		return

	var use_gold := GameManager.current_mode.uses_economy()
	if use_gold:
		var refund := int(unit.stats.cost * GameManager.SELL_REFUND_FRACTION)
		_sell_button.text = "Sell (%dg)" % refund
	else:
		_sell_button.text = "Sell"

	var player := SelectionManager.local_player
	for i in _upgrade_buttons.size():
		var upgrade: UnitUpgrade = [IRON_ARMOR_UPGRADE, WHETSTONE_UPGRADE, HEROIC_VIGOR_UPGRADE, HEROIC_MIGHT_UPGRADE][i]
		var button := _upgrade_buttons[i]
		var relevant := use_gold and (not upgrade.heroes_only or unit.stats.is_hero)
		button.visible = relevant
		if not relevant:
			continue
		var unaffordable := not player.can_afford_blood_points(upgrade.cost)
		button.text = "%s (%dbp)" % [upgrade.upgrade_name, upgrade.cost]
		button.disabled = unaffordable
		button.modulate = _UNAFFORDABLE_MODULATE if unaffordable else Color.WHITE

	_unit_action_bar.reset_size()
	var viewport_size := get_viewport_rect().size
	_unit_action_bar.position = Vector2((viewport_size.x - _unit_action_bar.size.x) * 0.5, viewport_size.y - 40)


## One button per ARCHETYPE_UPGRADE_POOL entry, always present (never
## added/removed) -- same "fixed pool, toggle visibility/text in place"
## shape _build_ability_hotbar() already uses, since the pool itself is
## small and fixed regardless of which unit happens to be selected.
func _build_archetype_upgrade_row() -> void:
	_archetype_upgrade_row = HBoxContainer.new()
	_archetype_upgrade_row.add_theme_constant_override("separation", 6)
	_archetype_upgrade_row.visible = false
	add_child(_archetype_upgrade_row)

	for upgrade in ARCHETYPE_UPGRADE_POOL:
		var button := Button.new()
		button.custom_minimum_size = Vector2(170, 32)
		button.pressed.connect(func(): archetype_upgrade_requested.emit(upgrade))
		button.pressed.connect(func(): Sfx.play_ui_click())
		_archetype_upgrade_row.add_child(button)
		_archetype_upgrade_buttons.append(button)


## Shows only the ARCHETYPE_UPGRADE_POOL entries whose own `archetype`
## matches the selected unit's -- e.g. selecting a Fighter shows Battle
## Standard, never Archer's Mortar Support, and selecting a Tank (no
## upgrades defined for it yet) shows nothing at all, same as
## _refresh_unit_action_bar()'s own upgrade buttons hiding when
## irrelevant. Already-owned upgrades stay visible but disabled/labeled
## "(Owned)" rather than disappearing -- confirms the purchase stuck,
## same reasoning a build-menu button doesn't vanish once affordable
## again.
func _refresh_archetype_upgrade_row() -> void:
	var unit := _tracked_unit
	var relevant_base := unit != null and is_instance_valid(unit) and unit.life_state == Unit.LifeState.ALIVE \
		and unit.player == SelectionManager.local_player and GameManager.is_placement_phase() \
		and GameManager.current_mode.uses_economy()

	var any_visible := false
	var player := SelectionManager.local_player
	for i in ARCHETYPE_UPGRADE_POOL.size():
		var upgrade := ARCHETYPE_UPGRADE_POOL[i]
		var button := _archetype_upgrade_buttons[i]
		var applies := relevant_base and upgrade.archetype == unit.stats
		button.visible = applies
		if not applies:
			continue
		any_visible = true

		if player.archetype_upgrades.has(upgrade):
			button.text = "%s (Owned)" % upgrade.upgrade_name
			button.disabled = true
			button.modulate = Color.WHITE
		else:
			var unaffordable := not player.can_afford_blood_points(upgrade.cost)
			button.text = "%s (%dbp)" % [upgrade.upgrade_name, upgrade.cost]
			button.disabled = unaffordable
			button.modulate = _UNAFFORDABLE_MODULATE if unaffordable else Color.WHITE

	_archetype_upgrade_row.visible = any_visible
	if not any_visible:
		return
	_archetype_upgrade_row.reset_size()
	var viewport_size := get_viewport_rect().size
	# Above the hero level label's own -140 slot -- a non-hero archetype
	# (the only kind with an ArchetypeUpgrade defined so far) never shows
	# that label at all, so this doesn't actually collide with it in
	# practice, but sits clear of it on paper too in case a future
	# session adds a hero archetype upgrade.
	_archetype_upgrade_row.position = Vector2((viewport_size.x - _archetype_upgrade_row.size.x) * 0.5, viewport_size.y - 175)


const _UNIT_INFO_PORTRAIT_SIZE := Vector2(64, 64)
const _UNIT_INFO_STATS_WIDTH := 220.0
const _UNIT_INFO_HEALTH_BAR_HEIGHT := 20.0


## Card sized/positioned the same manual "compute from
## get_viewport_rect().size, not anchors" way every other overlay in this
## file already uses (see _leaderboard_card's own doc comment for why).
## Portrait reuses UnitStats.icon -- the same texture already used on
## build-menu/roster buttons, no new art needed. The health bar overlays
## a ProgressBar (fill) with a Label (exact "current / max" numbers, WC3's
## own convention) rather than just a percentage -- show_percentage is
## Godot's own %, not what a player asking "how much HP does this unit
## have left" actually wants.
func _build_unit_info_panel() -> void:
	_unit_info_card = PanelContainer.new()
	_unit_info_card.visible = false
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.08, 0.08, 0.1, 0.9)
	style.set_corner_radius_all(6)
	style.set_content_margin_all(12)
	_unit_info_card.add_theme_stylebox_override("panel", style)
	add_child(_unit_info_card)

	var content := HBoxContainer.new()
	content.add_theme_constant_override("separation", 12)
	_unit_info_card.add_child(content)

	_unit_info_portrait = TextureRect.new()
	_unit_info_portrait.custom_minimum_size = _UNIT_INFO_PORTRAIT_SIZE
	_unit_info_portrait.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	content.add_child(_unit_info_portrait)

	var stats_column := VBoxContainer.new()
	stats_column.custom_minimum_size = Vector2(_UNIT_INFO_STATS_WIDTH, 0)
	stats_column.add_theme_constant_override("separation", 4)
	content.add_child(stats_column)

	_unit_info_name_label = Label.new()
	_unit_info_name_label.add_theme_font_size_override("font_size", 18)
	stats_column.add_child(_unit_info_name_label)

	# ProgressBar's fill + a Label added as its own child, overlaid rather
	# than laid out beside it -- Godot draws a Control's children after
	# itself, so the label renders on top of the bar for free with no
	# separate positioning code, same overlay trick a HUD health/mana bar
	# always uses.
	_unit_info_health_bar = ProgressBar.new()
	_unit_info_health_bar.custom_minimum_size = Vector2(_UNIT_INFO_STATS_WIDTH, _UNIT_INFO_HEALTH_BAR_HEIGHT)
	_unit_info_health_bar.show_percentage = false
	var health_fill_style := StyleBoxFlat.new()
	health_fill_style.bg_color = Color(0.2, 0.75, 0.25)
	_unit_info_health_bar.add_theme_stylebox_override("fill", health_fill_style)
	var health_bg_style := StyleBoxFlat.new()
	health_bg_style.bg_color = Color(0.15, 0.05, 0.05)
	_unit_info_health_bar.add_theme_stylebox_override("background", health_bg_style)
	stats_column.add_child(_unit_info_health_bar)

	_unit_info_health_label = Label.new()
	_unit_info_health_label.set_anchors_preset(Control.PRESET_FULL_RECT)
	_unit_info_health_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_unit_info_health_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_unit_info_health_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_unit_info_health_bar.add_child(_unit_info_health_label)

	_unit_info_armor_label = Label.new()
	stats_column.add_child(_unit_info_armor_label)

	_unit_info_status_label = Label.new()
	stats_column.add_child(_unit_info_status_label)


## Shows for whatever HUD.track_unit() last set, alive or dead, owned or
## not -- WC3 shows an enemy's portrait/health/armor on selection too,
## it's inspection, not an owned-only action bar like _unit_action_bar's
## Sell/upgrades are.
func _refresh_unit_info_panel() -> void:
	var unit := _tracked_unit
	var visible_now := unit != null and is_instance_valid(unit)
	_unit_info_card.visible = visible_now
	if not visible_now:
		return

	_unit_info_portrait.texture = unit.stats.icon
	_unit_info_name_label.text = unit.stats.unit_name

	var max_health := unit.stat_block.max_health()
	_unit_info_health_bar.max_value = max_health
	_unit_info_health_bar.value = clampf(unit.current_health, 0.0, max_health)
	_unit_info_health_label.text = "%d / %d" % [maxi(int(ceilf(unit.current_health)), 0), int(max_health)]

	_unit_info_armor_label.text = "Armor: %.1f" % unit.stat_block.armor()
	_unit_info_status_label.text = "Status: %s" % unit.status_summary()

	_unit_info_card.reset_size()
	var viewport_size := get_viewport_rect().size
	# Stacked above UI/DebugPanel.gd's own bottom-left diagnostic panel
	# (also always-visible whenever a unit is selected, see its own class
	# doc comment), not flush to the bottom edge like every other
	# bottom-left candidate position would be -- HUD.gd stays decoupled
	# from DebugPanel (separate scenes under Main.tscn's HUDLayer, no
	# direct reference either way, matching this file's own class doc
	# comment on staying decoupled from unrelated internals), so this is
	# a fixed clearance, not a measurement of DebugPanel's real height --
	# generous enough to clear its detailed-stats-expanded height too.
	_unit_info_card.position = Vector2(24, viewport_size.y - _unit_info_card.size.y - 220)


func _build_buff_row() -> void:
	_buff_row = HBoxContainer.new()
	_buff_row.add_theme_constant_override("separation", 4)
	add_child(_buff_row)


## Grow-only pool of icon+label entries (same pattern DebugInspector/
## SelectionManager use for their 3D indicators, just for 2D nodes here)
## rather than queue_free()-ing and rebuilding every frame -- a
## queue_free()'d child is still present in the tree until end-of-frame
## idle cleanup, so measuring this container's size again in the same
## frame (reset_size(), right below) would double-count it. Hidden pool
## entries cost nothing: a Container doesn't allocate layout space for an
## invisible child.
func _refresh_buff_row() -> void:
	var unit := _tracked_unit
	var alive := unit != null and is_instance_valid(unit) and unit.life_state == Unit.LifeState.ALIVE
	var effects: Array[Effect] = []
	if alive:
		effects = unit.get_active_effects()

	while _buff_row.get_child_count() < effects.size():
		var entry := HBoxContainer.new()
		entry.add_theme_constant_override("separation", 2)
		var icon_rect := TextureRect.new()
		icon_rect.custom_minimum_size = Vector2(16, 16)
		icon_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		icon_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		entry.add_child(icon_rect)
		var label := Label.new()
		label.add_theme_font_size_override("font_size", 14)
		entry.add_child(label)
		_buff_row.add_child(entry)

	for i in _buff_row.get_child_count():
		var entry: HBoxContainer = _buff_row.get_child(i)
		if i < effects.size():
			var effect := effects[i]
			var remaining := "%.1fs" % (effect.duration - effect.elapsed) if effect.duration > 0.0 else "perm"
			var icon_rect: TextureRect = entry.get_child(0)
			var label: Label = entry.get_child(1)
			label.text = "%s (%s)" % [effect.id, remaining]
			# Effect.source is opaque (see its own doc comment) -- only
			# read .icon off it when it's actually the Ability that
			# created this Effect, same guard StatBlock.Modifier's own
			# identity-only use of `source` implies.
			icon_rect.texture = effect.source.icon if effect.source is Ability else null
			entry.visible = true
		else:
			entry.visible = false

	_buff_row.reset_size()
	var viewport_size := get_viewport_rect().size
	_buff_row.position = Vector2((viewport_size.x - _buff_row.size.x) * 0.5, viewport_size.y - 106)


func _build_targeting_prompt() -> void:
	_targeting_label = Label.new()
	_targeting_label.visible = false
	_targeting_label.add_theme_font_size_override("font_size", 20)
	_targeting_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_style_overlay_label(_targeting_label)
	add_child(_targeting_label)


## Called by PlayerInputController while a UNIT_TARGET ability
## (try_cast_or_target()) or a Patrol order (begin_patrol_targeting()) is
## awaiting a click -- `prompt_text` is the caller's own full sentence
## (e.g. "Select a target for Frost Bolt", "Select a Patrol destination"),
## not just a bare ability name, so this stays generic to whichever
## click-to-target flow is using it.
func show_targeting_prompt(prompt_text: String) -> void:
	_targeting_label.text = "%s (right-click or Esc to cancel)" % prompt_text
	_targeting_label.reset_size()
	var viewport_width := get_viewport_rect().size.x
	_targeting_label.position = Vector2((viewport_width - _targeting_label.size.x) * 0.5, 80)
	_targeting_label.visible = true


func hide_targeting_prompt() -> void:
	_targeting_label.visible = false


func _build_placement_hint() -> void:
	_placement_hint_label = Label.new()
	_placement_hint_label.visible = false
	_placement_hint_label.add_theme_font_size_override("font_size", 16)
	_placement_hint_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_style_overlay_label(_placement_hint_label)
	add_child(_placement_hint_label)


## A blank arena with no accompanying instructions gave a first-time
## player nothing to go on (usability review, 2026-08-11 -- the classic-
## mode placement screen is otherwise just two side cards and an empty
## floor). Only shown during PLACEMENT -- once a battle is underway the
## player already knows what to do, and the label would just be clutter
## competing with the ability hotbar/buff row for the same screen space.
## Text depends on uses_economy() since the two placement flows are
## genuinely different (click-to-place vs. click-your-Builder-to-buy).
func _refresh_placement_hint() -> void:
	if not GameManager.is_placement_phase():
		_placement_hint_label.visible = false
		return

	_placement_hint_label.text = "Click your Builder to buy units, drag squads in your courtyard to reorder, then Start Battle" \
		if GameManager.current_mode.uses_economy() \
		else "Click the arena to place a unit, right-click a unit to sell it, then Start Battle"
	_placement_hint_label.reset_size()
	var viewport_width := get_viewport_rect().size.x
	_placement_hint_label.position = Vector2((viewport_width - _placement_hint_label.size.x) * 0.5, 140)
	_placement_hint_label.visible = true


const _XP_BAR_SIZE := Vector2(160, 10)

func _build_hero_level_label() -> void:
	_hero_level_label = Label.new()
	_hero_level_label.visible = false
	_hero_level_label.add_theme_font_size_override("font_size", 16)
	_hero_level_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	add_child(_hero_level_label)

	# A ProgressBar, not just text -- independent design-review feedback:
	# a plain "12 / 100 XP" number gives no at-a-glance sense of how
	# close a level-up is. Exact numbers still available via tooltip_text
	# on hover, not deleted, just not the primary always-visible readout.
	_hero_xp_bar = ProgressBar.new()
	_hero_xp_bar.visible = false
	_hero_xp_bar.show_percentage = false
	_hero_xp_bar.custom_minimum_size = _XP_BAR_SIZE
	var bg_style := StyleBoxFlat.new()
	bg_style.bg_color = Color(0.1, 0.1, 0.12, 0.85)
	bg_style.set_corner_radius_all(3)
	_hero_xp_bar.add_theme_stylebox_override("background", bg_style)
	var fill_style := StyleBoxFlat.new()
	fill_style.bg_color = Color(0.85, 0.7, 0.2)
	fill_style.set_corner_radius_all(3)
	_hero_xp_bar.add_theme_stylebox_override("fill", fill_style)
	add_child(_hero_xp_bar)


## Hidden entirely for a non-hero tracked unit (or none selected) --
## Unit.level/xp are unused fields for anything else, see UnitStats.is_hero.
func _refresh_hero_level_label() -> void:
	var unit := _tracked_unit
	var alive := unit != null and is_instance_valid(unit) and unit.life_state == Unit.LifeState.ALIVE
	if not alive or not unit.stats.is_hero:
		_hero_level_label.visible = false
		_hero_xp_bar.visible = false
		return

	var viewport_size := get_viewport_rect().size

	_hero_level_label.text = "Level %d" % unit.level
	_hero_level_label.reset_size()
	_hero_level_label.position = Vector2((viewport_size.x - _hero_level_label.size.x) * 0.5, viewport_size.y - 140)
	_hero_level_label.visible = true

	_hero_xp_bar.max_value = unit.get_xp_to_next_level()
	_hero_xp_bar.value = unit.xp
	_hero_xp_bar.tooltip_text = "%d / %d XP" % [int(unit.xp), int(unit.get_xp_to_next_level())]
	_hero_xp_bar.position = Vector2((viewport_size.x - _XP_BAR_SIZE.x) * 0.5, viewport_size.y - 118)
	_hero_xp_bar.visible = true


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
