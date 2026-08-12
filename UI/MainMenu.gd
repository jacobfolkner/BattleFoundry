## Front screen shown before Scenes/Main.tscn (see project.godot's
## run/main_scene). Mode-first, then setup: Blood Tournament / Hero
## Footies toggles, a per-slot lobby (color/name/Empty-You-Bot picker per
## team, see _build_lobby_panel()) that appears once Blood Tournament is
## on, plus a plain-text controls reference, since the input surface
## (drag-select, right-click orders, Q/E/R abilities with click-to-target,
## control groups, U/I upgrades...) has grown well past "click to place,
## click to fight" since this was the only screen anyone saw. Blood
## Tournament and Hero Footies are mutually exclusive here too (see
## _build_options()' own toggle wiring), matching the guard
## Main._on_tournament_toggled()/_on_hero_footies_toggled() already
## enforce mid-match -- both claim GameManager.current_mode.
##
## Built in code, same as UI/HUD.gd and for the same reason: a handful of
## controls is just as readable this way and keeps it in one file. Choices
## are handed off via the MenuSelection autoload (see its own doc comment
## for why that's a separate tiny autoload rather than fields on
## GameManager) -- Main.gd consumes and clears them in _ready(). A
## "Settings" button (below "Play") leads to Scenes/SettingsMenu.tscn,
## Phase 10's keybind remap screen.
class_name MainMenu
extends Control

const LAUREL_CROWN_ICON: Texture2D = preload("res://Resources/Icons/LaurelCrown.svg")
const WAR_STOMP_ICON: Texture2D = preload("res://Resources/Icons/WarStomp.svg")

var _tournament_toggle: Button
var _hero_footies_toggle: Button
var _settings_button: Button
var _play_button: Button
## Per-slot lobby (see _build_lobby_panel()): index = team_id,
## SlotChoice.EMPTY/YOU/BOT. Only visible/relevant while _tournament_toggle
## is on -- Hero Footies keeps its own fixed 1v1 assumption, no lobby
## needed (see its own class doc comment for why).
var _slot_options: Array[OptionButton] = []
## Per-slot race pick, one per lobby row (index = team_id), sitting right
## after that row's Empty/You/Bot picker -- every slot gets one now, not
## just the human's. Index 0 is always "Random" (leaves that team_id out
## of MenuSelection.chosen_factions entirely, see
## apply_selection_to_menu_state()), indices 1+ map to
## FactionRegistry.ALL[index - 1]. Defaults to Random for every slot.
var _faction_options: Array[OptionButton] = []
var _lobby_panel: VBoxContainer

enum SlotChoice { EMPTY, YOU, BOT }

var _loading_overlay: Control
var _loading_label: Label
## Cosmetic-only, just to prove the app is still alive during the scene
## load/first-render below -- not real load progress, since
## ResourceLoader.load_threaded_get_status() has no percentage for a
## single small scene like Main.tscn.
var _loading_dots_elapsed: float = 0.0


func _ready() -> void:
	# set_anchors_preset(FULL_RECT) alone leaves this scene's root Control
	# at (0,0) size -- confirmed via isolated testing that a bare Control
	# created directly in code sizes correctly the same frame, but a
	# *scene root* loaded from a .tscn with no saved anchor/offset data
	# does not. Every previous build of this menu (including the one
	# that actually shipped) had every control jammed at the top-left
	# corner because of this -- this was never cosmetic-only. Explicit
	# size/position from the viewport rect instead of anchors is the
	# fix, matching UI/HUD.gd's own established convention for its
	# viewport-relative elements (gold label, minimap, etc.) -- those
	# also compute position from get_viewport_rect().size directly each
	# frame rather than relying on anchors, for the same
	# "parentless Control never reliably resolves size/position from
	# anchors alone" reason CLAUDE.md documents.
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
	column.add_theme_constant_override("separation", 18)
	center.add_child(column)

	_build_title(column)
	var mode_card := _wrap_in_card(column, "Game Mode")
	_build_options(mode_card)
	_build_controls_card(column)
	var actions_card := _wrap_in_card(column, "")
	_build_play_button(actions_card)
	_build_settings_button(actions_card)
	_build_loading_overlay()


func _build_title(parent: Control) -> void:
	var title := Label.new()
	title.text = "BattleFoundry"
	title.add_theme_font_size_override("font_size", 40)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	parent.add_child(title)


## Wraps a titled group of controls in a background PanelContainer --
## same pattern UI/HUD.gd's own _wrap_in_card() establishes for the
## in-battle placement screen, reused here so this front screen doesn't
## read as a bare column of unstyled controls. Returns the inner
## VBoxContainer callers add their own content to.
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


func _build_options(parent: Control) -> void:
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 12)
	parent.add_child(row)

	_tournament_toggle = _add_toggle(row, "Blood Tournament: Off", "Blood Tournament: On", LAUREL_CROWN_ICON)
	_hero_footies_toggle = _add_toggle(row, "Hero Footies: Off", "Hero Footies: On", WAR_STOMP_ICON)

	# Both game-mode toggles claim GameManager.current_mode (same mutual
	# exclusion Main._on_tournament_toggled()/_on_hero_footies_toggled()
	# already enforce mid-match) -- mirrored here so the menu's own
	# checkbox state can't silently disagree with what Play would actually
	# start once Main._apply_menu_selection() runs.
	_tournament_toggle.toggled.connect(func(enabled: bool):
		if enabled:
			_hero_footies_toggle.set_pressed_no_signal(false)
			_hero_footies_toggle.text = "Hero Footies: Off"
		_lobby_panel.visible = enabled
	)
	_hero_footies_toggle.toggled.connect(func(enabled: bool):
		if enabled:
			_tournament_toggle.set_pressed_no_signal(false)
			_tournament_toggle.text = "Blood Tournament: Off"
			_lobby_panel.visible = false
	)

	_build_lobby_panel(parent)


## Mode-first, then the lobby: one row per registered team (color swatch +
## name + a 3-way Empty/You/Bot picker + a per-slot race picker), visible
## only once Blood Tournament is toggled on -- "pick mode, then pick your
## color, then mark any number of the other slots as bots" (confirmed
## design, replacing the old blunt "AI Opponent: On/Off" + flat
## team/team-count dropdowns, which couldn't leave a slot empty or choose
## which specific slots were bots). "You" is exclusive across rows --
## picking it on one row resets whichever other row currently has it back
## to Empty (see _on_slot_option_selected()) -- every other slot can
## independently be Bot or Empty, any number of each. The race picker sits
## beside every slot regardless of Empty/You/Bot (gameplay feedback,
## 2026-08-11: "race should be an option beside every slot... default to
## random for every team") -- an Empty slot's pick is simply never read
## (Main._apply_menu_selection() only assigns factions to registered
## teams, which is every team regardless of who's playing, but an Empty
## team never fields a roster for it to matter).
func _build_lobby_panel(parent: Control) -> void:
	_lobby_panel = VBoxContainer.new()
	_lobby_panel.add_theme_constant_override("separation", 4)
	_lobby_panel.visible = false
	parent.add_child(_lobby_panel)

	_build_lobby_header_row(_lobby_panel)

	for team_id in GameManager.all_team_ids():
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 8)
		_lobby_panel.add_child(row)

		# A rounded PanelContainer, not a plain ColorRect -- ColorRect has
		# no corner-radius of its own, and every other surface on this
		# screen (cards, buttons) is already rounded via StyleBoxFlat.
		var swatch := PanelContainer.new()
		var swatch_style := StyleBoxFlat.new()
		swatch_style.bg_color = GameManager.get_player(team_id).color
		swatch_style.set_corner_radius_all(4)
		swatch.add_theme_stylebox_override("panel", swatch_style)
		swatch.custom_minimum_size = Vector2(16, 16)
		row.add_child(swatch)

		var label := Label.new()
		label.text = GameManager.get_team_display_name(team_id)
		label.custom_minimum_size = Vector2(90, 0)
		row.add_child(label)

		var option := OptionButton.new()
		option.custom_minimum_size = Vector2(100, 32)
		option.add_item("Empty", SlotChoice.EMPTY)
		option.add_item("You", SlotChoice.YOU)
		option.add_item("Bot", SlotChoice.BOT)
		option.select(SlotChoice.YOU if team_id == GameManager.BLUE_TEAM_ID else SlotChoice.EMPTY)
		option.item_selected.connect(_on_slot_option_selected.bind(team_id))
		row.add_child(option)
		_slot_options.append(option)

		var faction_option := OptionButton.new()
		faction_option.custom_minimum_size = Vector2(120, 32)
		faction_option.add_item("Random", 0)
		for i in FactionRegistry.ALL.size():
			faction_option.add_item(FactionRegistry.ALL[i].faction_name, i + 1)
		faction_option.select(0)
		faction_option.item_selected.connect(func(_index: int): Sfx.play_ui_click())
		row.add_child(faction_option)
		_faction_options.append(faction_option)


## Labels the two dropdown columns -- independent design review,
## 2026-08-12: "no column headers... 'You/Empty' and 'Random' are only
## guessable as Player-slot and Race from context." Column widths
## mirror each data row's own Controls exactly (swatch 16 + name 90 as
## one blank-text spacer, then two labels matching the dropdowns' own
## custom_minimum_size) so headers land flush above their real column
## regardless of container spacing.
func _build_lobby_header_row(parent: Control) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	parent.add_child(row)

	var spacer := Label.new()
	spacer.custom_minimum_size = Vector2(16 + 8 + 90, 0)
	row.add_child(spacer)

	var player_header := Label.new()
	player_header.text = "Player"
	player_header.custom_minimum_size = Vector2(100, 0)
	player_header.add_theme_color_override("font_color", Color(0.65, 0.65, 0.6))
	row.add_child(player_header)

	var race_header := Label.new()
	race_header.text = "Race"
	race_header.custom_minimum_size = Vector2(120, 0)
	race_header.add_theme_color_override("font_color", Color(0.65, 0.65, 0.6))
	row.add_child(race_header)


func _on_slot_option_selected(index: int, team_id: int) -> void:
	Sfx.play_ui_click()
	if index != SlotChoice.YOU:
		return
	for other_team_id in GameManager.all_team_ids():
		if other_team_id != team_id and _slot_options[other_team_id].selected == SlotChoice.YOU:
			_slot_options[other_team_id].select(SlotChoice.EMPTY)


## Godot's toggle_mode Button already swaps between the "normal" and
## "pressed" theme styleboxes automatically based on button_pressed --
## green-for-on/neutral-for-off just needed those two styleboxes set,
## no manual per-toggle swapping. Previously plain default-gray chrome
## either way (independent design review, 2026-08-12: "the On/Off state
## has no color coding at all, same white text either way -- you have to
## read the word, not glance at a color"). Same green Play's own button
## uses, not a new color -- reads as "this is the same kind of positive/
## active state," not a third unrelated meaning.
func _add_toggle(parent: Control, off_text: String, on_text: String, icon: Texture2D = null) -> Button:
	var button := Button.new()
	button.text = off_text
	button.icon = icon
	button.custom_minimum_size = Vector2(190, 40)
	button.toggle_mode = true

	var off_style := StyleBoxFlat.new()
	off_style.bg_color = Color(0.16, 0.16, 0.18)
	off_style.set_corner_radius_all(6)
	button.add_theme_stylebox_override("normal", off_style)
	var on_style := StyleBoxFlat.new()
	on_style.bg_color = Color(0.2, 0.45, 0.25)
	on_style.set_corner_radius_all(6)
	button.add_theme_stylebox_override("pressed", on_style)
	var hover_style := StyleBoxFlat.new()
	hover_style.bg_color = Color(0.22, 0.22, 0.25)
	hover_style.set_corner_radius_all(6)
	button.add_theme_stylebox_override("hover", hover_style)

	button.toggled.connect(func(enabled: bool): button.text = on_text if enabled else off_text)
	button.toggled.connect(func(_enabled: bool): Sfx.play_ui_click()) # only ever fires on real interaction -- the mutual-exclusion resets in _build_options() use set_pressed_no_signal() specifically to avoid re-triggering this
	parent.add_child(button)
	return button


## Collapsed by default -- this used to be an always-visible 8-line wall
## of hotkey text leading the front screen before the player had done
## anything, reading as a reference manual rather than a menu
## (independent design-review feedback). One click away instead of
## deleted -- the reference is still genuinely useful once the input
## surface (drag-select, control groups, U/I/O/L upgrades...) is more
## than "click to place, click to fight" (see this file's own class doc
## comment).
func _build_controls_card(parent: Control) -> void:
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

	var label := Label.new()
	label.text = "Left-click: place a unit / select a unit (drag for box-select)\n" \
		+ "Right-click: attack / follow / attack-move -- sells a unit during placement\n" \
		+ "X / H: stop / hold position\n" \
		+ "P: patrol (click a destination) -- right-click or Esc cancels\n" \
		+ "Q / E / R: cast ability slot 0/1/2 (click a unit to target it)\n" \
		+ "1-9: recall a control group -- Ctrl+1-9: assign the current selection\n" \
		+ "U / I / O / L: buy a shop upgrade for your whole roster (Blood Tournament only)\n" \
		+ "WASD / arrow keys: pan the camera -- mouse wheel / right-drag: zoom / orbit"
	label.add_theme_font_size_override("font_size", 16)
	label.visible = false

	var toggle := Button.new()
	toggle.text = "Controls ▸"
	toggle.flat = true
	toggle.alignment = HORIZONTAL_ALIGNMENT_LEFT
	toggle.pressed.connect(func():
		label.visible = not label.visible
		toggle.text = "Controls ▾" if label.visible else "Controls ▸"
	)
	toggle.pressed.connect(func(): Sfx.play_ui_click())
	content.add_child(toggle)
	content.add_child(label)


## A distinct fill color and larger size than Settings -- independent
## design-review feedback: the two used to look like equal-weight
## siblings, with nothing marking Play as the primary action on the
## whole screen.
func _build_play_button(parent: Control) -> void:
	_play_button = Button.new()
	_play_button.text = "Play"
	_play_button.custom_minimum_size = Vector2(220, 56)
	_play_button.add_theme_font_size_override("font_size", 20)
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.2, 0.45, 0.25)
	style.set_corner_radius_all(6)
	_play_button.add_theme_stylebox_override("normal", style)
	var hover_style := StyleBoxFlat.new()
	hover_style.bg_color = Color(0.25, 0.55, 0.3)
	hover_style.set_corner_radius_all(6)
	_play_button.add_theme_stylebox_override("hover", hover_style)
	var pressed_style := StyleBoxFlat.new()
	pressed_style.bg_color = Color(0.15, 0.35, 0.2)
	pressed_style.set_corner_radius_all(6)
	_play_button.add_theme_stylebox_override("pressed", pressed_style)
	_play_button.pressed.connect(_on_play_pressed)
	_play_button.pressed.connect(func(): Sfx.play_ui_click()) # Sfx is an autoload, so this keeps playing across the scene change below without issue
	parent.add_child(_play_button)


## Hidden full-rect overlay shown while Main.tscn loads and, more
## importantly, while its first real frame renders -- pressing Play used
## to call get_tree().change_scene_to_file()/change_scene_to_packed()
## directly, which frees MainMenu (and this overlay with it) the instant
## the new scene is assigned, well before Main.tscn's own first frame
## actually renders. Main.tscn's *resource load* is fast (~100ms, see
## _MAIN_SCENE_PATH's own doc comment) but the first frame that scene
## renders still pays Forward+'s known shader/pipeline-compile cost
## (already documented in CLAUDE.md for tools/screenshot.sh's own ~30s
## first-invocation hit) -- with the overlay already gone by then, that
## stutter read as a frozen/broken window, not a loading one, arguably
## worse than before once the load itself stopped being the bottleneck.
## _on_play_pressed() now keeps this overlay alive through Main's actual
## first frames (see its own doc comment) rather than handing off to
## change_scene's instant free.
##
## Wrapped in its own CanvasLayer at a layer index (100) well above
## Main's own HUD (a plain CanvasLayer at the default index, 0) --
## needed because _on_play_pressed() briefly has both MainMenu and a
## fully-_ready() Main coexisting as siblings under the tree root, and
## without an explicit higher layer, draw order between same-layer
## CanvasItems follows tree order (Main, added later, would draw on top
## and let its HUD show through mid-transition instead of staying
## hidden behind this overlay).
func _build_loading_overlay() -> void:
	var loading_layer := CanvasLayer.new()
	loading_layer.layer = 100
	add_child(loading_layer)

	_loading_overlay = Control.new()
	_loading_overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	_loading_overlay.visible = false
	_loading_overlay.mouse_filter = Control.MOUSE_FILTER_STOP # eat clicks while loading
	loading_layer.add_child(_loading_overlay)

	var background := ColorRect.new()
	background.color = Color(0.02, 0.02, 0.02, 0.85)
	background.set_anchors_preset(Control.PRESET_FULL_RECT)
	_loading_overlay.add_child(background)

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	_loading_overlay.add_child(center)

	_loading_label = Label.new()
	_loading_label.text = "Loading"
	_loading_label.add_theme_font_size_override("font_size", 28)
	center.add_child(_loading_label)


## Ticks the loading label's ellipsis while _loading_overlay is visible --
## a no-op the rest of the time (before Play is pressed, and after the
## scene change actually happens and this node is freed with the rest of
## MainMenu).
func _process(delta: float) -> void:
	if not _loading_overlay.visible:
		return
	_loading_dots_elapsed += delta
	var dot_count := int(_loading_dots_elapsed / 0.4) % 4
	_loading_label.text = "Loading" + ".".repeat(dot_count)


## Split from the scene-change call itself so tests can exercise the
## selection hand-off without also making a GUT test's own SceneTree tear
## down and reload a whole new scene.
func apply_selection_to_menu_state() -> void:
	MenuSelection.start_with_tournament = _tournament_toggle.button_pressed
	MenuSelection.start_with_hero_footies = _hero_footies_toggle.button_pressed
	MenuSelection.human_team_id = GameManager.BLUE_TEAM_ID
	MenuSelection.bot_team_ids.clear()
	for team_id in GameManager.all_team_ids():
		match _slot_options[team_id].selected:
			SlotChoice.YOU:
				MenuSelection.human_team_id = team_id
			SlotChoice.BOT:
				MenuSelection.bot_team_ids.append(team_id)

	MenuSelection.chosen_factions.clear()
	for team_id in GameManager.all_team_ids():
		var faction_index: int = _faction_options[team_id].get_selected_id()
		if faction_index > 0:
			MenuSelection.chosen_factions[team_id] = FactionRegistry.ALL[faction_index - 1]


## Plain synchronous load(), NOT ResourceLoader.load_threaded_request() --
## this used to poll load_threaded_get_status() across awaited frames
## specifically to keep _loading_overlay animating throughout, on the
## reasoning that a direct get_tree().change_scene_to_file() blocked the
## main thread for the entire load with the overlay never getting a
## chance to draw first. Measured instead of assumed (tools/ had a
## throwaway timing driver this session, since deleted): Main.tscn's own
## resource graph loads in ~100ms via a plain load() -- every .tres/.svg
## under Resources/ loads in ~25ms combined, so there's nothing here
## worth threading. The threaded path was actually costing 40x+ that
## (4+ real seconds, reproduced 3 times) -- polling load_threaded_get_status()
## forces a render frame between each check, and under a loaded/CPU-
## constrained machine that starves the background loader thread of the
## CPU time it needs, adding real wall-clock seconds to what should be a
## sub-frame load.
const _MAIN_SCENE_PATH := "res://Scenes/Main.tscn"

## How many frames to keep Main hidden behind the loading overlay after
## it's added to the tree, before revealing it -- covers _ready() itself
## (synchronous, same frame) plus a couple of real rendered frames so
## Forward+'s first-time shader/pipeline compile for this project's
## primitive meshes/StandardMaterial3D (unavoidable at the API level --
## see _build_loading_overlay()'s doc comment) happens while the overlay
## still occludes it, not after.
const _POST_ADD_SETTLE_FRAMES := 3


## No longer hands off to get_tree().change_scene_to_packed() -- that
## frees MainMenu (and _loading_overlay with it) the instant the new
## scene is assigned, which used to happen well before Main.tscn's own
## first real frame had actually rendered (see _build_loading_overlay()'s
## doc comment for why that read as a frozen window once the load itself
## stopped being the bottleneck). Manually adds Main as a sibling first,
## waits for it to settle behind the still-visible overlay
## (_POST_ADD_SETTLE_FRAMES), and only then removes MainMenu and hands
## SceneTree.current_scene over -- so whatever's left of the wait always
## has something legible on screen, load-time bug or genuine GPU compile
## cost alike.
func _on_play_pressed() -> void:
	apply_selection_to_menu_state()

	_play_button.disabled = true
	_loading_overlay.visible = true
	_loading_dots_elapsed = 0.0
	await get_tree().process_frame
	await get_tree().process_frame # a second frame, to be sure the overlay was actually presented before the load below starts

	var packed: PackedScene = load(_MAIN_SCENE_PATH)
	if packed == null:
		push_error("Failed to load Main.tscn")
		_loading_overlay.visible = false
		_play_button.disabled = false
		return

	var tree := get_tree() # get_tree() returns null once self is removed from the tree below -- must be cached before that point
	var main := packed.instantiate()
	tree.root.add_child(main) # runs Main._ready() synchronously, right here -- still hidden behind this menu's own layer-100 overlay
	for i in _POST_ADD_SETTLE_FRAMES:
		await tree.process_frame

	tree.root.remove_child(self)
	tree.current_scene = main
	queue_free()


## Roadmap Phase 10's "settings/keybind remapping UI" -- Scripts/Autoloads/Hotkeys.gd
## already has the actual InputMap-rebind mechanism (rebind(), tested by
## tests/test_hotkeys.gd); UI/SettingsMenu.gd is the screen that
## finally calls into it. A separate scene (not a panel bolted onto this
## one) since it needs its own full-screen key-capture input handling
## (_unhandled_input()) that would otherwise compete with this menu's own.
func _build_settings_button(parent: Control) -> void:
	_settings_button = Button.new()
	_settings_button.text = "Settings"
	_settings_button.custom_minimum_size = Vector2(190, 40)
	_settings_button.pressed.connect(_on_settings_pressed)
	_settings_button.pressed.connect(func(): Sfx.play_ui_click())
	parent.add_child(_settings_button)


func _on_settings_pressed() -> void:
	get_tree().change_scene_to_file("res://Scenes/SettingsMenu.tscn")
