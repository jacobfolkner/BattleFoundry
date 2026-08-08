## Root controller for the prototype scene.
##
## Owns the arena and turns mouse/keyboard input into the right action for
## the current battle_state: unit placement during PLACEMENT, and
## selection/order-issuing (SelectionManager, Scripts/SelectionManager.gd)
## during BATTLE. A click first gets offered to DebugInspector
## (Scripts/DebugInspector.gd) in case it landed on a unit; only an
## unclaimed click can place one or fall through to a box-select/deselect.
## Main.gd otherwise knows nothing about selection bookkeeping, debug UI,
## or the camera (self-managed by Scripts/OrbitCamera.gd) -- that's the
## whole point of routing through those rather than handling it here.
extends Node3D

const GROUND_PLANE := Plane(Vector3.UP, 0.0)
## Screen pixels the mouse must move past _left_drag_start before a
## left-button hold counts as a box-select drag instead of a click --
## without this, every click (which always jitters a pixel or two) would
## register as a zero-size drag and skip the click-handling path entirely.
const _DRAG_THRESHOLD := 6.0
## Must match whichever unit-type button HUD._build_unit_panel() starts
## toggled on ("Tank"). HUD._ready() emits its default selection too, but
## Godot calls a child's _ready() (HUD's) before its parent's (this
## node's) -- by the time this connects unit_type_selected below, that
## first emit already fired into the void. Godot's actual startup order
## confirmed this races for real (not just in theory): see
## _selected_player's comment for the identical bug this one shipped
## alongside, caught by a user hitting it directly rather than by any
## automated test, since none exercised the real click-to-place path.
const _DEFAULT_UNIT_STATS: UnitStats = preload("res://Resources/Units/TankStats.tres")
## Index 0/1 map to the U/I hotkeys (see _handle_placement_key()) --
## deliberately just two, "prove the shop-side flow" per the roadmap, not
## a real shop UI/browse list.
const _UPGRADES: Array[UnitUpgrade] = [
	preload("res://Resources/Upgrades/IronArmorUpgrade.tres"),
	preload("res://Resources/Upgrades/WhetstoneUpgrade.tres"),
]

@onready var _camera: Camera3D = $Camera3D
@onready var _units_container: Node3D = $UnitsContainer
@onready var _hud: Control = $HUDLayer/HUD

var _selected_stats: UnitStats
## Set in _ready(), not a field initializer -- a field initializer runs
## at this node's construction time, which is not guaranteed to be after
## GameManager._ready() has populated its player registry (confirmed to
## actually race in a real project run, not just a theoretical concern --
## see SelectionManager.local_player's doc comment for the same fix).
var _selected_player: Player

var _left_drag_start: Vector2 = Vector2.ZERO
var _is_left_dragging: bool = false

## Non-null only while PLACEMENT's left-mouse-down landed on a unit
## _selected_player already owns -- lets it be repositioned instead of
## only ever placing a brand-new unit on click. See
## _try_start_unit_drag()/_drag_unit_to(). Only ever finds anything under
## classic mode now: Blood Tournament's roster (Player.roster) isn't
## spawned as live Units during PLACEMENT anymore (see
## _on_unit_type_selected()/_begin_staggered_deployment()), so there's
## nothing on the field to drag until BATTLE actually starts.
var _dragging_unit: Unit = null

## Non-null only while the HUD's Blood Tournament toggle is on -- see
## _on_tournament_toggled(). Holding the reference here (not just reading
## it back off GameManager.current_mode) is what lets _on_tournament_round_ended()
## read BloodTournamentMode-specific state (get_wins(), is_match_over())
## without every caller needing to cast/check GameManager.current_mode's type.
var _tournament_mode: BloodTournamentMode = null

var _ai := AIController.new()

## Non-null only while a goblin boss round's team-by-team sequence is
## actually running (see _on_start_battle_pressed()/GoblinBossRound's own
## class doc comment) -- a fresh instance every boss round, discarded once
## boss_round_finished fires.
var _boss_round: GoblinBossRound = null

## Non-null only while the final tournament bracket is actually running
## (see _on_all_rounds_finished()/FinalTournamentBracket's own class doc
## comment) -- one instance for the whole bracket (unlike _boss_round,
## which is one per boss round), discarded once champion_decided fires.
var _bracket: FinalTournamentBracket = null

## -1 means no ability is awaiting a target. Set only for a UNIT_TARGET
## ability slot (see _try_cast_or_target()) -- the next left-click resolves
## it (_resolve_pending_ability_target()); right-click or Escape cancels.
var _pending_ability_target: int = -1


func _ready() -> void:
	GameManager.units_container = _units_container
	GameManager.battle_ended.connect(_hud.show_winner)
	GameManager.battle_started.connect(_begin_staggered_deployment)
	_selected_player = GameManager.get_player(GameManager.BLUE_TEAM_ID)
	_selected_stats = _DEFAULT_UNIT_STATS
	SelectionManager.local_player = _selected_player # keep in sync with the default team panel toggle
	_build_arenas()

	_hud.unit_type_selected.connect(_on_unit_type_selected)
	_hud.team_selected.connect(_on_team_selected)
	_hud.start_battle_pressed.connect(_on_start_battle_pressed)
	_hud.tournament_mode_toggled.connect(_on_tournament_toggled)
	_hud.ai_opponent_toggled.connect(_on_ai_opponent_toggled)
	_hud.ability_slot_pressed.connect(_try_cast_or_target)
	_hud.roster_slot_sold.connect(_on_roster_slot_sold)
	# HUD only ever displays whichever unit SelectionManager reports as
	# selected -- it never reads SelectionManager itself (see HUD.gd's own
	# doc comment on staying decoupled from selection/battle-lifecycle
	# internals), so this is the one bridge that tells it who to track for
	# the ability hotbar/buff row (UI/HUD.gd's track_unit()).
	SelectionManager.selection_changed.connect(_on_selection_changed)

	_apply_menu_selection()


func _on_selection_changed(units: Array[Unit]) -> void:
	_hud.track_unit(units[0] if not units.is_empty() else null)


## Consumes (and immediately clears) MenuSelection's two flags -- UI/MainMenu.gd
## sets these right before changing to this scene. Clearing them here, not
## just reading them, makes this a true one-shot hand-off: if this scene
## is ever entered again without going back through the menu (a GUT test
## loading it directly, almost always), nothing carries over silently --
## MenuSelection is an autoload, so its state would otherwise survive a
## scene change (or a whole test suite run) untouched.
func _apply_menu_selection() -> void:
	var tournament := MenuSelection.start_with_tournament
	var ai_opponent := MenuSelection.start_with_ai_opponent
	MenuSelection.start_with_tournament = false
	MenuSelection.start_with_ai_opponent = false

	# AI first: _on_tournament_toggled(true)'s own tail call to
	# _run_ai_turn_if_needed() only does anything once Red.is_human is
	# already false, so this order lets round 1 auto-populate immediately
	# rather than needing the (harmless, but redundant) second check
	# _on_ai_opponent_toggled() would otherwise trigger if done second.
	if ai_opponent:
		_hud.set_ai_toggle(true)
	if tournament:
		_hud.set_tournament_toggle(true)


## team_id -> spawn anchor, near the outer edge of one of the cross map's
## 4 arms (2 team_ids per arm) -- see _build_cross_arena(). Used by
## Main._try_place_unit() to offer a sensible default and by AIController
## to place a team's units on its own side rather than the map center.
const ARM_SPAWN_POINTS: Array[Vector3] = [
	Vector3(-4, 0, -26), # 0 Blue -- North arm, west half
	Vector3(4, 0, -26),  # 1 Red -- North arm, east half
	Vector3(26, 0, -4),  # 2 Green -- East arm, north half
	Vector3(26, 0, 4),   # 3 Yellow -- East arm, south half
	Vector3(4, 0, 26),   # 4 Purple -- South arm, east half
	Vector3(-4, 0, 26),  # 5 Orange -- South arm, west half
	Vector3(-26, 0, 4),  # 6 Cyan -- West arm, south half
	Vector3(-26, 0, -4), # 7 Magenta -- West arm, north half
]

@onready var _ground: Node3D = $Ground
var _square_nav_region: NavigationRegion3D
var _cross_nav_region: NavigationRegion3D
var _square_ground_pieces: Array[MeshInstance3D] = []
var _cross_ground_pieces: Array[MeshInstance3D] = []


## Builds both arena shapes once up front (ground meshes + navmesh) and
## leaves only the one GameManager.current_mode.uses_cross_map() actually
## wants enabled/visible -- see _sync_arena_shape(), the only thing that
## needs to run again on a mode swap. Building both up front (rather than
## freeing and rebuilding nodes on every toggle) means toggling Blood
## Tournament on and off never risks leaking/duplicating navigation
## regions.
func _build_arenas() -> void:
	_build_square_arena()
	_build_cross_arena()
	_sync_arena_shape()


## The default 40x40 flat square -- exactly what every pre-cross-map test
## and ClassicEliminationMode still assume. A single open rectangle,
## authored directly (NavigationMesh.vertices/add_polygon()) rather than
## baked from Ground's geometry -- deterministic and instant, and there's
## nothing to bake around: this shared arena has no static obstacles (see
## tests/test_pathfinding.gd for a *baked* NavigationMesh with a real
## wall to route around, built in an isolated scene rather than here,
## since a shared obstacle here would sit in the footsteps of dozens of
## existing tests that spawn/path units anywhere in the 40x40 plane,
## corners included). Units path against this via
## Unit._seek_position()/get_next_path_position() -- see its doc comment
## for why that's an actual navmesh query now, not just a straight-line
## direction fed to avoidance the way it was before this existed.
func _build_square_arena() -> void:
	var half := GameManager.ARENA_HALF_EXTENT
	var nav_mesh := NavigationMesh.new()
	nav_mesh.vertices = PackedVector3Array([
		Vector3(-half, 0, -half),
		Vector3(half, 0, -half),
		Vector3(half, 0, half),
		Vector3(-half, 0, half),
	])
	nav_mesh.add_polygon(PackedInt32Array([0, 1, 2, 3]))

	_square_nav_region = NavigationRegion3D.new()
	_square_nav_region.navigation_mesh = nav_mesh
	add_child(_square_nav_region)

	_square_ground_pieces.append(_build_ground_piece(Vector2(half * 2.0, half * 2.0), Vector3.ZERO))


## The 8-team Blood Tournament map: a square center plus 4 arms of the
## same width extending outward, one per cardinal direction (see
## ARM_SPAWN_POINTS for where each team starts). Hand-authored as 5
## quads sharing vertex indices at the center/arm junctions, the same
## "direct NavigationMesh.vertices/add_polygon(), not baked" approach
## _build_square_arena() uses and for the same reason (deterministic,
## instant, nothing to bake around) -- junction vertices are shared by
## index (not just coincident position) so Godot's navigation system
## definitely stitches the 5 polygons into one walkable region rather
## than relying on floating-point-exact edge matching between separately
## authored polygons.
func _build_cross_arena() -> void:
	var half := GameManager.CROSS_ARM_HALF_WIDTH
	var outer := GameManager.CROSS_ARM_OUTER_EXTENT

	var vertices := PackedVector3Array([
		Vector3(-half, 0, -half), # 0: center NW
		Vector3(half, 0, -half),  # 1: center NE
		Vector3(half, 0, half),   # 2: center SE
		Vector3(-half, 0, half),  # 3: center SW
		Vector3(-half, 0, -outer), # 4: north-arm outer NW
		Vector3(half, 0, -outer),  # 5: north-arm outer NE
		Vector3(outer, 0, -half),  # 6: east-arm outer NE
		Vector3(outer, 0, half),   # 7: east-arm outer SE
		Vector3(half, 0, outer),   # 8: south-arm outer SE
		Vector3(-half, 0, outer),  # 9: south-arm outer SW
		Vector3(-outer, 0, half),  # 10: west-arm outer SW
		Vector3(-outer, 0, -half), # 11: west-arm outer NW
	])

	var nav_mesh := NavigationMesh.new()
	nav_mesh.vertices = vertices
	nav_mesh.add_polygon(PackedInt32Array([0, 1, 2, 3])) # center
	nav_mesh.add_polygon(PackedInt32Array([4, 5, 1, 0])) # north arm
	nav_mesh.add_polygon(PackedInt32Array([1, 6, 7, 2])) # east arm
	nav_mesh.add_polygon(PackedInt32Array([2, 8, 9, 3])) # south arm
	nav_mesh.add_polygon(PackedInt32Array([3, 10, 11, 0])) # west arm

	_cross_nav_region = NavigationRegion3D.new()
	_cross_nav_region.navigation_mesh = nav_mesh
	add_child(_cross_nav_region)

	var full := half * 2.0
	var arm_length := outer - half
	var arm_center := half + arm_length * 0.5
	_cross_ground_pieces.append(_build_ground_piece(Vector2(full, full), Vector3.ZERO)) # center
	_cross_ground_pieces.append(_build_ground_piece(Vector2(full, arm_length), Vector3(0, 0, -arm_center))) # north
	_cross_ground_pieces.append(_build_ground_piece(Vector2(arm_length, full), Vector3(arm_center, 0, 0))) # east
	_cross_ground_pieces.append(_build_ground_piece(Vector2(full, arm_length), Vector3(0, 0, arm_center))) # south
	_cross_ground_pieces.append(_build_ground_piece(Vector2(arm_length, full), Vector3(-arm_center, 0, 0))) # west


## A single flat PlaneMesh piece of the ground, matching the original
## Scenes/Main.tscn Ground node's own mesh/material -- built in code (not
## the .tscn) since there are now up to 9 of these (1 square + 5 cross
## pieces) and authoring that by hand in the scene file would just
## duplicate this same material/shape logic across every one.
func _build_ground_piece(size: Vector2, position: Vector3) -> MeshInstance3D:
	var mesh := PlaneMesh.new()
	mesh.size = size

	var material := StandardMaterial3D.new()
	material.albedo_color = Color(0.16, 0.18, 0.16, 1)
	mesh.surface_set_material(0, material)

	var instance := MeshInstance3D.new()
	instance.mesh = mesh
	instance.position = position
	_ground.add_child(instance)
	return instance


## The only thing that needs to run again after _build_arenas() -- called
## once there, and again from _on_tournament_toggled()/_apply_menu_selection()
## whenever GameManager.current_mode actually changes. Disabling (not
## freeing) the inactive NavigationRegion3D fully excludes its navmesh
## from the navigation map, so the two shapes never interfere with each
## other's pathfinding.
func _sync_arena_shape() -> void:
	var cross_active := GameManager.current_mode.uses_cross_map()
	_square_nav_region.enabled = not cross_active
	_cross_nav_region.enabled = cross_active
	for piece in _square_ground_pieces:
		piece.visible = not cross_active
	for piece in _cross_ground_pieces:
		piece.visible = cross_active


## Swaps GameManager.current_mode between ClassicEliminationMode (the
## default single-battle behavior) and a fresh BloodTournamentMode.
## GameManager.set_mode() already resets to PLACEMENT, so this just also
## resyncs the HUD (winner banner/Start button) to match.
func _on_tournament_toggled(enabled: bool) -> void:
	if enabled:
		# 12 -- the genre-accurate fixed match length (see
		# BloodTournamentMode.total_rounds' own doc comment): every round
		# is played through regardless of standings, boss rounds included
		# (is_boss_round() lands on 3/6/9/12 either way). rounds_to_win (2)
		# is otherwise unused once total_rounds > 0, kept at its default.
		_tournament_mode = BloodTournamentMode.new(2, 12)
		_tournament_mode.round_ended.connect(_on_tournament_round_ended)
		_tournament_mode.all_rounds_finished.connect(_on_all_rounds_finished)
		GameManager.set_mode(_tournament_mode) # grants starting gold via BloodTournamentMode.on_activated()
	else:
		_tournament_mode = null
		GameManager.set_mode(ClassicEliminationMode.new())
	_sync_arena_shape()
	_hud.reset_for_new_round()
	_hud.hide_tournament_score()
	_refresh_gold_display()
	_run_ai_turn_if_needed()


## Connected to HUD's Start Battle button instead of GameManager.start_battle()
## directly, so a goblin boss round (BloodTournamentMode.is_boss_round())
## can be intercepted here and handed off to GoblinBossRound's own
## team-by-team sequencing instead of one normal simultaneous PvP battle.
## Every other mode/round just calls GameManager.start_battle() exactly as
## before.
func _on_start_battle_pressed() -> void:
	if _tournament_mode != null and _tournament_mode.is_boss_round():
		_boss_round = GoblinBossRound.new()
		_boss_round.boss_round_finished.connect(_on_boss_round_finished)
		_boss_round.start(_tournament_mode)
	else:
		GameManager.start_battle()


## GoblinBossRound itself never touches round scoring (see its class doc
## comment) -- finish_boss_round() does that once, for the boss round as a
## whole, which in turn emits round_ended and drives the exact same
## _on_tournament_round_ended() -> _advance_to_next_round() path a normal
## PvP round's win already does.
func _on_boss_round_finished() -> void:
	_boss_round = null
	_tournament_mode.finish_boss_round()


## All 12 rounds of the match are done (BloodTournamentMode.all_rounds_finished)
## -- hands off to the bracket-style final tournament that decides an
## overall champion (see FinalTournamentBracket's class doc comment).
func _on_all_rounds_finished() -> void:
	_bracket = FinalTournamentBracket.new()
	_bracket.champion_decided.connect(_on_champion_decided)
	_bracket.start(_tournament_mode)


## Reuses the existing winner-banner UI (is_draw always false -- a
## champion is always a specific team, byes included) rather than
## building dedicated "tournament champion" UI for this stage; a real
## presentation pass is future polish, not part of the mechanic itself.
func _on_champion_decided(team_id: int) -> void:
	_bracket = null
	_hud.show_winner(team_id, false)


## Red's Player.is_human flips to match -- AIController.take_turn() (see
## _run_ai_turn_if_needed()) is the only other thing that ever checks it.
## Forces the human back to Blue if they happened to be playing Red when
## AI takes it over -- HUD._on_ai_toggled() already disabled that button,
## this is the matching GameManager/SelectionManager-side half.
func _on_ai_opponent_toggled(enabled: bool) -> void:
	GameManager.get_player(GameManager.RED_TEAM_ID).is_human = not enabled
	if enabled:
		_selected_player = GameManager.get_player(GameManager.BLUE_TEAM_ID)
		SelectionManager.local_player = _selected_player
	_run_ai_turn_if_needed()


## Called everywhere a fresh PLACEMENT phase begins with Blood Tournament
## gold already settled (toggling the tournament on, toggling the AI on
## mid-match, and every subsequent round) -- see each call site. A no-op
## unless there's an is_human == false player under a mode that actually
## uses_economy(), so calling this speculatively from several places is
## always safe.
func _run_ai_turn_if_needed() -> void:
	if not GameManager.is_placement_phase() or not GameManager.current_mode.uses_economy():
		return
	var any_ai_took_a_turn := false
	for team_id in GameManager.all_team_ids():
		var player := GameManager.get_player(team_id)
		if not player.is_human:
			_ai.take_turn(player)
			any_ai_took_a_turn = true
	if any_ai_took_a_turn:
		_refresh_gold_display()


## Connected to the *current* BloodTournamentMode instance's own signal,
## not something GameManager forwards -- GameManager stays mode-agnostic
## (see GameMode.gd), so mode-specific UI reactions like this one have to
## come from Main.gd holding the mode reference directly.
func _on_tournament_round_ended(round_number: int, _winning_team_id: int, _is_draw: bool) -> void:
	_hud.show_tournament_score(round_number, _tournament_mode.get_wins(GameManager.BLUE_TEAM_ID), _tournament_mode.get_wins(GameManager.RED_TEAM_ID))
	_refresh_gold_display() # round income (BloodTournamentMode.on_battle_ended()) already landed by now
	if not _tournament_mode.is_match_over():
		# Deferred, not called straight from here: this handler runs
		# *during* GameManager._end_battle(), before its own
		# battle_ended.emit() -- resetting synchronously would flip
		# battle_state back to PLACEMENT and hide the winner banner
		# before that emit (and HUD.show_winner()) even runs, then have
		# it clobbered back to visible right after. Deferring lets this
		# round's result display first, uninterrupted.
		call_deferred("_advance_to_next_round")


func _advance_to_next_round() -> void:
	GameManager.reset_battle() # no permadeath -- every unit is freed; roster entries stay data-only until the next battle's staggered deployment
	_hud.reset_for_new_round()
	_run_ai_turn_if_needed()


## Seconds between one roster slot's squad marching out and the next --
## not a balance number, just enough to actually read as a staggered
## arrival rather than everyone appearing on the same frame.
const _DEPLOY_INTERVAL := 1.0

## Player.id -> Array[UnitStats], the still-to-deploy remainder of that
## player's roster, reversed (see _begin_staggered_deployment()) so it
## pops right-to-left. Player.id -> float in _deploy_timers is seconds
## remaining until that player's next entry deploys.
var _pending_deployments: Dictionary = {}
var _deploy_timers: Dictionary = {}


## Literal separate staging area, not an instant respawn: Player.roster
## entries are never spawned as live Units during PLACEMENT (see
## _on_unit_type_selected()/_try_place_unit()) -- they only become real
## Units once BATTLE actually starts, marching out from each player's pen
## one slot at a time. "Rightmost deploys first, leftmost deploys last"
## (per the reference genre) is expressed as *purchase order, reversed*:
## buying appends to the end of Player.roster, so the most recently
## bought slot -- the "rightmost" one in the line-up -- pops first here.
func _begin_staggered_deployment() -> void:
	# A goblin boss round's own controller (GoblinBossRound) deploys just
	# the one team currently taking its turn directly -- the normal
	# every-registered-team staggered flow below would double-deploy that
	# same roster a second time (and also try to deploy every OTHER
	# team's roster, which shouldn't appear during a solo PvE turn at
	# all) if it ran too. Same reasoning for a bracket matchup
	# (FinalTournamentBracket) -- it deploys exactly the two paired teams
	# itself.
	if _tournament_mode != null and (_tournament_mode.current_boss_team_id != -1 or _tournament_mode.in_bracket_match):
		return

	_pending_deployments.clear()
	_deploy_timers.clear()
	for team_id in GameManager.all_team_ids():
		var player := GameManager.get_player(team_id)
		if player.roster.is_empty():
			continue
		var queue := player.roster.duplicate()
		queue.reverse()
		_pending_deployments[player.id] = queue
		_deploy_timers[player.id] = 0.0 # the first slot marches out immediately, not after a full interval's wait


## _physics_process(), not _process() -- matches every other piece of
## game-logic timing in this codebase (HUD's own _process() is the one
## exception, but that's a pure UI refresh, not gameplay timing) and
## guarantees this actually advances during GUT's wait_physics_frames(),
## which is specifically tied to physics frames. Only does anything while
## there's an active staggered deployment queue for at least one player --
## a no-op every other physics frame of the game's life, including all of
## PLACEMENT and any battle with an empty roster (classic mode, always).
func _physics_process(delta: float) -> void:
	if _pending_deployments.is_empty():
		return
	for player_id in _pending_deployments.keys().duplicate(): # duplicated: _deploy_next_pending_slot() below may erase from the dict mid-iteration
		_deploy_timers[player_id] -= delta
		if _deploy_timers[player_id] <= 0.0:
			_deploy_next_pending_slot(player_id)


## Applies every account-wide upgrade the player bought during PLACEMENT
## (see GameManager.buy_roster_upgrade()) to every unit in the squad that
## just deployed -- upgrades were recorded rather than applied at
## purchase time specifically because nothing was alive yet to apply them
## to, so this is where that deferred application actually happens.
func _deploy_next_pending_slot(player_id: int) -> void:
	var queue: Array = _pending_deployments[player_id]
	var stats: UnitStats = queue.pop_front()
	var player := GameManager.get_player(player_id)
	var squad := GameManager.spawn_squad(stats, player, ARM_SPAWN_POINTS[player.team_id])
	for upgrade in player.roster_upgrades:
		for unit in squad:
			upgrade.ability.cast_unit_target(unit, unit)

	if queue.is_empty():
		_pending_deployments.erase(player_id)
		_deploy_timers.erase(player_id)
	else:
		_deploy_timers[player_id] = _DEPLOY_INTERVAL


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
	_hud.refresh_affordability(_selected_player)


## Connected to HUD's roster line-up row (see UI/HUD.gd) -- clicking a
## slot there sells it (GameManager.sell_roster_slot()) instead of the
## old right-click-a-live-unit flow (_try_sell_unit_at()), since nothing
## is live to click during PLACEMENT anymore under the staggered-deployment
## model.
func _on_roster_slot_sold(index: int) -> void:
	if GameManager.sell_roster_slot(_selected_player, index):
		_refresh_gold_display()


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		_handle_mouse_button(event)
	elif event is InputEventMouseMotion:
		_handle_mouse_motion(event)
	elif event is InputEventKey and event.pressed and not event.echo:
		_handle_key(event)


func _handle_mouse_button(event: InputEventMouseButton) -> void:
	if event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			_left_drag_start = event.position
			_is_left_dragging = false
			_try_start_unit_drag(event.position)
		else:
			_on_left_release(event)
	elif event.button_index == MOUSE_BUTTON_RIGHT and event.pressed:
		if _pending_ability_target != -1:
			_cancel_pending_ability_target()
		elif GameManager.battle_state == GameManager.BattleState.PLACEMENT:
			_try_sell_unit_at(event.position)
		else:
			_on_right_click(event)


func _handle_mouse_motion(event: InputEventMouseMotion) -> void:
	if not (event.button_mask & MOUSE_BUTTON_MASK_LEFT):
		return
	if _dragging_unit != null:
		_drag_unit_to(event.position)
		return
	if GameManager.battle_state != GameManager.BattleState.BATTLE:
		return
	if not _is_left_dragging and _left_drag_start.distance_to(event.position) > _DRAG_THRESHOLD:
		_is_left_dragging = true
	if _is_left_dragging:
		_hud.show_drag_box(Rect2(_left_drag_start, Vector2.ZERO).expand(event.position))


func _on_left_release(event: InputEventMouseButton) -> void:
	if _pending_ability_target != -1:
		_resolve_pending_ability_target(event.position)
		return

	if _dragging_unit != null:
		_dragging_unit = null
		return

	if _is_left_dragging:
		_is_left_dragging = false
		_hud.hide_drag_box()
		var rect := Rect2(_left_drag_start, Vector2.ZERO).expand(event.position)
		SelectionManager.select_in_rect(_camera, rect, Input.is_key_pressed(KEY_SHIFT))
		return
	_is_left_dragging = false

	if DebugInspector.try_select_at(_camera, event.position):
		# Debug-inspecting a unit and being able to command it shouldn't
		# need two separate clicks -- select_single() is a no-op if the
		# hit unit isn't SelectionManager.local_player's, so this is
		# harmless when the click was on an enemy/inspection-only target.
		if GameManager.battle_state == GameManager.BattleState.BATTLE:
			SelectionManager.select_single(DebugInspector.selected_unit, Input.is_key_pressed(KEY_SHIFT))
		return

	if GameManager.battle_state == GameManager.BattleState.PLACEMENT:
		_try_place_unit(event.position)
	elif GameManager.battle_state == GameManager.BattleState.BATTLE:
		SelectionManager.clear_selection() # clicking empty ground deselects, standard RTS convention


## Right-click on a hostile unit attacks it, on a friendly unit follows
## it, and on empty ground attack-moves there -- issued to every unit in
## SelectionManager.selected_units (ownership is already enforced there,
## via local_player). Shift queues the order after whatever's already
## queued instead of replacing it.
func _on_right_click(event: InputEventMouseButton) -> void:
	if GameManager.battle_state != GameManager.BattleState.BATTLE or SelectionManager.selected_units.is_empty():
		return
	var queue := Input.is_key_pressed(KEY_SHIFT)

	var space_state := _camera.get_world_3d().direct_space_state
	var ray_origin := _camera.project_ray_origin(event.position)
	var ray_direction := _camera.project_ray_normal(event.position)
	var query := PhysicsRayQueryParameters3D.create(ray_origin, ray_origin + ray_direction * 1000.0, SelectionManager.UNITS_PHYSICS_LAYER)
	var hit := space_state.intersect_ray(query)

	if not hit.is_empty() and hit.collider is Unit:
		var clicked: Unit = hit.collider
		if GameManager.alliances.is_hostile(SelectionManager.local_player.team_id, clicked.player.team_id):
			SelectionManager.order_attack_unit(clicked, queue)
		else:
			SelectionManager.order_follow(clicked, queue)
		return

	var hit_position = GROUND_PLANE.intersects_ray(ray_origin, ray_direction)
	if hit_position != null:
		SelectionManager.order_attack_move(hit_position, queue)


## S = Stop, H = Hold Position, Q/W/E = cast ability slot 0/1/2 (see
## UnitStats.abilities -- a NO_TARGET/PASSIVE/AURA slot casts immediately
## same as always; a UNIT_TARGET slot now enters click-to-target mode
## instead of auto-targeting, see _try_cast_or_target()), Escape cancels a
## pending target, plain 1-9 = recall a control group, Ctrl+1-9 = assign
## the current selection to one. No dedicated Patrol hotkey yet --
## Unit.order_patrol()/SelectionManager.order_patrol() are complete and
## tested, just not wired to input; a two-step "press P, then click a
## destination" mode is more input-state-machine than this pass needs.
func _handle_key(event: InputEventKey) -> void:
	if event.keycode == KEY_ESCAPE and _pending_ability_target != -1:
		_cancel_pending_ability_target()
		return
	if GameManager.battle_state == GameManager.BattleState.PLACEMENT:
		_handle_placement_key(event)
		return
	if GameManager.battle_state != GameManager.BattleState.BATTLE:
		return
	if event.keycode == KEY_S:
		SelectionManager.order_stop()
	elif event.keycode == KEY_H:
		SelectionManager.order_hold()
	elif event.keycode == KEY_Q:
		_try_cast_or_target(0)
	elif event.keycode == KEY_W:
		_try_cast_or_target(1)
	elif event.keycode == KEY_E:
		_try_cast_or_target(2)
	elif event.keycode >= KEY_1 and event.keycode <= KEY_9:
		var group := event.keycode - KEY_1 + 1
		if event.ctrl_pressed:
			SelectionManager.assign_control_group(group)
		else:
			SelectionManager.select_control_group(group)


## A NO_TARGET/PASSIVE/AURA slot (or an empty one) casts immediately via
## the auto-target path, unchanged from before this feature. A UNIT_TARGET
## slot instead enters click-to-target mode (_pending_ability_target) and
## shows a HUD prompt -- the next left-click (_resolve_pending_ability_target())
## casts it at whatever unit was clicked instead of auto-targeting.
## Determined from the first owned selected unit's ability in that slot --
## a mixed selection with different kits at the same index is already an
## existing ambiguity SelectionManager.cast_ability() has (it just casts
## whatever each unit happens to have there), not something this feature
## needs to solve first. Also the target for HUD's clickable hotbar
## buttons (see ability_slot_pressed), not just the Q/W/E hotkeys.
func _try_cast_or_target(index: int) -> void:
	var ability := _first_selected_ability(index)
	if ability != null and ability.cast_type == Ability.CastType.UNIT_TARGET:
		_pending_ability_target = index
		_hud.show_targeting_prompt(ability.ability_name)
	else:
		SelectionManager.cast_ability(index)


func _first_selected_ability(index: int) -> Ability:
	for unit in SelectionManager.selected_units:
		if index >= 0 and index < unit.stats.abilities.size() and unit.stats.abilities[index] != null:
			return unit.stats.abilities[index]
	return null


func _resolve_pending_ability_target(screen_position: Vector2) -> void:
	var index := _pending_ability_target
	_cancel_pending_ability_target() # clears state/hides the prompt regardless of whether the click actually hits a unit
	if DebugInspector.try_select_at(_camera, screen_position):
		SelectionManager.cast_ability_at_target(index, DebugInspector.selected_unit)


func _cancel_pending_ability_target() -> void:
	_pending_ability_target = -1
	_hud.hide_targeting_prompt()


## PLACEMENT-only: U/I buy a Blood Tournament shop upgrade (see
## Resources/*Upgrade.tres) for _selected_player's account, applied to
## every unit in every squad they deploy from now on (see
## GameManager.buy_roster_upgrade()/Main._deploy_next_pending_slot()).
## No unit-targeting/selection needed anymore -- nothing is alive to
## target during PLACEMENT under the staging-area deployment model, so
## unlike the old per-unit flow this replaced, there's no legal target to
## check ownership of at purchase time at all.
func _handle_placement_key(event: InputEventKey) -> void:
	if event.keycode != KEY_U and event.keycode != KEY_I:
		return
	var index := 0 if event.keycode == KEY_U else 1
	if index < _UPGRADES.size() and GameManager.buy_roster_upgrade(_selected_player, _UPGRADES[index]):
		_refresh_gold_display()


## PLACEMENT-only pickup for a unit _selected_player already owns (see
## _dragging_unit's doc comment) -- reuses DebugInspector's own raycast/layer
## instead of a second one, so this is also why clicking a unit already
## short-circuits _try_place_unit() via DebugInspector.try_select_at() in
## _on_left_release(): that early-return existed before this feature and is
## what stopped a click from ever placing a fresh unit on top of one that's
## already there.
func _try_start_unit_drag(screen_position: Vector2) -> void:
	_dragging_unit = null
	if GameManager.battle_state != GameManager.BattleState.PLACEMENT:
		return
	if not DebugInspector.try_select_at(_camera, screen_position):
		return
	if DebugInspector.selected_unit.player == _selected_player:
		_dragging_unit = DebugInspector.selected_unit


## Teleports _dragging_unit under the cursor every frame the drag continues.
## No path/physics involved -- Unit._physics_process() clamps position to
## the arena bounds and snaps Y to _resting_height() every frame regardless
## of battle_state, so a drag that goes past the edge or over uneven resting
## height just corrects itself for free.
func _drag_unit_to(screen_position: Vector2) -> void:
	var ray_origin := _camera.project_ray_origin(screen_position)
	var ray_direction := _camera.project_ray_normal(screen_position)
	var hit_position = GROUND_PLANE.intersects_ray(ray_origin, ray_direction)
	if hit_position != null:
		_dragging_unit.global_position = hit_position


## Classic-mode-only now: under Blood Tournament (current_mode.uses_economy())
## there's no arena position to choose anymore -- a purchase just joins
## the roster/line-up (see _on_unit_type_selected()) and deploys from a
## fixed per-team anchor once battle starts (_begin_staggered_deployment()),
## not wherever you clicked. A plain single-battle match is unaffected:
## click a spot, place one unit there, exactly as before.
func _try_place_unit(screen_position: Vector2) -> void:
	if _selected_stats == null or GameManager.current_mode.uses_economy():
		return

	var ray_origin := _camera.project_ray_origin(screen_position)
	var ray_direction := _camera.project_ray_normal(screen_position)
	var hit_position = GROUND_PLANE.intersects_ray(ray_origin, ray_direction)
	if hit_position == null:
		return

	GameManager.spawn_unit(_selected_stats, _selected_player, hit_position)


## PLACEMENT-only: right-click on a unit _selected_player owns sells it
## (see GameManager.sell_unit()) instead of the BATTLE right-click's
## attack/follow/attack-move routing, which only makes sense once a battle
## is actually running. Also removes the matching entry from the
## player's roster (Array.erase() removes the first match, a harmless
## no-op if it isn't there -- e.g. outside Blood Tournament, where
## nothing ever gets appended to begin with) -- otherwise a sold unit
## would just respawn again next round regardless of being sold.
func _try_sell_unit_at(screen_position: Vector2) -> void:
	if not DebugInspector.try_select_at(_camera, screen_position):
		return
	var unit := DebugInspector.selected_unit
	if unit.player == _selected_player:
		unit.player.roster.erase(unit.stats)
		GameManager.sell_unit(unit)
		_refresh_gold_display()


## Under Blood Tournament, clicking a unit-type button doesn't just pick
## what a later arena click would place (there's no arena click for this
## anymore, see _try_place_unit()) -- it buys one slot immediately,
## appending to the roster/line-up. Classic mode keeps the original
## two-step "pick a type, then click where" flow, so _selected_stats is
## still tracked either way.
func _on_unit_type_selected(stats: UnitStats) -> void:
	_selected_stats = stats
	if GameManager.current_mode.uses_economy():
		_try_buy_for_roster(stats)


func _try_buy_for_roster(stats: UnitStats) -> void:
	if not _selected_player.can_afford(stats.cost):
		return
	_selected_player.spend(stats.cost)
	_selected_player.roster.append(stats)
	_refresh_gold_display()


## Doubles as "which side am I playing as" for this single-machine
## prototype: the Blue/Red toggle picks both who newly-placed units
## belong to (_selected_player) and whose units SelectionManager will
## let you select/command (local_player) -- there's no separate "spawn
## for both sides, but only ever play as Blue" mode. A real lobby/second
## client (Phase 8) replaces this with actual per-player identity instead
## of one shared toggle switching both.
func _on_team_selected(team_id: int) -> void:
	_selected_player = GameManager.get_player(team_id)
	SelectionManager.local_player = _selected_player
	_refresh_gold_display()
