## Turns mouse/keyboard input into the right action for the current
## battle_state: unit placement during PLACEMENT, and selection/order-
## issuing (SelectionManager, Scripts/Autoloads/SelectionManager.gd) during BATTLE.
## A click first gets offered to DebugInspector (Scripts/Autoloads/DebugInspector.gd)
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
	preload("res://Resources/Upgrades/HeroicVigorUpgrade.tres"),
	preload("res://Resources/Upgrades/HeroicMightUpgrade.tres"),
]

const _UPGRADE_ACTIONS: Array[String] = ["buy_upgrade_0", "buy_upgrade_1", "buy_upgrade_2", "buy_upgrade_3"]

var _camera: Camera3D
var _hud: Control
var _refresh_gold_display: Callable
var _ghost: PlacementGhost

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
## try_start_unit_drag()/drag_unit_to(). Under classic mode this just
## repositions a placed unit freely. Under Blood Tournament
## (uses_economy()), courtyard squads ARE live Units during PLACEMENT
## (see GameManager.buy_roster_slot_at()) -- dragging one there reorders
## Player.roster to match where it's dropped (see
## _resolve_courtyard_drag()/GameManager.reorder_roster_by_courtyard_depth()),
## gated to only the Builder-owner's own courtyard.
var dragging_unit: Unit = null

## Set alongside dragging_unit only when the drag is a Blood Tournament
## courtyard squad (-1 otherwise, including all of classic mode) -- the
## squad's roster/courtyard_units index and its centroid before the drag
## started (used to revert an invalid drop). See try_start_unit_drag().
var _drag_source_squad_index: int = -1
var _drag_source_center: Vector3 = Vector3.ZERO

## -1 means no ability is awaiting a target. Set only for a UNIT_TARGET
## ability slot (see try_cast_or_target()) -- the next left-click resolves
## it (resolve_pending_ability_target()); right-click or Escape cancels.
var pending_ability_target: int = -1

## True only while a Patrol order (the "order_patrol"/P hotkey -- see
## begin_patrol_targeting()) is awaiting a destination click. Mirrors
## pending_ability_target's own two-step "press a key, then click" shape
## (right-click or Escape cancels either one, see handle_mouse_button()/
## handle_key()) -- SelectionManager.order_patrol() only needs ONE click
## (a destination; each unit already knows its own current position as
## the other end of its patrol route, see Unit.order_patrol()), unlike a
## hypothetical "pick point A, then point B" patrol tool this project
## doesn't build.
var pending_patrol: bool = false

## Non-null only while the Blood Tournament build menu's "click a unit
## type, then click where to place it" flow is awaiting a placement
## click -- see begin_build_placement()/resolve_build_placement()/
## cancel_build_placement(). Same two-step shape pending_ability_target/
## pending_patrol already establish, just confirmed by any left-click
## rather than only a unit/ground-specific one, and only ever armed
## during PLACEMENT (build-menu buttons only exist there).
var _pending_build_stats: UnitStats = null


func _init(camera: Camera3D, hud: Control, refresh_gold_display: Callable, ghost: PlacementGhost) -> void:
	_camera = camera
	_hud = hud
	_refresh_gold_display = refresh_gold_display
	_ghost = ghost
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
		elif pending_patrol:
			cancel_pending_patrol()
		elif _pending_build_stats != null:
			cancel_build_placement()
		elif GameManager.battle_state == GameManager.BattleState.PLACEMENT:
			try_sell_unit_at(event.position)
		else:
			on_right_click(event)


func handle_mouse_motion(event: InputEventMouseMotion) -> void:
	if _pending_build_stats != null:
		_update_ghost_at(event.position)
		return
	if not (event.button_mask & MOUSE_BUTTON_MASK_LEFT):
		return
	if dragging_unit != null:
		# A plain click landing on a unit (to select/inspect it) still fires
		# a mouse-motion event or two from incidental cursor jitter between
		# press and release -- without this threshold, that jitter alone
		# was enough to teleport the unit under the cursor, so simply
		# clicking a courtyard unit visibly shifted it (usability report,
		# 2026-08-11). Reuses _is_left_dragging as a general "past the
		# click threshold" latch -- safe to share with the box-select path
		# below since the two are mutually exclusive (dragging_unit is only
		# ever set during PLACEMENT, box-select only during BATTLE).
		if not _is_left_dragging and _left_drag_start.distance_to(event.position) <= _DRAG_THRESHOLD:
			return
		_is_left_dragging = true
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

	if pending_patrol:
		resolve_pending_patrol(event.position)
		return

	if _pending_build_stats != null:
		resolve_build_placement(event.position)
		return

	if dragging_unit != null:
		# Only reposition if the cursor actually crossed _DRAG_THRESHOLD
		# (handle_mouse_motion() above) -- a plain click that never moved
		# should leave the squad exactly where it was, not reform it around
		# wherever the release-point ground raycast happened to land.
		if _is_left_dragging and GameManager.current_mode.uses_economy() and _drag_source_squad_index != -1:
			_resolve_courtyard_drag(event.position)
		dragging_unit = null
		_drag_source_squad_index = -1
		_is_left_dragging = false
		return

	if _is_left_dragging:
		_is_left_dragging = false
		_hud.hide_drag_box()
		var rect := Rect2(_left_drag_start, Vector2.ZERO).expand(event.position)
		SelectionManager.select_in_rect(_camera, rect, Input.is_key_pressed(KEY_SHIFT))
		return
	_is_left_dragging = false

	if DebugInspector.try_select_at(_camera, event.position):
		var unit := DebugInspector.selected_unit
		# WC3-style "click the building, a build menu appears" -- only for
		# your own Builder (same ownership check try_sell_unit_at() already
		# uses for its is_builder guard); clicking an opponent's Builder is
		# inspection-only, same as clicking any other enemy unit.
		if unit.stats.is_builder and unit.player == selected_player and GameManager.battle_state == GameManager.BattleState.PLACEMENT:
			_hud.show_build_menu()
			return
		_hud.hide_build_menu() # clicking any other unit closes the build menu, same as clicking away
		# Debug-inspecting a unit and being able to command it shouldn't
		# need two separate clicks -- select_single() is a no-op if the
		# hit unit isn't SelectionManager.local_player's, so this is
		# harmless when the click was on an enemy/inspection-only target.
		if GameManager.battle_state == GameManager.BattleState.BATTLE:
			SelectionManager.select_single(DebugInspector.selected_unit, Input.is_key_pressed(KEY_SHIFT))
		return

	_hud.hide_build_menu() # clicking empty ground or dragging also closes it
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


## X = Stop, H = Hold Position, P = Patrol (enters click-to-target mode
## for a destination, same shape as a UNIT_TARGET ability -- see
## begin_patrol_targeting()), Q/E/R = cast ability slot 0/1/2 (see
## UnitStats.abilities -- a NO_TARGET/PASSIVE/AURA slot casts immediately
## same as always; a UNIT_TARGET slot enters click-to-target mode instead
## of auto-targeting, see try_cast_or_target()), Escape cancels a pending
## target/patrol, plain 1-9 = recall a control group, Ctrl+1-9 = assign
## the current selection to one. X/H/P specifically become no-ops during
## auto-battle (GameMode.is_auto_battle()) -- Q/E/R stay reachable since
## try_cast_or_target() has its own auto-battle guard, and 1-9 group
## recall is selection/inspection, not commanding, so it's never gated at
## all.
func handle_key(event: InputEventKey) -> void:
	if event.keycode == KEY_ESCAPE:
		if pending_ability_target != -1:
			cancel_pending_ability_target()
			return
		if pending_patrol:
			cancel_pending_patrol()
			return
		if _pending_build_stats != null:
			cancel_build_placement()
			return
		if _hud.is_build_menu_open():
			_hud.hide_build_menu()
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
	elif event.is_action_pressed("order_patrol") and can_command:
		begin_patrol_targeting()
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
## ability_slot_pressed), not just the Q/E/R hotkeys. A no-op entirely
## during auto-battle, mid-BATTLE -- see GameMode.is_auto_battle().
func try_cast_or_target(index: int) -> void:
	if GameManager.is_battle_active() and GameManager.current_mode.is_auto_battle():
		return
	var ability := first_selected_ability(index)
	if ability != null and ability.cast_type == Ability.CastType.UNIT_TARGET:
		pending_ability_target = index
		_hud.show_targeting_prompt("Select a target for %s" % ability.ability_name)
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


## Closes the roadmap's long-standing "no PATROL hotkey" rough edge --
## Unit.order_patrol()/SelectionManager.order_patrol() were already
## complete and tested, just never wired to input. Only needs to arm the
## "next click is a destination" flag; SelectionManager.order_patrol()
## takes a single Vector3 (each unit patrols between wherever it already
## is and that point, see Unit.order_patrol()), so this needs none of
## pending_ability_target's per-ability lookup, just a bool. A no-op
## entirely during auto-battle, matching every other manual-order hotkey.
func begin_patrol_targeting() -> void:
	if GameManager.current_mode.is_auto_battle():
		return
	pending_patrol = true
	_hud.show_targeting_prompt("Select a Patrol destination")


## Ground-plane raycast, not DebugInspector's unit-raycast
## (resolve_pending_ability_target()'s own target-picking one) -- a
## Patrol destination is a point on the map, never a unit. Shift queues
## it after whatever's already queued, same convention as
## on_right_click()'s attack-move.
func resolve_pending_patrol(screen_position: Vector2) -> void:
	cancel_pending_patrol() # clears state/hides the prompt regardless of whether the click actually hits ground
	var ray_origin := _camera.project_ray_origin(screen_position)
	var ray_direction := _camera.project_ray_normal(screen_position)
	var hit_position = GROUND_PLANE.intersects_ray(ray_origin, ray_direction)
	if hit_position != null:
		SelectionManager.order_patrol(hit_position, Input.is_key_pressed(KEY_SHIFT))


func cancel_pending_patrol() -> void:
	pending_patrol = false
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
	for index in _UPGRADE_ACTIONS.size():
		if event.is_action_pressed(_UPGRADE_ACTIONS[index]):
			if index < _UPGRADES.size() and GameManager.buy_roster_upgrade(selected_player, _UPGRADES[index]):
				_refresh_gold_display.call()
			return


## PLACEMENT-only pickup for a unit selected_player already owns (see
## dragging_unit's doc comment) -- reuses DebugInspector's own raycast/
## layer instead of a second one, so this is also why clicking a unit
## already short-circuits try_place_unit() via DebugInspector.try_select_at()
## in on_left_release(): that early-return existed before this feature
## and is what stopped a click from ever placing a fresh unit on top of
## one that's already there.
func try_start_unit_drag(screen_position: Vector2) -> void:
	# Set here (not just by handle_mouse_button()'s own press branch) so
	# the click-vs-drag distance threshold (handle_mouse_motion()) has a
	# correct origin even when this is called directly (every GUT test
	# that arms a courtyard drag does exactly this, bypassing the real
	# button-press event entirely).
	_left_drag_start = screen_position
	dragging_unit = null
	_drag_source_squad_index = -1
	if GameManager.battle_state != GameManager.BattleState.PLACEMENT:
		return
	if not DebugInspector.try_select_at(_camera, screen_position):
		return
	var unit := DebugInspector.selected_unit
	if unit.player != selected_player:
		return

	if GameManager.current_mode.uses_economy():
		if unit.stats.is_builder:
			return
		var index := _find_courtyard_slot_index(unit)
		if index == -1:
			return
		_drag_source_squad_index = index
		_drag_source_center = _squad_centroid(selected_player.courtyard_units[index])

	dragging_unit = unit


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


## PLACEMENT-only: right-click on a unit selected_player owns sells it,
## instead of the BATTLE right-click's attack/follow/attack-move routing,
## which only makes sense once a battle is actually running.
##
## Under Blood Tournament (uses_economy()), the clicked unit is one member
## of a live courtyard squad standing in for one roster slot -- selling
## has to free the WHOLE squad and remove that one roster entry (see
## GameManager.sell_roster_slot()), not just the single unit actually
## clicked, or the rest of the squad would be orphaned (still alive,
## still registered, but belonging to no roster slot at all). The Builder
## fixture is never sellable -- it's a permanent per-team fixture, not a
## roster slot. Classic mode (no courtyard, nothing ever spawns before
## BATTLE) keeps its original single-unit GameManager.sell_unit() path,
## unchanged, plus its own matching roster.erase() (a harmless no-op
## there since nothing is ever appended to roster outside Blood Tournament).
func try_sell_unit_at(screen_position: Vector2) -> void:
	if not DebugInspector.try_select_at(_camera, screen_position):
		return
	try_sell_unit(DebugInspector.selected_unit)


## Shared by the right-click-a-unit path above and HUD's own explicit
## Sell button (see UI/HUD.gd's sell_requested signal / Main.gd's
## _on_sell_requested()) -- both ultimately just need "sell this specific
## Unit," they differ only in how they identify it (a raycast vs.
## whatever SelectionManager currently reports as selected).
func try_sell_unit(unit: Unit) -> void:
	if unit == null or not is_instance_valid(unit):
		return
	if unit.player != selected_player:
		return
	if unit.stats.is_builder:
		return

	if GameManager.current_mode.uses_economy():
		var index := _find_courtyard_slot_index(unit)
		if index != -1:
			GameManager.sell_roster_slot(selected_player, index)
			_refresh_gold_display.call()
	else:
		unit.player.roster.erase(unit.stats)
		GameManager.sell_unit(unit)
		_refresh_gold_display.call()


## Which of selected_player.courtyard_units[i] a clicked courtyard unit
## belongs to -- -1 if it isn't in any of them (shouldn't happen for a
## unit that passed the ownership check above, under Blood Tournament).
func _find_courtyard_slot_index(unit: Unit) -> int:
	for i in selected_player.courtyard_units.size():
		if selected_player.courtyard_units[i].has(unit):
			return i
	return -1


## Average position of a squad's currently-live members -- used as the
## drag's revert-to center rather than the specific member that happened
## to get clicked, since a non-center member's own position isn't the
## squad's formation center (see GameManager._squad_formation_offset()).
func _squad_centroid(squad: Array) -> Vector3:
	var total := Vector3.ZERO
	var count := 0
	for unit in squad:
		if is_instance_valid(unit):
			total += unit.global_position
			count += 1
	return total / count


## Resolves a Blood Tournament courtyard drag on release: repositions the
## whole squad (GameManager.reposition_courtyard_squad()) to reform
## around the drop point if it's inside selected_player's own courtyard,
## then reorders Player.roster to match the new front-to-back
## arrangement -- otherwise reverts the squad to _drag_source_center
## (its pre-drag position) with no reorder, same "can't place somewhere
## invalid, stay put" convention _update_ghost_at()'s courtyard check
## established for build placement.
func _resolve_courtyard_drag(screen_position: Vector2) -> void:
	var ray_origin := _camera.project_ray_origin(screen_position)
	var ray_direction := _camera.project_ray_normal(screen_position)
	var hit_position = GROUND_PLANE.intersects_ray(ray_origin, ray_direction)
	if hit_position == null or not CrossArenaMap.is_in_teams_courtyard(selected_player.team_id, hit_position):
		GameManager.reposition_courtyard_squad(selected_player, _drag_source_squad_index, _drag_source_center)
		return
	GameManager.reposition_courtyard_squad(selected_player, _drag_source_squad_index, hit_position)
	GameManager.reorder_roster_by_courtyard_depth(selected_player)


## Under Blood Tournament, clicking a unit-type button doesn't just pick
## what a later arena click would place (there's no arena click for this
## anymore, see try_place_unit()) -- it buys one slot immediately,
## appending to the roster/line-up. Classic mode keeps the original
## two-step "pick a type, then click where" flow, so selected_stats is
## still tracked either way.
func on_unit_type_selected(stats: UnitStats) -> void:
	selected_stats = stats
	if GameManager.current_mode.uses_economy():
		begin_build_placement(stats)


## Arms the ghost-preview click-to-place flow instead of buying
## immediately -- see _pending_build_stats' own doc comment. The actual
## purchase only happens once resolve_build_placement() confirms a
## legal spot; affordability is re-checked there too (via
## GameManager.buy_roster_slot_at()), this is just what makes the ghost
## appear. Only reachable while _hud's build menu is open (its buttons
## are the only thing that calls this), i.e. only during PLACEMENT.
func begin_build_placement(stats: UnitStats) -> void:
	_pending_build_stats = stats
	_ghost.show_for(stats, selected_player.color)


## Raycasts the ground plane under the cursor and moves the ghost there,
## tinting it invalid (red) once outside selected_player's own courtyard
## -- confirming there would be a no-op, not a cancel, so the tint is the
## only feedback the player gets that a given spot won't work.
func _update_ghost_at(screen_position: Vector2) -> void:
	var ray_origin := _camera.project_ray_origin(screen_position)
	var ray_direction := _camera.project_ray_normal(screen_position)
	var hit_position = GROUND_PLANE.intersects_ray(ray_origin, ray_direction)
	if hit_position == null:
		return
	_ghost.move_to(hit_position)
	var valid := CrossArenaMap.is_in_teams_courtyard(selected_player.team_id, hit_position)
	_ghost.set_valid(valid, selected_player.color)


## Confirms the ghost-armed purchase at the clicked ground position, only
## if it's inside selected_player's own courtyard -- an out-of-bounds
## click is a silent no-op (stays armed) rather than a cancel, matching
## "can't place somewhere invalid" RTS convention. Disarms on a
## successful buy; a second squad means clicking the build-menu button
## again (no shift-queue in this pass).
func resolve_build_placement(screen_position: Vector2) -> void:
	var ray_origin := _camera.project_ray_origin(screen_position)
	var ray_direction := _camera.project_ray_normal(screen_position)
	var hit_position = GROUND_PLANE.intersects_ray(ray_origin, ray_direction)
	if hit_position == null:
		return
	if not CrossArenaMap.is_in_teams_courtyard(selected_player.team_id, hit_position):
		return
	if not GameManager.buy_roster_slot_at(selected_player, _pending_build_stats, hit_position):
		return
	_refresh_gold_display.call()
	cancel_build_placement()


func cancel_build_placement() -> void:
	_pending_build_stats = null
	_ghost.hide_ghost()


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
