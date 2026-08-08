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
const _DEFAULT_UNIT_STATS: UnitStats = preload("res://Resources/TankStats.tres")

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

## Non-null only while the HUD's Blood Tournament toggle is on -- see
## _on_tournament_toggled(). Holding the reference here (not just reading
## it back off GameManager.current_mode) is what lets _on_tournament_round_ended()
## read BloodTournamentMode-specific state (get_wins(), is_match_over())
## without every caller needing to cast/check GameManager.current_mode's type.
var _tournament_mode: BloodTournamentMode = null


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
		GameManager.set_mode(_tournament_mode)
	else:
		_tournament_mode = null
		GameManager.set_mode(ClassicEliminationMode.new())
	_hud.reset_for_new_round()
	_hud.hide_tournament_score()


## Connected to the *current* BloodTournamentMode instance's own signal,
## not something GameManager forwards -- GameManager stays mode-agnostic
## (see GameMode.gd), so mode-specific UI reactions like this one have to
## come from Main.gd holding the mode reference directly.
func _on_tournament_round_ended(round_number: int, _winning_team_id: int, _is_draw: bool) -> void:
	_hud.show_tournament_score(round_number, _tournament_mode.get_wins(GameManager.BLUE_TEAM_ID), _tournament_mode.get_wins(GameManager.RED_TEAM_ID))
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
	GameManager.reset_battle()
	_hud.reset_for_new_round()


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
		else:
			_on_left_release(event)
	elif event.button_index == MOUSE_BUTTON_RIGHT and event.pressed:
		_on_right_click(event)


func _handle_mouse_motion(event: InputEventMouseMotion) -> void:
	if not (event.button_mask & MOUSE_BUTTON_MASK_LEFT):
		return
	if GameManager.battle_state != GameManager.BattleState.BATTLE:
		return
	if not _is_left_dragging and _left_drag_start.distance_to(event.position) > _DRAG_THRESHOLD:
		_is_left_dragging = true
	if _is_left_dragging:
		_hud.show_drag_box(Rect2(_left_drag_start, Vector2.ZERO).expand(event.position))


func _on_left_release(event: InputEventMouseButton) -> void:
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
## UnitStats.abilities -- a UNIT_TARGET ability auto-targets whatever the
## unit is already fighting, there's no target-picking cursor mode in
## this v1), plain 1-9 = recall a control group, Ctrl+1-9 = assign the
## current selection to one. No dedicated Patrol hotkey yet --
## Unit.order_patrol()/SelectionManager.order_patrol() are complete and
## tested, just not wired to input; a two-step "press P, then click a
## destination" mode is more input-state-machine than this pass needs.
func _handle_key(event: InputEventKey) -> void:
	if GameManager.battle_state != GameManager.BattleState.BATTLE:
		return
	if event.keycode == KEY_S:
		SelectionManager.order_stop()
	elif event.keycode == KEY_H:
		SelectionManager.order_hold()
	elif event.keycode == KEY_Q:
		SelectionManager.cast_ability(0)
	elif event.keycode == KEY_W:
		SelectionManager.cast_ability(1)
	elif event.keycode == KEY_E:
		SelectionManager.cast_ability(2)
	elif event.keycode >= KEY_1 and event.keycode <= KEY_9:
		var group := event.keycode - KEY_1 + 1
		if event.ctrl_pressed:
			SelectionManager.assign_control_group(group)
		else:
			SelectionManager.select_control_group(group)


func _try_place_unit(screen_position: Vector2) -> void:
	if _selected_stats == null:
		return

	var ray_origin := _camera.project_ray_origin(screen_position)
	var ray_direction := _camera.project_ray_normal(screen_position)
	var hit_position = GROUND_PLANE.intersects_ray(ray_origin, ray_direction)
	if hit_position == null:
		return

	GameManager.spawn_unit(_selected_stats, _selected_player, hit_position)


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
