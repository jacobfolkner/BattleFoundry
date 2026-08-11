## Root controller for the prototype scene.
##
## Owns the arena (build/toggle only -- the shapes themselves live in
## Scripts/Maps/ArenaMap.gd and subclasses) and wires input, HUD, and Blood
## Tournament round orchestration together. Actual input handling is
## Scripts/Core/PlayerInputController.gd's job (_input below) -- this class
## forwards events/calls to it and keeps a handful of same-named
## delegate methods so every existing "private" test call site
## (_main._try_place_unit(), etc.) keeps working unchanged. Main.gd
## otherwise knows nothing about selection bookkeeping, debug UI, or the
## camera (self-managed by Scripts/Core/OrbitCamera.gd) -- that's the whole
## point of routing through those rather than handling it here.
extends Node3D

@onready var _camera: Camera3D = $Camera3D
@onready var _units_container: Node3D = $UnitsContainer
@onready var _hud: Control = $HUDLayer/HUD

## Constructed in _ready() (needs _camera/_hud, which are @onready) --
## owns selected_stats/selected_player/dragging_unit/pending_ability_target,
## which several of Main's own non-input methods (_refresh_gold_display(),
## _on_ai_opponent_toggled(), _apply_menu_selection()) still need to
## read/write -- see the forwarding properties right below this for how
## those keep working without every caller needing an `_input.` prefix.
var _input: PlayerInputController

## Forwarding properties, not plain fields -- selected_stats/dragging_unit/
## pending_ability_target genuinely live on _input now (PlayerInputController.gd),
## but several tests still read/write _main._selected_stats/_dragging_unit/
## _pending_ability_target directly, and Main's own non-input code
## (_refresh_gold_display(), etc.) still reads _selected_player constantly.
## Godot's property syntax lets both keep working unchanged.
var _selected_stats: UnitStats:
	get: return _input.selected_stats
	set(value): _input.selected_stats = value
var _selected_player: Player:
	get: return _input.selected_player
	set(value): _input.selected_player = value
var _dragging_unit: Unit:
	get: return _input.dragging_unit
	set(value): _input.dragging_unit = value
var _drag_source_squad_index: int:
	get: return _input._drag_source_squad_index
	set(value): _input._drag_source_squad_index = value
var _pending_ability_target: int:
	get: return _input.pending_ability_target
	set(value): _input.pending_ability_target = value
var _pending_patrol: bool:
	get: return _input.pending_patrol
	set(value): _input.pending_patrol = value

## Constructed unconditionally in _ready(), like _input -- see
## Scripts/BloodTournament/BloodTournamentController.gd's own class doc comment for why
## this exists regardless of whether Blood Tournament is actually active
## (several tests poke its state directly without ever "activating" a
## tournament at all).
var _bt_controller: BloodTournamentController

## Forwarding properties to _bt_controller, same reasoning/pattern as
## _selected_stats/etc. above -- _tournament_mode in particular is set
## directly by several tests (bypassing _on_tournament_toggled() entirely),
## and _round_spawn_points is read/written directly by a couple more.
var _tournament_mode: BloodTournamentMode:
	get: return _bt_controller.mode
	set(value): _bt_controller.mode = value
var _round_spawn_points: Dictionary:
	get: return _bt_controller.round_spawn_points
	set(value): _bt_controller.round_spawn_points = value


func _ready() -> void:
	GameManager.units_container = _units_container
	GameManager.battle_ended.connect(_hud.show_winner)
	GameManager.battle_started.connect(_begin_staggered_deployment)
	var placement_ghost := PlacementGhost.new()
	_units_container.add_child(placement_ghost)
	_input = PlayerInputController.new(_camera, _hud, _refresh_gold_display, placement_ghost)
	_bt_controller = BloodTournamentController.new(_hud, _refresh_gold_display)
	SelectionManager.local_player = _selected_player # keep in sync with the default team panel toggle
	_build_arenas()

	_hud.unit_type_selected.connect(_on_unit_type_selected)
	_hud.team_selected.connect(_on_team_selected)
	_hud.start_battle_pressed.connect(_on_start_battle_pressed)
	_hud.ai_opponent_toggled.connect(_on_ai_opponent_toggled)
	_hud.ability_slot_pressed.connect(_try_cast_or_target)
	_hud.roster_slot_sold.connect(_on_roster_slot_sold)
	_hud.hero_ability_picked.connect(_on_hero_ability_picked)
	_hud.gold_exchange_requested.connect(_on_gold_exchange_requested)
	_hud.blood_exchange_requested.connect(_on_blood_exchange_requested)
	_hud.sell_requested.connect(_on_sell_requested)
	# HUD only ever displays whichever unit SelectionManager reports as
	# selected -- it never reads SelectionManager itself (see HUD.gd's own
	# doc comment on staying decoupled from selection/battle-lifecycle
	# internals), so this is the one bridge that tells it who to track for
	# the ability hotbar/buff row (UI/HUD.gd's track_unit()).
	SelectionManager.selection_changed.connect(_on_selection_changed)

	_apply_menu_selection()


func _on_selection_changed(units: Array[Unit]) -> void:
	_hud.track_unit(units[0] if not units.is_empty() else null)


## Consumes (and immediately clears) MenuSelection's fields -- UI/MainMenu.gd
## sets these right before changing to this scene. Clearing them here, not
## just reading them, makes this a true one-shot hand-off: if this scene
## is ever entered again without going back through the menu (a GUT test
## loading it directly, almost always), nothing carries over silently --
## MenuSelection is an autoload, so its state would otherwise survive a
## scene change (or a whole test suite run) untouched.
func _apply_menu_selection() -> void:
	var tournament := MenuSelection.start_with_tournament
	var hero_footies := MenuSelection.start_with_hero_footies
	var human_team_id := MenuSelection.human_team_id
	var bot_team_ids := MenuSelection.bot_team_ids.duplicate()
	var chosen_faction := MenuSelection.chosen_faction
	MenuSelection.start_with_tournament = false
	MenuSelection.start_with_hero_footies = false
	MenuSelection.human_team_id = GameManager.BLUE_TEAM_ID
	MenuSelection.bot_team_ids.clear()
	MenuSelection.chosen_faction = null

	_on_team_selected(human_team_id) # harmless no-op when this is already the default (Blue)

	# AI first: _on_tournament_toggled(true)'s own tail call to
	# _run_ai_turn_if_needed() only does anything once every other team is
	# already non-human, so this order lets round 1 auto-populate
	# immediately rather than needing a second, redundant check.
	#
	# The human's own team plus every explicitly-chosen bot slot become
	# the active roster for this match (UI/MainMenu.gd's per-slot lobby --
	# "You"/"Bot"/"Empty" per team, any number of Bots). Left empty
	# (meaning "every registered team," see BloodTournamentMode.active_team_ids'
	# own doc comment) when no bots were picked at all -- a plain "Blood
	# Tournament: On" with an empty lobby keeps its original, pre-lobby
	# behavior (every registered team funded/playing). Every slot NOT
	# explicitly marked Bot stays is_human == true (its existing default),
	# including "Empty" slots -- an empty slot never gets funded (outside
	# active_team_ids) so it simply never plays, is_human is irrelevant
	# for it either way.
	var active_team_ids: Array = []
	if not bot_team_ids.is_empty():
		active_team_ids = [human_team_id] + bot_team_ids
		for team_id in GameManager.all_team_ids():
			GameManager.get_player(team_id).is_human = not bot_team_ids.has(team_id)
	if tournament:
		# Race only means anything under Blood Tournament (the one mode
		# with a shop) -- gated here, not unconditionally above, since
		# every OTHER test/scenario that loads Main.tscn (the large
		# majority, classic mode by default) would otherwise get a random
		# Player.faction assigned whether it asked for one or not. That
		# already broke several AIController tests that assume a specific
		# archetype's cost is affordable regardless of faction -- Player is
		## a persistent RefCounted (same category of cross-test-pollution
		## risk already on file for is_human/resources/current_mode), so an
		## assignment here has to be genuinely conditional, not just
		## "harmless," to avoid reintroducing that lesson via randomness
		## instead of leftover state.
		#
		# Every team gets a race, not just whoever ends up playing this
		# match -- cheaper than threading active_team_ids through this too,
		# and harmless for a team that never plays. The human's own slot
		# gets the lobby's pick (or a random one if left on "Random");
		# every other slot (bots included) always gets a random race --
		# there's no per-bot picker. Assigned before _on_tournament_toggled()
		# runs, not after, since its own tail call is what actually runs
		# the AI's first turn -- AIController needs Player.faction to
		# already be set the moment it buys.
		for team_id in GameManager.all_team_ids():
			var player := GameManager.get_player(team_id)
			player.faction = chosen_faction if (team_id == human_team_id and chosen_faction != null) else FactionRegistry.random_pick()
		_hud.refresh_unit_panel_for_faction(GameManager.get_player(human_team_id).faction)
		_on_tournament_toggled(true, active_team_ids) # its own tail call to _run_ai_turn_if_needed() is what actually runs the AI's first turn
	elif hero_footies:
		_on_hero_footies_toggled(true)


## Kept for backward compat (AIController and several tests read this
## directly) -- the real source of truth is now CrossArenaMap.SPAWN_POINTS
## (Scripts/Maps/CrossArenaMap.gd), referenced here rather than duplicated
## (GDScript resolves another class's const at compile time, same
## pattern MenuSelection.human_team_id's own default already uses for
## GameManager.BLUE_TEAM_ID).
const ARM_SPAWN_POINTS: Array[Vector3] = CrossArenaMap.SPAWN_POINTS

@onready var _ground: Node3D = $Ground
var _square_map := SquareArenaMap.new()
var _cross_map := CrossArenaMap.new()


## Builds both arena maps once up front (ground meshes + navmesh) and
## leaves only the one GameManager.current_mode.get_arena_map() actually
## wants enabled/visible -- see _sync_arena_shape(), the only thing that
## needs to run again on a mode swap. Building both up front (rather than
## freeing and rebuilding nodes on every toggle) means toggling Blood
## Tournament on and off never risks leaking/duplicating navigation
## regions. Hardcodes exactly these two concrete ArenaMap classes here
## (not derived generically from every possible GameMode) since building
## requires real scene-tree parents (this node, _ground) only Main.gd
## has -- a third map shape would need one more line here, still no
## per-shape branching anywhere else (see _sync_arena_shape()).
func _build_arenas() -> void:
	_square_map.build(self, _ground)
	_cross_map.build(self, _ground)
	_sync_arena_shape()


## The only thing that needs to run again after _build_arenas() -- called
## once there, and again from _on_tournament_toggled()/_apply_menu_selection()
## whenever GameManager.current_mode actually changes. Disabling (not
## freeing) the inactive map's NavigationRegion3D fully excludes its
## navmesh from the navigation map, so the two shapes never interfere
## with each other's pathfinding. Matches by the class of whatever
## ArenaMap instance current_mode.get_arena_map() returns -- a throwaway
## instance just for the type check (cheap, RefCounted, never added to
## the scene tree), not the same object _square_map/_cross_map already
## built.
func _sync_arena_shape() -> void:
	var active_map := GameManager.current_mode.get_arena_map()
	_square_map.set_active(active_map is SquareArenaMap)
	_cross_map.set_active(active_map is CrossArenaMap)


## Swaps GameManager.current_mode between ClassicEliminationMode (the
## default single-battle behavior) and a fresh BloodTournamentMode.
## GameManager.set_mode() already resets to PLACEMENT, so this just also
## resyncs the HUD (winner banner/Start button) to match.
##
## active_team_ids (plain Array, see BloodTournamentMode.active_team_ids'
## own doc comment) restricts which of the 8 registered teams actually
## get starting gold -- empty (default) means every registered team,
## unchanged for the in-game HUD toggle's own direct signal connection
## (which only ever passes the bool) and every existing test. Only
## Main._apply_menu_selection() passes a real, possibly-smaller list, for
## the "2 to 8 teams, fill some or all remaining slots with bots" setup
## choice. Must be set on the mode BEFORE GameManager.set_mode() runs --
## that's what triggers on_activated()'s starting-gold grant, which reads
## it.
func _on_tournament_toggled(enabled: bool, active_team_ids: Array = []) -> void:
	if enabled:
		# 12 -- the genre-accurate fixed match length (see
		# BloodTournamentMode.total_rounds' own doc comment): every round
		# is played through regardless of standings, boss rounds included
		# (is_boss_round() lands on 3/6/9/12 either way). rounds_to_win (2)
		# is otherwise unused once total_rounds > 0, kept at its default.
		_tournament_mode = BloodTournamentMode.new(2, 12)
		_tournament_mode.active_team_ids = active_team_ids
		_tournament_mode.round_ended.connect(_bt_controller.on_round_ended)
		_tournament_mode.all_rounds_finished.connect(_bt_controller.on_all_rounds_finished)
		GameManager.set_mode(_tournament_mode) # grants starting gold via BloodTournamentMode.on_activated()
		_bt_controller.assign_random_spawn_points()
	else:
		_tournament_mode = null
		GameManager.set_mode(ClassicEliminationMode.new())
	_sync_arena_shape()
	_hud.reset_for_new_round()
	_hud.hide_tournament_score()
	_hud.refresh_match_toggles_visibility() # Blue/Red/AI-toggle visibility -- see its own doc comment
	_refresh_gold_display()
	_run_ai_turn_if_needed()


## Connected to HUD's Start Battle button instead of GameManager.start_battle()
## directly, so BloodTournamentController can intercept a goblin boss
## round and hand it to GoblinBossRound's own team-by-team sequencing
## instead of one normal simultaneous PvP battle. Every other mode/round
## just calls GameManager.start_battle() exactly as before -- see
## BloodTournamentController.start_battle_pressed(), which this always
## delegates to regardless of whether Blood Tournament is even active
## (mode == null there is the classic-mode/no-tournament case).
func _on_start_battle_pressed() -> void:
	_bt_controller.start_battle_pressed()


## Red's Player.is_human flips to match -- AIController.take_turn() (see
## BloodTournamentController.run_ai_turn_if_needed()) is the only other
## thing that ever checks it. Forces the human back to Blue if they
## happened to be playing Red when AI takes it over -- HUD._on_ai_toggled()
## already disabled that button, this is the matching GameManager/
## SelectionManager-side half.
func _on_ai_opponent_toggled(enabled: bool) -> void:
	GameManager.get_player(GameManager.RED_TEAM_ID).is_human = not enabled
	if enabled:
		_selected_player = GameManager.get_player(GameManager.BLUE_TEAM_ID)
		SelectionManager.local_player = _selected_player
	_run_ai_turn_if_needed()


func _run_ai_turn_if_needed() -> void:
	_bt_controller.run_ai_turn_if_needed()


## Swaps GameManager.current_mode between ClassicEliminationMode and a
## fresh HeroFootiesMode (roadmap Phase 6 -- wave-spawner + throne-HP win
## condition). Mutually exclusive with Blood Tournament -- both claim
## GameManager.current_mode, so turning this on while a tournament is
## active clears Main._tournament_mode too (GameManager.set_mode() below
## already overwrites current_mode itself either way).
func _on_hero_footies_toggled(enabled: bool) -> void:
	if enabled:
		_tournament_mode = null
		GameManager.set_mode(HeroFootiesMode.new())
	else:
		GameManager.set_mode(ClassicEliminationMode.new())
	_sync_arena_shape()
	_hud.reset_for_new_round()
	_hud.refresh_match_toggles_visibility()
	_refresh_gold_display()


func _scoreboard_text() -> String:
	return _bt_controller.scoreboard_text()


func _assign_random_spawn_points() -> void:
	_bt_controller.assign_random_spawn_points()


func _begin_staggered_deployment() -> void:
	_bt_controller.begin_march()
	_focus_camera_on_local_battle()


## Blood Tournament's default camera framing centers on the map origin at
## a zoom tuned for the older, smaller square arena -- against the cross
## map's larger reach that leaves the actual fight a tiny cluster near
## the frame's edge (usability review, 2026-08-11). Recenter+zoom onto
## the local human player's own arm anchor the instant marching starts,
## since that's where their fight actually happens first -- the player
## can still freely re-orbit/zoom afterward, this only sets where the
## camera starts looking. A no-op outside the cross map (classic mode's
## square arena already fits the default framing) or with no local human
## player (AI-vs-AI/dev scenarios).
func _focus_camera_on_local_battle() -> void:
	if not GameManager.current_mode.uses_cross_map():
		return
	var local_player := SelectionManager.local_player
	if local_player == null:
		return
	var anchor: Vector3 = _round_spawn_points.get(local_player.team_id, CrossArenaMap.SPAWN_POINTS[local_player.team_id])
	(_camera as OrbitCamera).focus_and_zoom(anchor, 16.0)


func _physics_process(delta: float) -> void:
	GameManager.current_mode.tick(delta) # no-op for every mode but HeroFootiesMode (see GameMode.tick()'s own doc comment)


## Shows Blue/Red's current gold and blood points whenever
## current_mode.uses_economy() is true, hides it otherwise -- self-deciding
## on every call (rather than the caller tracking on/off) so every
## spend/refund/income/kill call site can just call this without also
## branching on mode type itself.
func _refresh_gold_display() -> void:
	var use_gold := GameManager.current_mode.uses_economy()
	if use_gold:
		var blue := GameManager.get_player(GameManager.BLUE_TEAM_ID)
		var red := GameManager.get_player(GameManager.RED_TEAM_ID)
		_hud.show_gold(blue.resources, red.resources, blue.blood_points, red.blood_points)
		_hud.refresh_roster_row(_selected_player.roster)
	else:
		_hud.hide_gold()
		# _hud is typed as plain Control (see its @onready declaration), so this
		# call dispatches dynamically -- a bare [] literal has no static context
		# to become Array[UnitStats] and fails HUD.refresh_roster_row()'s typed
		# parameter at runtime. A typed local variable carries its own runtime
		# type tag, unlike a fresh [] literal (Player.roster itself doesn't
		# need this -- it's already a real typed-array value, not a literal).
		var empty_roster: Array[UnitStats] = []
		_hud.refresh_roster_row(empty_roster)
	_hud.refresh_hero_draft_panel(_selected_player) # self-hides (empty panel) when the roster has no hero with a drafted slot -- roster is always empty outside Blood Tournament anyway
	_hud.refresh_affordability(_selected_player)


## Connected to HUD's roster line-up row (see UI/HUD.gd) -- clicking a
## slot there sells it (GameManager.sell_roster_slot()) instead of the
## old right-click-a-live-unit flow (_try_sell_unit_at()), since nothing
## is live to click during PLACEMENT anymore under the staggered-deployment
## model.
func _on_roster_slot_sold(index: int) -> void:
	if GameManager.sell_roster_slot(_selected_player, index):
		_refresh_gold_display()


func _on_hero_ability_picked(stats: UnitStats, slot_index: int, chosen_index: int) -> void:
	if GameManager.pick_hero_ability(_selected_player, stats, slot_index, chosen_index):
		_refresh_gold_display()


func _on_gold_exchange_requested() -> void:
	if _selected_player.exchange_gold_for_blood_points():
		_refresh_gold_display()


func _on_blood_exchange_requested() -> void:
	if _selected_player.exchange_blood_points_for_gold():
		_refresh_gold_display()


## HUD's Sell button (see UI/HUD.gd's sell_requested signal) has no
## payload -- it always refers to whichever unit SelectionManager
## currently reports selected, the same source HUD's own track_unit()/
## _tracked_unit already reflects for the button's own visibility.
func _on_sell_requested() -> void:
	if SelectionManager.selected_units.is_empty():
		return
	_input.try_sell_unit(SelectionManager.selected_units[0])


## Actual input handling lives in Scripts/Core/PlayerInputController.gd (_input)
## -- every method below is a thin one-line delegate, kept under these
## exact names because several test files call them directly
## (_main._try_place_unit(), etc.) and HUD connects a few of them as
## signal handlers (_on_unit_type_selected, _on_team_selected,
## _try_cast_or_target -- see _ready()).
func _unhandled_input(event: InputEvent) -> void:
	_input.handle(event)


func _handle_mouse_button(event: InputEventMouseButton) -> void:
	_input.handle_mouse_button(event)


func _handle_mouse_motion(event: InputEventMouseMotion) -> void:
	_input.handle_mouse_motion(event)


func _on_left_release(event: InputEventMouseButton) -> void:
	_input.on_left_release(event)


func _on_right_click(event: InputEventMouseButton) -> void:
	_input.on_right_click(event)


func _handle_key(event: InputEventKey) -> void:
	_input.handle_key(event)


func _try_cast_or_target(index: int) -> void:
	_input.try_cast_or_target(index)


func _resolve_pending_ability_target(screen_position: Vector2) -> void:
	_input.resolve_pending_ability_target(screen_position)


func _cancel_pending_ability_target() -> void:
	_input.cancel_pending_ability_target()


func _begin_patrol_targeting() -> void:
	_input.begin_patrol_targeting()


func _resolve_pending_patrol(screen_position: Vector2) -> void:
	_input.resolve_pending_patrol(screen_position)


func _cancel_pending_patrol() -> void:
	_input.cancel_pending_patrol()


func _handle_placement_key(event: InputEventKey) -> void:
	_input.handle_placement_key(event)


func _try_start_unit_drag(screen_position: Vector2) -> void:
	_input.try_start_unit_drag(screen_position)


func _drag_unit_to(screen_position: Vector2) -> void:
	_input.drag_unit_to(screen_position)


func _try_place_unit(screen_position: Vector2) -> void:
	_input.try_place_unit(screen_position)


func _try_sell_unit_at(screen_position: Vector2) -> void:
	_input.try_sell_unit_at(screen_position)


## Thin delegate for the full left-click-release resolution path
## (selection / Builder build-menu / placement / deselect -- see
## PlayerInputController.on_left_release()) -- exists so callers (tests)
## don't need to reach `_input.on_left_release()` directly, which resolves
## to Node's own built-in _input(event) virtual instead of this field when
## accessed through a generically-typed reference (see CLAUDE.md's
## documented `_input` naming gotcha).
func _try_left_click_at(screen_position: Vector2) -> void:
	var event := InputEventMouseButton.new()
	event.button_index = MOUSE_BUTTON_LEFT
	event.pressed = false
	event.position = screen_position
	_input.on_left_release(event)


func _on_unit_type_selected(stats: UnitStats) -> void:
	_input.on_unit_type_selected(stats)


## Thin delegate for simulating cursor movement (see
## PlayerInputController.handle_mouse_motion()) -- same `_input` naming
## gotcha as _try_left_click_at() above, avoided the same way. `held`
## simulates the left button still being down during the move (needed to
## cross handle_mouse_motion()'s own click-vs-drag distance threshold for
## a courtyard-squad drag test) -- false by default since the
## build-placement ghost path this originally existed for doesn't check
## button_mask at all.
func _try_move_mouse_to(screen_position: Vector2, held: bool = false) -> void:
	var event := InputEventMouseMotion.new()
	event.position = screen_position
	if held:
		event.button_mask = MOUSE_BUTTON_MASK_LEFT
	_input.handle_mouse_motion(event)


## Test-only accessors for the ghost-placement flow's otherwise-private
## state -- same `_input`/`_ghost` reach-through gotcha, avoided by living
## on Main.gd itself (a statically-typed `self`, not a generic reference).
func _is_build_placement_armed() -> bool:
	return _input._pending_build_stats != null


func _placement_ghost_visible() -> bool:
	return _input._ghost.visible


func _placement_ghost_position() -> Vector3:
	return _input._ghost.global_position


func _placement_ghost_is_tinted_invalid() -> bool:
	return _input._ghost._material.albedo_color == PlacementGhost._INVALID_COLOR


## Thin delegates for simulating a right-click / key-press, same `_input`
## naming gotcha as _try_left_click_at()/_try_move_mouse_to() above,
## avoided the same way.
func _try_right_press_at(screen_position: Vector2) -> void:
	var event := InputEventMouseButton.new()
	event.button_index = MOUSE_BUTTON_RIGHT
	event.pressed = true
	event.position = screen_position
	_input.handle_mouse_button(event)


func _try_press_key(keycode: Key) -> void:
	var event := InputEventKey.new()
	event.keycode = keycode
	event.pressed = true
	_input.handle_key(event)


func _on_team_selected(team_id: int) -> void:
	_input.on_team_selected(team_id)
