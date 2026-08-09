## Turns mouse/keyboard input into the right action for the current
## battle_state: unit placement during PLACEMENT, and selection/order-
## issuing (SelectionManager, Scripts/SelectionManager.gd) during BATTLE.
## A click first gets offered to DebugInspector (Scripts/DebugInspector.gd)
## in case it landed on a unit; only an unclaimed click can place one or
## fall through to a box-select/deselect.
##
## Owned and driven by Main.gd (constructed once in Main._ready(), fed
## every input event via Main._unhandled_input() -> handle()) -- knows
## nothing about the camera/HUD beyond the two references it's given, and
## nothing about arena-building or Blood Tournament round orchestration
## at all, matching the same "isolated component, not a back-reference to
## all of Main" shape GoblinBossRound/FinalTournamentBracket already use.
## refresh_gold_display is a Callable, not a full Main reference, for the
## same reason -- the one piece of Main's own state (HUD gold/roster
## display) a few of these actions need to trigger after they run.
class_name PlayerInputController
extends RefCounted

const GROUND_PLANE := Plane(Vector3.UP, 0.0)
## Screen pixels the mouse must move past _left_drag_start before a
## left-button hold counts as a box-select drag instead of a click --
## without this, every click (which always jitters a pixel or two) would
## register as a zero-size drag and skip the click-handling path entirely.
const _DRAG_THRESHOLD := 6.0
## Must match whichever unit-type button HUD._build_unit_panel() starts
## toggled on ("Tank"). HUD._ready() emits its default selection too, but
## Godot calls a child's _ready() (HUD's) before its parent's (Main's) --
## by the time Main connects unit_type_selected, that first emit already
## fired into the void, so this fallback exists to give selected_stats a
## valid value regardless. See Main.gd's own former copy of this comment
## for the full history (a real race, caught by a user hitting it
## directly, not by any automated test).
const _DEFAULT_UNIT_STATS: UnitStats = preload("res://Resources/Units/TankStats.tres")
## Index 0/1 map to the U/I hotkeys (see handle_placement_key()) --
## deliberately just two, "prove the shop-side flow" per the roadmap, not
## a real shop UI/browse list.
const _UPGRADES: Array[UnitUpgrade] = [
	preload("res://Resources/Upgrades/IronArmorUpgrade.tres"),
	preload("res://Resources/Upgrades/WhetstoneUpgrade.tres"),
]

var _camera: Camera3D
var _hud: Control
var _refresh_gold_display: Callable

var selected_stats: UnitStats
## Set here in _init(), not a field initializer -- a field initializer
## would run at construction time, which for this controller happens
## during Main._ready(), not guaranteed to be after GameManager._ready()
## has populated its player registry. Main._ready() constructs this
## controller only after its own @onready vars resolve, which is late
## enough, but keeping the read in _init() (not a bare `= GameManager...`
## default) documents that ordering dependency explicitly rather than
## relying on construction timing nobody would otherwise notice mattered.
var selected_player: Player

var _left_drag_start: Vector2 = Vector2.ZERO
var _is_left_dragging: bool = false

## Non-null only while PLACEMENT's left-mouse-down landed on a unit
## selected_player already owns -- lets it be repositioned instead of
## only ever placing a brand-new unit on click. See
## try_start_unit_drag()/drag_unit_to(). Only ever finds anything under
## classic mode now: Blood Tournament's roster (Player.roster) isn't
## spawned as live Units during PLACEMENT anymore, so there's nothing on
## the field to drag until BATTLE actually starts.
var dragging_unit: Unit = null

## -1 means no ability is awaiting a target. Set only for a UNIT_TARGET
## ability slot (see try_cast_or_target()) -- the next left-click resolves
## it (resolve_pending_ability_target()); right-click or Escape cancels.
var pending_ability_target: int = -1


func _init(camera: Camera3D, hud: Control, refresh_gold_display: Callable) -> void:
	_camera = camera
	_hud = hud
	_refresh_gold_display = refresh_gold_display
	selected_player = GameManager.get_player(GameManager.BLUE_TEAM_ID)
	selected_stats = _DEFAULT_UNIT_STATS


func handle(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		handle_mouse_button(event)
	elif event is InputEventMouseMotion:
		handle_mouse_motion(event)
	elif event is InputEventKey and event.pressed and not event.echo:
		handle_key(event)


func handle_mouse_button(event: InputEventMouseButton) -> void:
	if event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			_left_drag_start = event.position
			_is_left_dragging = false
			try_start_unit_drag(event.position)
		else:
			on_left_release(event)
	elif event.button_index == MOUSE_BUTTON_RIGHT and event.pressed:
		if pending_ability_target != -1:
			cancel_pending_ability_target()
		elif GameManager.battle_state == GameManager.BattleState.PLACEMENT:
			try_sell_unit_at(event.position)
		else:
			on_right_click(event)


func handle_mouse_motion(event: InputEventMouseMotion) -> void:
	if not (event.button_mask & MOUSE_BUTTON_MASK_LEFT):
		return
	if dragging_unit != null:
		drag_unit_to(event.position)
		return
	if GameManager.battle_state != GameManager.BattleState.BATTLE:
		return
	if not _is_left_dragging and _left_drag_start.distance_to(event.position) > _DRAG_THRESHOLD:
		_is_left_dragging = true
	if _is_left_dragging:
		_hud.show_drag_box(Rect2(_left_drag_start, Vector2.ZERO).expand(event.position))


func on_left_release(event: InputEventMouseButton) -> void:
	if pending_ability_target != -1:
		resolve_pending_ability_target(event.position)
		return

	if dragging_unit != null:
		dragging_unit = null
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
		try_place_unit(event.position)
	elif GameManager.battle_state == GameManager.BattleState.BATTLE:
		SelectionManager.clear_selection() # clicking empty ground deselects, standard RTS convention


## Right-click on a hostile unit attacks it, on a friendly unit follows
## it, and on empty ground attack-moves there -- issued to every unit in
## SelectionManager.selected_units (ownership is already enforced there,
## via local_player). Shift queues the order after whatever's already
## queued instead of replacing it. A no-op entirely during auto-battle
## (GameMode.is_auto_battle()) -- no manual commanding, see Main's own
## former doc comment for the design.
func on_right_click(event: InputEventMouseButton) -> void:
	if GameManager.battle_state != GameManager.BattleState.BATTLE or SelectionManager.selected_units.is_empty():
		return
	if GameManager.current_mode.is_auto_battle():
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
## same as always; a UNIT_TARGET slot enters click-to-target mode instead
## of auto-targeting, see try_cast_or_target()), Escape cancels a pending
## target, plain 1-9 = recall a control group, Ctrl+1-9 = assign the
## current selection to one. S/H specifically become no-ops during
## auto-battle (GameMode.is_auto_battle()) -- Q/W/E stay reachable since
## try_cast_or_target() has its own auto-battle guard, and 1-9 group
## recall is selection/inspection, not commanding, so it's never gated at
## all. No dedicated Patrol hotkey yet -- Unit.order_patrol()/
## SelectionManager.order_patrol() are complete and tested, just not
## wired to input; a two-step "press P, then click a destination" mode is
## more input-state-machine than this pass needs.
func handle_key(event: InputEventKey) -> void:
	if event.keycode == KEY_ESCAPE and pending_ability_target != -1:
		cancel_pending_ability_target()
		return
	if GameManager.battle_state == GameManager.BattleState.PLACEMENT:
		handle_placement_key(event)
		return
	if GameManager.battle_state != GameManager.BattleState.BATTLE:
		return
	var can_command := not GameManager.current_mode.is_auto_battle()
	if event.is_action_pressed("order_stop") and can_command:
		SelectionManager.order_stop()
	elif event.is_action_pressed("order_hold") and can_command:
		SelectionManager.order_hold()
	elif event.is_action_pressed("ability_slot_0"):
		try_cast_or_target(0)
	elif event.is_action_pressed("ability_slot_1"):
		try_cast_or_target(1)
	elif event.is_action_pressed("ability_slot_2"):
		try_cast_or_target(2)
	elif event.keycode >= KEY_1 and event.keycode <= KEY_9:
		var group := event.keycode - KEY_1 + 1
		if event.ctrl_pressed:
			SelectionManager.assign_control_group(group)
		else:
			SelectionManager.select_control_group(group)


## A NO_TARGET/PASSIVE/AURA slot (or an empty one) casts immediately via
## the auto-target path. A UNIT_TARGET slot instead enters click-to-target
## mode (pending_ability_target) and shows a HUD prompt -- the next
## left-click (resolve_pending_ability_target()) casts it at whatever
## unit was clicked instead of auto-targeting. Determined from the first
## owned selected unit's ability in that slot -- a mixed selection with
## different kits at the same index is already an existing ambiguity
## SelectionManager.cast_ability() has (it just casts whatever each unit
## happens to have there), not something this feature needs to solve
## first. Also the target for HUD's clickable hotbar buttons (see
## ability_slot_pressed), not just the Q/W/E hotkeys. A no-op entirely
## during auto-battle, mid-BATTLE -- see GameMode.is_auto_battle().
func try_cast_or_target(index: int) -> void:
	if GameManager.is_battle_active() and GameManager.current_mode.is_auto_battle():
		return
	var ability := first_selected_ability(index)
	if ability != null and ability.cast_type == Ability.CastType.UNIT_TARGET:
		pending_ability_target = index
		_hud.show_targeting_prompt(ability.ability_name)
	else:
		SelectionManager.cast_ability(index)


func first_selected_ability(index: int) -> Ability:
	for unit in SelectionManager.selected_units:
		if index >= 0 and index < unit.resolved_abilities.size() and unit.resolved_abilities[index] != null:
			return unit.resolved_abilities[index]
	return null


func resolve_pending_ability_target(screen_position: Vector2) -> void:
	var index := pending_ability_target
	cancel_pending_ability_target() # clears state/hides the prompt regardless of whether the click actually hits a unit
	if DebugInspector.try_select_at(_camera, screen_position):
		SelectionManager.cast_ability_at_target(index, DebugInspector.selected_unit)


func cancel_pending_ability_target() -> void:
	pending_ability_target = -1
	_hud.hide_targeting_prompt()


## PLACEMENT-only: U/I buy a Blood Tournament shop upgrade (see
## Resources/*Upgrade.tres) for selected_player's account, applied to
## every unit in every squad they deploy from now on (see
## GameManager.buy_roster_upgrade()). No unit-targeting/selection needed
## anymore -- nothing is alive to target during PLACEMENT under the
## staging-area deployment model, so unlike the old per-unit flow this
## replaced, there's no legal target to check ownership of at purchase
## time at all.
func handle_placement_key(event: InputEventKey) -> void:
	var is_slot_0 := event.is_action_pressed("buy_upgrade_0")
	var is_slot_1 := event.is_action_pressed("buy_upgrade_1")
	if not is_slot_0 and not is_slot_1:
		return
	var index := 0 if is_slot_0 else 1
	if index < _UPGRADES.size() and GameManager.buy_roster_upgrade(selected_player, _UPGRADES[index]):
		_refresh_gold_display.call()


## PLACEMENT-only pickup for a unit selected_player already owns (see
## dragging_unit's doc comment) -- reuses DebugInspector's own raycast/
## layer instead of a second one, so this is also why clicking a unit
## already short-circuits try_place_unit() via DebugInspector.try_select_at()
## in on_left_release(): that early-return existed before this feature
## and is what stopped a click from ever placing a fresh unit on top of
## one that's already there.
func try_start_unit_drag(screen_position: Vector2) -> void:
	dragging_unit = null
	if GameManager.battle_state != GameManager.BattleState.PLACEMENT:
		return
	if not DebugInspector.try_select_at(_camera, screen_position):
		return
	if DebugInspector.selected_unit.player == selected_player:
		dragging_unit = DebugInspector.selected_unit


## Teleports dragging_unit under the cursor every frame the drag continues.
## No path/physics involved -- Unit._physics_process() clamps position to
## the arena bounds and snaps Y to _resting_height() every frame regardless
## of battle_state, so a drag that goes past the edge or over uneven resting
## height just corrects itself for free.
func drag_unit_to(screen_position: Vector2) -> void:
	var ray_origin := _camera.project_ray_origin(screen_position)
	var ray_direction := _camera.project_ray_normal(screen_position)
	var hit_position = GROUND_PLANE.intersects_ray(ray_origin, ray_direction)
	if hit_position != null:
		dragging_unit.global_position = hit_position


## Classic-mode-only now: under Blood Tournament (current_mode.uses_economy())
## there's no arena position to choose anymore -- a purchase just joins
## the roster/line-up (see on_unit_type_selected()) and deploys from a
## fixed per-team anchor once battle starts, not wherever you clicked. A
## plain single-battle match is unaffected: click a spot, place one unit
## there, exactly as before.
func try_place_unit(screen_position: Vector2) -> void:
	if selected_stats == null or GameManager.current_mode.uses_economy():
		return

	var ray_origin := _camera.project_ray_origin(screen_position)
	var ray_direction := _camera.project_ray_normal(screen_position)
	var hit_position = GROUND_PLANE.intersects_ray(ray_origin, ray_direction)
	if hit_position == null:
		return

	GameManager.spawn_unit(selected_stats, selected_player, hit_position)


## PLACEMENT-only: right-click on a unit selected_player owns sells it
## (see GameManager.sell_unit()) instead of the BATTLE right-click's
## attack/follow/attack-move routing, which only makes sense once a battle
## is actually running. Also removes the matching entry from the
## player's roster (Array.erase() removes the first match, a harmless
## no-op if it isn't there -- e.g. outside Blood Tournament, where
## nothing ever gets appended to begin with) -- otherwise a sold unit
## would just respawn again next round regardless of being sold.
func try_sell_unit_at(screen_position: Vector2) -> void:
	if not DebugInspector.try_select_at(_camera, screen_position):
		return
	var unit := DebugInspector.selected_unit
	if unit.player == selected_player:
		unit.player.roster.erase(unit.stats)
		GameManager.sell_unit(unit)
		_refresh_gold_display.call()


## Under Blood Tournament, clicking a unit-type button doesn't just pick
## what a later arena click would place (there's no arena click for this
## anymore, see try_place_unit()) -- it buys one slot immediately,
## appending to the roster/line-up. Classic mode keeps the original
## two-step "pick a type, then click where" flow, so selected_stats is
## still tracked either way.
func on_unit_type_selected(stats: UnitStats) -> void:
	selected_stats = stats
	if GameManager.current_mode.uses_economy():
		try_buy_for_roster(stats)


func try_buy_for_roster(stats: UnitStats) -> void:
	if not selected_player.can_afford(stats.cost):
		return
	selected_player.spend(stats.cost)
	selected_player.roster.append(stats)
	_refresh_gold_display.call()


## Doubles as "which side am I playing as" for this single-machine
## prototype: the Blue/Red toggle picks both who newly-placed units
## belong to (selected_player) and whose units SelectionManager will
## let you select/command (local_player) -- there's no separate "spawn
## for both sides, but only ever play as Blue" mode. A real lobby/second
## client (Phase 8) replaces this with actual per-player identity instead
## of one shared toggle switching both.
func on_team_selected(team_id: int) -> void:
	selected_player = GameManager.get_player(team_id)
	SelectionManager.local_player = selected_player
	_refresh_gold_display.call()
