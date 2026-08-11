## Player-facing unit selection and order issuing: single click, drag-box,
## shift-add, control groups (1-9), and applying the move/attack-move/
## stop/hold/patrol/follow orders (see Unit.order_*) to whatever's
## currently selected.
##
## Separate from DebugInspector (Scripts/DebugInspector.gd), which is a
## read-only debug overlay for inspecting any one unit regardless of who
## owns it -- this is the actual gameplay selection a player commands
## units through, and it enforces ownership (see local_player), which
## the debug tool deliberately does not.
extends Node

## Physics layer Unit's CollisionShape3D lives on (see Unit.tscn) --
## matches DebugInspector.UNITS_PHYSICS_LAYER; duplicated rather than
## shared since the two tools are intentionally independent.
const UNITS_PHYSICS_LAYER := 2

## Green, not DebugInspector.SELECTION_COLOR's yellow -- the two rings
## mean different things (this is "you can command this," that's "the
## debug panel is inspecting this") and can legitimately both be visible
## on the same unit at once, so they need to read as visually distinct.
const _INDICATOR_COLOR := Color(0.3, 1.0, 0.5)

signal selection_changed(units: Array[Unit])

## Which Player's units this SelectionManager will let the local input
## select/command. Hardcoded to GameManager's default Blue slot for now --
## the same interim assumption Main.gd's placement flow already makes for
## a single local player. A real lobby (Phase 8) replaces this with
## actual per-client identity; nothing else here should need to change
## when it does, since every method already funnels ownership checks
## through this one property.
##
## Set in _ready(), not a field initializer -- autoloads are constructed
## in project.godot's [autoload] order, but a field initializer runs at
## construction time, before *any* autoload's own _ready() has run.
## GameManager.players is only populated in GameManager._ready()
## (_register_default_players()), so a field initializer here would
## read it while still empty and silently cache null.
var local_player: Player

var selected_units: Array[Unit] = []

## 1-9 -> Array[Unit]. Godot's own Ctrl/Shift+number shortcuts aren't
## reserved by anything here -- Main.gd owns deciding which physical key
## combo maps to assign vs. recall.
var _control_groups: Dictionary = {}

## One ring per currently-selected unit, pooled and reused as the
## selection grows/shrinks rather than rebuilt every change -- see
## _sync_indicators(). Parented directly to this autoload (a plain Node,
## same as DebugInspector) so they're always in the live tree; setting
## global_position on a Node3D under a non-spatial parent still resolves
## correctly in Godot, the same trick DebugInspector's own indicators
## already rely on.
var _indicator_pool: Array[MeshInstance3D] = []


func _ready() -> void:
	local_player = GameManager.get_player(GameManager.BLUE_TEAM_ID)


## Selection can change without any of this script's own methods being
## called -- a selected unit dying mid-battle on its own being the
## obvious case -- so both pruning and the indicator rings need a
## per-frame pass rather than only updating on select_*()/order_*() calls.
func _process(_delta: float) -> void:
	var size_before_prune := selected_units.size()
	selected_units = selected_units.filter(func(u): return is_instance_valid(u) and u.life_state == Unit.LifeState.ALIVE)
	if selected_units.size() != size_before_prune:
		selection_changed.emit(selected_units)

	_sync_indicators()


func _sync_indicators() -> void:
	while _indicator_pool.size() < selected_units.size():
		_indicator_pool.append(_build_indicator())

	for i in range(_indicator_pool.size()):
		var indicator := _indicator_pool[i]
		if i >= selected_units.size():
			indicator.visible = false
			continue
		var unit := selected_units[i]
		indicator.visible = true
		indicator.global_position = unit.global_position + Vector3(0, 0.03, 0)
		_resize_indicator(indicator, unit.stats.collision_radius)


func _build_indicator() -> MeshInstance3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = _INDICATOR_COLOR
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED

	var ring := TorusMesh.new()
	ring.inner_radius = 0.01
	ring.outer_radius = 0.05
	ring.surface_set_material(0, material)

	var instance := MeshInstance3D.new()
	instance.mesh = ring
	instance.visible = false
	add_child(instance)
	return instance


func _resize_indicator(instance: MeshInstance3D, unit_radius: float) -> void:
	var ring: TorusMesh = instance.mesh
	var radius := unit_radius + 0.2
	ring.inner_radius = maxf(radius - 0.06, 0.01)
	ring.outer_radius = radius + 0.06


func select_single(unit: Unit, add_to_selection: bool = false) -> void:
	if unit.player != local_player:
		return
	if not add_to_selection:
		selected_units.clear()
	elif selected_units.has(unit):
		selected_units.erase(unit) # shift-clicking an already-selected unit toggles it off
		_prune_and_emit()
		return
	selected_units.append(unit)
	_prune_and_emit()


## `screen_rect` must already be normalized (positive size) -- callers
## dragging from an arbitrary corner should build it with Rect2.abs().
func select_in_rect(camera: Camera3D, screen_rect: Rect2, add_to_selection: bool = false) -> void:
	if not add_to_selection:
		selected_units.clear()
	for unit in GameManager.get_all_units():
		if unit.player != local_player or unit.life_state != Unit.LifeState.ALIVE:
			continue
		if _is_behind_camera(camera, unit.global_position):
			continue # unproject_position() doesn't clip against the near plane on its own
		var screen_position := camera.unproject_position(unit.global_position)
		if screen_rect.has_point(screen_position) and not selected_units.has(unit):
			selected_units.append(unit)
	_prune_and_emit()


func _is_behind_camera(camera: Camera3D, world_position: Vector3) -> bool:
	return camera.global_transform.basis.z.dot(world_position - camera.global_position) > 0.0


func clear_selection() -> void:
	if selected_units.is_empty():
		return
	selected_units.clear()
	selection_changed.emit(selected_units)


func assign_control_group(number: int) -> void:
	_control_groups[number] = selected_units.duplicate()


## Replaces the current selection with group `number`'s members still
## alive/valid -- a control group is a snapshot at assign time, so it can
## silently shrink (or, once respawns exist, stay stale) as units die;
## pruning here rather than at assign time is what makes that transparent
## instead of needing its own cleanup pass.
func select_control_group(number: int) -> void:
	if not _control_groups.has(number):
		return
	selected_units = _control_groups[number].filter(
		func(u): return is_instance_valid(u) and u.life_state == Unit.LifeState.ALIVE
	)
	_prune_and_emit()


func order_move(target_position: Vector3, queue: bool = false) -> void:
	for unit in _owned_selection():
		unit.order_move(target_position, queue)


func order_attack_move(target_position: Vector3, queue: bool = false) -> void:
	for unit in _owned_selection():
		unit.order_attack_move(target_position, queue)


func order_attack_unit(enemy: Unit, queue: bool = false) -> void:
	for unit in _owned_selection():
		unit.order_attack_unit(enemy, queue)


func order_stop() -> void:
	for unit in _owned_selection():
		unit.order_stop()


func order_hold() -> void:
	for unit in _owned_selection():
		unit.order_hold()


func order_patrol(target_position: Vector3, queue: bool = false) -> void:
	for unit in _owned_selection():
		unit.order_patrol(target_position, queue)


func order_follow(target_unit: Unit, queue: bool = false) -> void:
	for unit in _owned_selection():
		if unit != target_unit:
			unit.order_follow(target_unit, queue)


## Casts ability slot `index` (0/1/2, the Q/E/R hotkeys in Main.gd) on
## every selected unit that has one there, auto-targeting whatever each
## unit is already fighting (target_enemy), same as autoattacks do --
## NO_TARGET/PASSIVE/AURA ignore the concept of a target entirely. This is
## the auto-target path Main.gd falls back to for anything that isn't a
## UNIT_TARGET ability; see cast_ability_at_target() for the click-to-
## target flow UNIT_TARGET abilities actually use now.
func cast_ability(index: int) -> void:
	for unit in _owned_selection():
		if index < 0 or index >= unit.resolved_abilities.size():
			continue
		var ability: Ability = unit.resolved_abilities[index]
		if ability == null:
			continue
		if ability.cast_type == Ability.CastType.UNIT_TARGET:
			unit.cast_ability(index, unit.target_enemy)
		else:
			unit.cast_ability(index)


## Like cast_ability(), but for the click-to-target flow (see
## Main._pending_ability_target/_resolve_pending_ability_target()) --
## every owned selected unit with a UNIT_TARGET ability in this slot casts
## it at the same explicit `target` instead of whatever each unit's own
## target_enemy happens to be. NO_TARGET/PASSIVE/AURA slots ignore target
## entirely, same as cast_ability() -- this only actually changes behavior
## for UNIT_TARGET.
func cast_ability_at_target(index: int, target: Unit) -> void:
	for unit in _owned_selection():
		if index < 0 or index >= unit.resolved_abilities.size():
			continue
		var ability: Ability = unit.resolved_abilities[index]
		if ability == null:
			continue
		if ability.cast_type == Ability.CastType.UNIT_TARGET:
			unit.cast_ability(index, target)
		else:
			unit.cast_ability(index)


## Ownership enforcement for order issuing: select_single()/select_in_rect()
## already filter to local_player at selection time, but this is the
## actual gate order_*() reads -- if either selection method's filter
## were ever bypassed (a stale reference, a future selection path), a
## unit could never be ordered without also being owned.
func _owned_selection() -> Array[Unit]:
	return selected_units.filter(func(u): return is_instance_valid(u) and u.player == local_player)


func _prune_and_emit() -> void:
	selected_units = selected_units.filter(func(u): return is_instance_valid(u) and u.life_state == Unit.LifeState.ALIVE)
	selection_changed.emit(selected_units)
