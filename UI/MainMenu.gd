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

## REMOTE marks "the connected LAN peer's team" -- only meaningful once
## hosting a connected NetworkSession, and only one slot may be REMOTE at
## a time (_on_slot_option_selected() extends the same mutual-exclusivity
## reset it already gives YOU). Outside a hosted session the item is
## still present in the dropdown (built once at _ready(), simplest to
## keep unconditional) but nothing ever reads it -- the local Play flow's
## apply_selection_to_menu_state() only ever checks EMPTY/YOU/BOT.
enum SlotChoice { EMPTY, YOU, BOT, REMOTE }

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
	_build_multiplayer_card(column)
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
## only once Blood Tournament is toggled on. "You" is exclusive across
## rows -- picking it on one row resets whichever other row currently
## has it back to Empty (see _on_slot_option_selected()) -- every other
## slot can independently be Bot or Empty, any number of each. The race
## picker sits beside every slot regardless of Empty/You/Bot; an Empty
## slot's pick is simply never read (an Empty team never fields a roster).
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
		option.add_item("Remote", SlotChoice.REMOTE)
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


## Labels the two dropdown columns. Column widths mirror each data row's
## own Controls exactly (swatch 16 + name 90 as one blank-text spacer,
## then two labels matching the dropdowns' own custom_minimum_size) so
## headers land flush above their real column regardless of container spacing.
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


## YOU and REMOTE are each exclusive across rows (at most one slot of
## each at a time) -- REMOTE additionally means "the connected LAN peer,"
## so a second REMOTE pick would silently mean "two different peers are
## slot 5" once Start Match serializes only a single remote_team_id.
func _on_slot_option_selected(index: int, team_id: int) -> void:
	Sfx.play_ui_click()
	if index != SlotChoice.YOU and index != SlotChoice.REMOTE:
		return
	for other_team_id in GameManager.all_team_ids():
		if other_team_id != team_id and _slot_options[other_team_id].selected == index:
			_slot_options[other_team_id].select(SlotChoice.EMPTY)


## Godot's toggle_mode Button already swaps between the "normal" and
## "pressed" theme styleboxes automatically based on button_pressed --
## green-for-on/neutral-for-off just needed those two styleboxes set, no
## manual per-toggle swapping. Same green Play's own button uses.
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


## Collapsed by default -- an always-visible wall of hotkey text read as
## a reference manual, not a menu. One click away, not deleted -- still
## useful once the input surface grows past "click to place, click to fight."
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


## A distinct fill color and larger size than Settings, so Play reads as
## the primary action instead of an equal-weight sibling.
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
	await _load_main_scene()


## Shared tail of both the local Play flow and the Host/Join multiplayer
## flow (_start_multiplayer_match() below) -- everything from
## apply_selection_to_menu_state() onward. Callers set up MenuSelection's
## fields themselves first (the local flow reads the lobby UI, the
## multiplayer flow sets a fixed 1v1 directly), since what belongs in
## MenuSelection differs enough between the two that a shared setup step
## would just be a pile of conditionals.
func _load_main_scene() -> void:
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


## D1 multiplayer plan, Phase D: a real UI to actually trigger
## NetworkSession.host()/join() -- until Phase C, the only thing that
## ever called those was tools/NetworkPlaytest.gd's headless test
## harness. Host-authoritative (user's explicit choice, not a two-way
## negotiation): once a peer connects, the HOST alone configures the
## existing 8-slot lobby panel below (_build_lobby_panel()) -- including
## a new SlotChoice.REMOTE marking which slot the connected peer plays --
## then clicks "Start Match" to serialize that config, broadcast it via
## LobbySync, and both sides load into the same match. The client only
## ever watches a status label and waits.
##
## Blood Tournament specifically, not Classic mode's default click-to-
## place, is force-enabled and locked once hosting: its roster/courtyard
## purchases already go through CommandQueue (Phase B) --
## PlayerInputController.try_place_unit() (Classic mode's own placement)
## calls GameManager.spawn_unit() directly and was never Command-wrapped,
## since Blood Tournament (uses_economy() == true) always skips that path.
const _DEFAULT_LAN_PORT := 7777

var _mp_ip_field: LineEdit
var _mp_status_label: Label
var _mp_host_button: Button
var _mp_join_button: Button
var _mp_start_button: Button
## True while a Host/Join attempt is actively waiting on a peer -- guards
## _await_peer() against a stray multiplayer.connection_failed signal
## firing after the wait already resolved some other way (e.g. the user
## backing out isn't offered here, but a late/duplicate signal still
## shouldn't double-fire the failure path).
var _mp_connecting: bool = false


func _build_multiplayer_card(parent: Control) -> void:
	var content := _wrap_in_card(parent, "Multiplayer (LAN)")

	var ip_row := HBoxContainer.new()
	ip_row.add_theme_constant_override("separation", 8)
	content.add_child(ip_row)

	var ip_label := Label.new()
	ip_label.text = "Host IP"
	ip_row.add_child(ip_label)

	_mp_ip_field = LineEdit.new()
	_mp_ip_field.text = "127.0.0.1"
	_mp_ip_field.custom_minimum_size = Vector2(140, 32)
	_mp_ip_field.placeholder_text = "Host IP to join"
	ip_row.add_child(_mp_ip_field)

	var button_row := HBoxContainer.new()
	button_row.add_theme_constant_override("separation", 8)
	content.add_child(button_row)

	_mp_host_button = Button.new()
	_mp_host_button.text = "Host"
	_mp_host_button.custom_minimum_size = Vector2(100, 36)
	_mp_host_button.pressed.connect(_on_host_pressed)
	button_row.add_child(_mp_host_button)

	_mp_join_button = Button.new()
	_mp_join_button.text = "Join"
	_mp_join_button.custom_minimum_size = Vector2(100, 36)
	_mp_join_button.pressed.connect(_on_join_pressed)
	button_row.add_child(_mp_join_button)

	# Hidden until the host has a connected peer -- see
	# _reveal_host_lobby_controls(). Never shown on the joining side.
	_mp_start_button = Button.new()
	_mp_start_button.text = "Start Match"
	_mp_start_button.custom_minimum_size = Vector2(220, 40)
	_mp_start_button.visible = false
	_mp_start_button.pressed.connect(_on_start_match_pressed)
	content.add_child(_mp_start_button)

	_mp_status_label = Label.new()
	_mp_status_label.text = "Host, or enter an IP above and Join"
	_mp_status_label.add_theme_color_override("font_color", Color(0.65, 0.65, 0.6))
	content.add_child(_mp_status_label)


func _on_host_pressed() -> void:
	Sfx.play_ui_click()
	_set_mp_controls_enabled(false)
	var err := NetworkSession.host(_DEFAULT_LAN_PORT)
	if err != OK:
		_mp_status_label.text = "Failed to host (error %d)" % err
		_set_mp_controls_enabled(true)
		return
	_mp_status_label.text = "Hosting on port %d -- waiting for opponent..." % _DEFAULT_LAN_PORT
	if not await _await_peer():
		return
	_mp_status_label.text = "Opponent connected -- mark their slot \"Remote\" below, then Start Match."
	_reveal_host_lobby_controls()


func _on_join_pressed() -> void:
	Sfx.play_ui_click()
	var ip := _mp_ip_field.text.strip_edges()
	if ip.is_empty():
		_mp_status_label.text = "Enter the host's IP first"
		return
	_set_mp_controls_enabled(false)
	var err := NetworkSession.join(ip, _DEFAULT_LAN_PORT)
	if err != OK:
		_mp_status_label.text = "Failed to connect (error %d)" % err
		_set_mp_controls_enabled(true)
		return
	_mp_status_label.text = "Connecting to %s..." % ip
	if not await _await_peer():
		return
	_mp_status_label.text = "Connected -- waiting for host to configure and start..."
	LobbySync.host_config_received.connect(_on_host_config_received, CONNECT_ONE_SHOT)


func _set_mp_controls_enabled(enabled: bool) -> void:
	_mp_host_button.disabled = not enabled
	_mp_join_button.disabled = not enabled
	_mp_ip_field.editable = enabled
	_play_button.disabled = not enabled


## Waits for NetworkSession.peer_ids to actually see the other side (or
## for Godot's own multiplayer.connection_failed to fire, on the joining
## side -- the host side never gets that signal, since create_server()
## either succeeds immediately or fails synchronously above, already
## handled). Returns whether it actually connected -- callers branch into
## the host-configures-and-starts flow or the client-waits-for-host flow
## from there, since what happens next differs completely between them.
func _await_peer() -> bool:
	_mp_connecting = true
	var failed := false
	var on_failed := func(): failed = true
	multiplayer.connection_failed.connect(on_failed, CONNECT_ONE_SHOT)

	while _mp_connecting and NetworkSession.peer_ids.is_empty() and not failed:
		await get_tree().process_frame

	_mp_connecting = false
	# CONNECT_ONE_SHOT auto-disconnects once fired -- is_connected() is
	# only still true here if the loop exited via peer_ids instead, in
	# which case it needs disconnecting manually so it can't fire later.
	if multiplayer.connection_failed.is_connected(on_failed):
		multiplayer.connection_failed.disconnect(on_failed)

	if failed:
		_mp_status_label.text = "Connection failed"
		NetworkSession.disconnect_session()
		_set_mp_controls_enabled(true)
		return false
	return true


## Forces Blood Tournament on and locks both mode toggles (multiplayer
## only supports BT, see this section's own doc comment), reveals the
## existing single-player lobby panel, and swaps in the Start Match
## button -- all host-only, never reached by a joining client.
## set_pressed_no_signal() is used (not .toggled.emit()/a real click) to
## avoid re-triggering Sfx/other listeners twice; every side effect the
## real toggled signal handler would have caused is replicated here by
## hand instead.
func _reveal_host_lobby_controls() -> void:
	_tournament_toggle.set_pressed_no_signal(true)
	_tournament_toggle.text = "Blood Tournament: On"
	_tournament_toggle.disabled = true
	_hero_footies_toggle.set_pressed_no_signal(false)
	_hero_footies_toggle.text = "Hero Footies: Off"
	_hero_footies_toggle.disabled = true
	_lobby_panel.visible = true
	_mp_start_button.visible = true


## team_id of the one row currently set to `choice`, or -1 if none is --
## used to find the host's own "You" slot and the connected peer's
## "Remote" slot when building the config to broadcast.
func _find_slot_choice(choice: SlotChoice) -> int:
	for team_id in GameManager.all_team_ids():
		if _slot_options[team_id].selected == choice:
			return team_id
	return -1


func _on_start_match_pressed() -> void:
	var host_team_id := _find_slot_choice(SlotChoice.YOU)
	var remote_team_id := _find_slot_choice(SlotChoice.REMOTE)
	if host_team_id == -1:
		_mp_status_label.text = "Mark exactly one slot \"You\" before starting"
		return
	if remote_team_id == -1:
		_mp_status_label.text = "Mark exactly one slot \"Remote\" before starting"
		return
	Sfx.play_ui_click()
	var config := _build_host_config(host_team_id, remote_team_id)
	LobbySync.broadcast_host_config(config)
	_apply_synced_config(config, host_team_id)
	await _load_main_scene()


func _on_host_config_received(config: Dictionary) -> void:
	_mp_status_label.text = "Starting match..."
	_apply_synced_config(config, int(config["remote_team_id"]))
	await _load_main_scene()


## RPC-safe primitives only (ints/arrays/dictionaries), same
## resource_path-not-raw-Resource reasoning Command.to_dict() already
## established for unit_stats/upgrade -- faction picks go over the wire
## as an index into FactionRegistry.ALL, not the Faction resource itself.
func _build_host_config(host_team_id: int, remote_team_id: int) -> Dictionary:
	var bot_team_ids: Array = []
	var faction_indices := {}
	for team_id in GameManager.all_team_ids():
		if _slot_options[team_id].selected == SlotChoice.BOT:
			bot_team_ids.append(team_id)
		var faction_id: int = _faction_options[team_id].get_selected_id()
		if faction_id > 0:
			faction_indices[team_id] = faction_id - 1
	return {
		"host_team_id": host_team_id,
		"remote_team_id": remote_team_id,
		"bot_team_ids": bot_team_ids,
		"faction_indices": faction_indices,
	}


## Shared by both the host (applying its own just-broadcast config) and
## the client (applying what it just received) -- `own_team_id` is the
## one difference between them (host_team_id vs remote_team_id).
## Main._apply_menu_selection() needs no changes at all to consume this;
## every field here already exists and is read exactly this way for the
## single-player lobby (active_team_ids specifically was added this
## session for the earlier fixed-1v1 LAN flow this replaces).
func _apply_synced_config(config: Dictionary, own_team_id: int) -> void:
	MenuSelection.start_with_tournament = true
	MenuSelection.human_team_id = own_team_id

	var bot_team_ids: Array[int] = []
	for id in config["bot_team_ids"]:
		bot_team_ids.append(int(id))
	MenuSelection.bot_team_ids = bot_team_ids

	MenuSelection.chosen_factions.clear()
	var faction_indices: Dictionary = config["faction_indices"]
	for team_id in faction_indices:
		MenuSelection.chosen_factions[int(team_id)] = FactionRegistry.ALL[int(faction_indices[team_id])]

	var active_team_ids: Array[int] = [int(config["host_team_id"]), int(config["remote_team_id"])]
	for id in bot_team_ids:
		active_team_ids.append(id)
	MenuSelection.active_team_ids = active_team_ids
