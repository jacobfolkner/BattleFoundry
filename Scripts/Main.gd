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
## _selected_player already owns (a Blood Tournament survivor carried over
## by GameManager.reset_battle(true), most likely) -- lets it be
## repositioned before the next round starts instead of only ever placing
## a brand-new unit on click. See _try_start_unit_drag()/_drag_unit_to().
var _dragging_unit: Unit = null

## Non-null only while the HUD's Blood Tournament toggle is on -- see
## _on_tournament_toggled(). Holding the reference here (not just reading
## it back off GameManager.current_mode) is what lets _on_tournament_round_ended()
## read BloodTournamentMode-specific state (get_wins(), is_match_over())
## without every caller needing to cast/check GameManager.current_mode's type.
var _tournament_mode: BloodTournamentMode = null

var _ai := AIController.new()

## -1 means no ability is awaiting a target. Set only for a UNIT_TARGET
## ability slot (see _try_cast_or_target()) -- the next left-click resolves
## it (_resolve_pending_ability_target()); right-click or Escape cancels.
var _pending_ability_target: int = -1


func _ready() -> void:
	GameManager.units_container = _units_container
	GameManager.battle_ended.connect(_hud.show_winner)
	_selected_player = GameManager.get_player(GameManager.BLUE_TEAM_ID)
	_selected_stats = _DEFAULT_UNIT_STATS
	SelectionManager.local_player = _selected_player # keep in sync with the default team panel toggle
	_build_navigation()

	_hud.unit_type_selected.connect(_on_unit_type_selected)
	_hud.team_selected.connect(_on_team_selected)
	_hud.start_battle_pressed.connect(GameManager.start_battle)
	_hud.tournament_mode_toggled.connect(_on_tournament_toggled)
	_hud.ai_opponent_toggled.connect(_on_ai_opponent_toggled)
	_hud.ability_slot_pressed.connect(_try_cast_or_target)
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


## A single open rectangle spanning the whole arena, authored directly
## (NavigationMesh.vertices/add_polygon()) rather than baked from Ground's
## geometry -- deterministic and instant, and there's nothing to bake
## around: this shared arena has no static obstacles (see
## tests/test_pathfinding.gd for a *baked* NavigationMesh with a real
## wall to route around, built in an isolated scene rather than here,
## since a shared obstacle here would sit in the footsteps of dozens of
## existing tests that spawn/path units anywhere in the 40x40 plane,
## corners included). Units path against this via
## Unit._seek_position()/get_next_path_position() -- see its doc comment
## for why that's an actual navmesh query now, not just a straight-line
## direction fed to avoidance the way it was before this existed.
func _build_navigation() -> void:
	var half := GameManager.ARENA_HALF_EXTENT
	var nav_mesh := NavigationMesh.new()
	nav_mesh.vertices = PackedVector3Array([
		Vector3(-half, 0, -half),
		Vector3(half, 0, -half),
		Vector3(half, 0, half),
		Vector3(-half, 0, half),
	])
	nav_mesh.add_polygon(PackedInt32Array([0, 1, 2, 3]))

	var region := NavigationRegion3D.new()
	region.navigation_mesh = nav_mesh
	add_child(region)


## Swaps GameManager.current_mode between ClassicEliminationMode (the
## default single-battle behavior) and a fresh BloodTournamentMode.
## GameManager.set_mode() already resets to PLACEMENT, so this just also
## resyncs the HUD (winner banner/Start button) to match.
func _on_tournament_toggled(enabled: bool) -> void:
	if enabled:
		_tournament_mode = BloodTournamentMode.new()
		_tournament_mode.round_ended.connect(_on_tournament_round_ended)
		GameManager.set_mode(_tournament_mode) # grants starting gold via BloodTournamentMode.on_activated()
	else:
		_tournament_mode = null
		GameManager.set_mode(ClassicEliminationMode.new())
	_hud.reset_for_new_round()
	_hud.hide_tournament_score()
	_refresh_gold_display()
	_run_ai_turn_if_needed()


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
	var red := GameManager.get_player(GameManager.RED_TEAM_ID)
	if not red.is_human:
		_ai.take_turn(red)
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
	GameManager.reset_battle(true) # Blood Tournament: units still standing carry into the next round
	_hud.reset_for_new_round()
	_run_ai_turn_if_needed()


## Shows Blue/Red's current gold whenever current_mode.uses_economy() is
## true, hides it otherwise -- self-deciding on every call (rather than
## the caller tracking on/off) so every spend/refund/income call site can
## just call this without also branching on mode type itself.
func _refresh_gold_display() -> void:
	if GameManager.current_mode.uses_economy():
		_hud.show_gold(
			GameManager.get_player(GameManager.BLUE_TEAM_ID).resources,
			GameManager.get_player(GameManager.RED_TEAM_ID).resources
		)
	else:
		_hud.hide_gold()
	_hud.refresh_affordability(_selected_player)


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
## Resources/*Upgrade.tres) for whichever unit DebugInspector currently has
## selected -- deliberately no click-to-target flow of its own (unlike Q/W/E
## in BATTLE, see _try_cast_or_target()) since there's only ever one legal
## target, your own already-selected unit. GameManager.buy_upgrade() itself
## already no-ops outside Blood Tournament and for an unaffordable
## purchase, so this only needs to check which unit is selected and who
## owns it.
func _handle_placement_key(event: InputEventKey) -> void:
	if event.keycode != KEY_U and event.keycode != KEY_I:
		return
	if not DebugInspector.has_valid_selection():
		return
	var unit := DebugInspector.selected_unit
	if unit.player != _selected_player:
		return
	var index := 0 if event.keycode == KEY_U else 1
	if index < _UPGRADES.size() and GameManager.buy_upgrade(unit, _UPGRADES[index]):
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


## Cost-gated only while GameManager.current_mode.uses_economy() is true --
## a plain single-battle match stays exactly as free-to-place as it always
## was (see GameMode.uses_economy()'s doc comment).
func _try_place_unit(screen_position: Vector2) -> void:
	if _selected_stats == null:
		return
	var use_gold := GameManager.current_mode.uses_economy()
	if use_gold and not _selected_player.can_afford(_selected_stats.cost):
		return

	var ray_origin := _camera.project_ray_origin(screen_position)
	var ray_direction := _camera.project_ray_normal(screen_position)
	var hit_position = GROUND_PLANE.intersects_ray(ray_origin, ray_direction)
	if hit_position == null:
		return

	GameManager.spawn_unit(_selected_stats, _selected_player, hit_position)
	if use_gold:
		_selected_player.spend(_selected_stats.cost)
		_refresh_gold_display()


## PLACEMENT-only: right-click on a unit _selected_player owns sells it
## (see GameManager.sell_unit()) instead of the BATTLE right-click's
## attack/follow/attack-move routing, which only makes sense once a battle
## is actually running.
func _try_sell_unit_at(screen_position: Vector2) -> void:
	if not DebugInspector.try_select_at(_camera, screen_position):
		return
	var unit := DebugInspector.selected_unit
	if unit.player == _selected_player:
		GameManager.sell_unit(unit)
		_refresh_gold_display()


func _on_unit_type_selected(stats: UnitStats) -> void:
	_selected_stats = stats


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
