## A single combat unit: a primitive-mesh body that fights automatically
## once GameManager enters the BATTLE state.
##
## Seeks target_enemy via NavigationAgent3D avoidance (RVO) rather than a
## raw straight line, so units route around blocking allies instead of
## queuing up behind them. Unit is a CharacterBody3D and moves via
## move_and_slide(), so Godot's physics server also resolves any overlap
## avoidance didn't fully avoid -- no custom overlap code here at all.
class_name Unit
extends CharacterBody3D

## killer is the DamageInstance.source of the killing blow; may be null
## (environmental/scripted damage, or the unit was freed some other way).
signal died(unit: Unit, killer: Unit)
## Emitted after mitigation is applied, on every hit that connects --
## GameManager listens for this to reset its stalemate timer, and it's
## the natural hook point for future damage-meter/on-hit UI.
signal damaged(unit: Unit, instance: DamageInstance, damage_dealt: float)

enum LifeState { ALIVE, DEAD }

## MOVE never fights (pure repositioning); ATTACK_MOVE/PATROL/FOLLOW all
## fight anything that comes into range along the way. There's no NONE
## entry -- current_order == null *is* "no order issued," meaning fall
## back to the pre-Sprint-N default of autonomously seeking and attacking
## the nearest enemy the instant BATTLE starts. That default is exactly
## today's pre-orders behavior, so a unit nobody ever gives an order to
## behaves identically to before this system existed.
enum OrderType { MOVE, ATTACK_MOVE, STOP, HOLD, PATROL, FOLLOW }

## One player-issued command. `target_position` drives MOVE/ATTACK_MOVE/
## PATROL; `target_unit` drives FOLLOW (and is set for an attack order on
## a specific enemy, so it can be chased instead of just its last known
## position). `patrol_origin` is captured at issue time, not passed in --
## see order_patrol().
class Order:
	var type: OrderType
	var target_position: Vector3
	var target_unit: Unit
	var patrol_origin: Vector3

	func _init(p_type: OrderType, p_target_position: Vector3 = Vector3.ZERO, p_target_unit: Unit = null, p_patrol_origin: Vector3 = Vector3.ZERO) -> void:
		type = p_type
		target_position = p_target_position
		target_unit = p_target_unit
		patrol_origin = p_patrol_origin

const _PROJECTILE_SCENE: PackedScene = preload("res://Scenes/Projectile.tscn")

const _AVOIDANCE_NEIGHBOR_DISTANCE := 6.0
const _ARRIVAL_EPSILON := 0.3 ## Horizontal distance (m) within which a MOVE/ATTACK_MOVE/PATROL destination counts as "reached."
const _KNOCKBACK_DURATION := 0.6 ## Seconds from launch to landing.
## How long a unit is immune to a *new* stun after one wears off --
## simplified stand-in for real diminishing returns (WC3 halves each
## successive CC duration within a window; this just blocks the next one
## outright for a bit instead). Same juggling problem PR #4's knockback
## review flagged, but for Effect-based stun rather than positional
## knockback (which already has its own, separate immunity -- see
## apply_knockback()'s doc comment; the two don't share a mechanism
## because one is positional and this one is Effect/CC-based).
const _STUN_IMMUNITY_DURATION := 1.0
## How long a corpse lingers -- collision disabled, no longer targetable,
## but still visible -- before being freed. No respawn hook yet (no
## heroes exist); this is purely the "corpse" half of "corpse/decay or
## respawn," so a future hero revive can intercept before the free
## without take_damage()/die() needing another signature change.
const _CORPSE_DECAY_DURATION := 3.0

@export var stats: UnitStats

var player: Player
var life_state: LifeState = LifeState.ALIVE
## Per-instance runtime stats derived from `stats` -- see StatBlock. All
## combat math reads this, never `stats` directly, so a future buff/debuff
## never leaks across units sharing the same archetype Resource.
var stat_block: StatBlock
var current_health: float
var target_enemy: Unit = null
## Pre-avoidance seek velocity, toward the *next* NavigationMesh waypoint
## on the way to wherever this unit is actually trying to go -- not
## necessarily a straight line to the final destination. Read by
## DebugInspector. See _seek_position()/_physics_process().
var desired_velocity: Vector3 = Vector3.ZERO
## This frame's real pathfinding destination and whether one was set at
## all -- see _seek_position(). Reset every frame in _physics_process();
## an untouched _is_seeking == false means "anchor target_position to my
## own current position," not "path to Vector3.ZERO."
var _seek_destination: Vector3 = Vector3.ZERO
var _is_seeking: bool = false

## null means "no order issued -- use the default autonomous AI." See
## OrderType. Set via order_move()/order_attack_move()/etc, never
## directly, so _order_queue and _patrol_forward always stay consistent
## with it.
var current_order: Order = null

var _attack_cooldown: float = 0.0
## > 0.0 while mid-swing on a committed attack (see UnitStats.attack_windup) --
## _windup_target is the enemy locked in at the moment the swing started,
## used instead of a possibly-since-changed target_enemy when the hit
## actually lands, so a re-target mid-swing can't redirect an already-
## committed hit onto someone else.
var _windup_remaining: float = 0.0
var _windup_target: Unit = null
var _health_bar: HealthBar
var _status_indicator: UnitStatusMarker
## The mesh's own material -- stored so die()/_physics_process()'s corpse
## tick can darken it toward black over _CORPSE_DECAY_DURATION, instead of
## a corpse just sitting there at full team color until it vanishes.
var _body_material: StandardMaterial3D
var _body_color_at_death: Color
var _nav_agent: NavigationAgent3D
var _order_queue: Array[Order] = []
var _patrol_forward: bool = true

## Timed/permanent Effects currently on this unit -- see Effect.gd and
## apply_effect(). Anything with a stat modifier also has a matching
## StatBlock.Modifier alive on stat_block for as long as it's in here.
var _active_effects: Array[Effect] = []
var _stun_immunity_remaining: float = 0.0

## Ability slot index (0/1/2, matching stats.abilities) -> remaining
## cooldown seconds. Absent/0 means ready.
var _ability_cooldowns: Dictionary = {}

## Re-ticking stats.aura_ability every physics frame would allocate a
## fresh Effect 60x/sec per aura-bearing unit for no benefit -- REFRESH
## stacking (Effect's own default) only needs to land often enough that
## the buff never actually expires on someone standing in range.
const _AURA_TICK_INTERVAL := 0.25
var _aura_tick_elapsed: float = 0.0

var _decay_elapsed: float = 0.0

var _is_airborne: bool = false
var _knockback_elapsed: float = 0.0
var _knockback_start: Vector3
var _knockback_direction: Vector3
var _knockback_distance: float
var _knockback_peak_height: float

@onready var _mesh_instance: MeshInstance3D = $MeshInstance3D
@onready var _collision_shape: CollisionShape3D = $CollisionShape3D

## Only meaningful when stats.is_hero is true -- see gain_xp(). Every
## non-hero unit just carries these unused defaults.
var level: int = 1
var xp: float = 0.0
## Flat, not scaled by the killed unit's cost/tier -- deliberately simple
## for this first Heroes slice (roadmap Phase 4), matching how every other
## v1 system in this project ships crude-but-real rather than fully tuned.
const XP_PER_KILL := 50.0


## Called by GameManager right after the unit is added to the scene tree.
func setup(new_stats: UnitStats, new_player: Player) -> void:
	stats = new_stats
	player = new_player
	stat_block = StatBlock.from_archetype(stats)
	current_health = stat_block.max_health()
	_build_appearance()
	_build_avoidance()
	_apply_passive_abilities()


## Pure repositioning -- never attacks, even if an enemy comes into range
## along the way. Clears current_order on arrival (see
## _move_toward_and_clear_when_arrived()), so the unit falls back to
## default autonomous behavior afterward rather than freezing in place.
func order_move(target_position: Vector3, queue: bool = false) -> void:
	_issue_order(Order.new(OrderType.MOVE, target_position), queue)


## Moves toward target_position, but stops to fight anything that comes
## into attack range along the way -- see _process_order().
func order_attack_move(target_position: Vector3, queue: bool = false) -> void:
	_issue_order(Order.new(OrderType.ATTACK_MOVE, target_position), queue)


## Directly targets `enemy` (chasing it specifically, not just its
## position at order time) rather than whatever _update_target() would
## otherwise autonomously pick.
func order_attack_unit(enemy: Unit, queue: bool = false) -> void:
	_issue_order(Order.new(OrderType.ATTACK_MOVE, enemy.global_position, enemy), queue)


## Cancels the order queue and goes fully idle: no movement, no
## auto-acquiring a target. Distinct from order_hold() (see there).
func order_stop() -> void:
	_issue_order(Order.new(OrderType.STOP))


## Like order_stop(), but still fights anything that comes into
## attack_range on its own -- it just never moves to chase. The classic
## RTS "Hold Position."
func order_hold() -> void:
	_issue_order(Order.new(OrderType.HOLD))


## Bounces between target_position and wherever the unit is right now
## (captured as patrol_origin), fighting anything encountered along the
## way -- same engage behavior as ATTACK_MOVE, just looping between two
## points instead of stopping at one.
func order_patrol(target_position: Vector3, queue: bool = false) -> void:
	_issue_order(Order.new(OrderType.PATROL, target_position, null, global_position), queue)


## Keeps pace with target_unit, fighting anything that comes into
## attack_range along the way. Ends on its own if target_unit stops
## being valid (dies, is freed) -- see _process_order().
func order_follow(target_unit: Unit, queue: bool = false) -> void:
	_issue_order(Order.new(OrderType.FOLLOW, Vector3.ZERO, target_unit), queue)


func _issue_order(order: Order, queue: bool = false) -> void:
	if queue and current_order != null:
		_order_queue.append(order)
		return
	_order_queue.clear()
	current_order = order
	_patrol_forward = true


## Drops the current order (and any queued after it) and returns to the
## default autonomous AI -- the same state a unit starts in before any
## order is ever issued.
func clear_order() -> void:
	current_order = null
	_order_queue.clear()


func _advance_order_queue() -> void:
	current_order = _order_queue.pop_front() if not _order_queue.is_empty() else null
	_patrol_forward = true


# ---------------------------------------------------------------------
# Effects (see Effect.gd)
# ---------------------------------------------------------------------

## Applies `effect` to this unit, respecting its stack_rule against any
## existing effect with the same id. A STUN effect is silently dropped
## outright while stun immunity is active -- see _STUN_IMMUNITY_DURATION.
func apply_effect(effect: Effect) -> void:
	if effect.cc_flag == Effect.CCFlag.STUN and _stun_immunity_remaining > 0.0:
		return

	var existing := _find_effect_by_id(effect.id)
	if existing != null:
		match effect.stack_rule:
			Effect.StackRule.REFRESH:
				existing.elapsed = 0.0
				return
			Effect.StackRule.STRONGEST_WINS:
				if effect.magnitude <= existing.magnitude:
					return
				_remove_effect(existing)
			Effect.StackRule.STACK:
				pass # multiple simultaneous instances with the same id are allowed

	_active_effects.append(effect)
	if effect.stat != "":
		stat_block.add_modifier(effect, effect.stat, effect.stat_op, effect.stat_value)


func remove_effects_from_source(source: Variant) -> void:
	for effect in _active_effects.duplicate():
		if effect.source == source:
			_remove_effect(effect)


func is_stunned() -> bool:
	return _has_cc_flag(Effect.CCFlag.STUN)


func is_rooted() -> bool:
	return _has_cc_flag(Effect.CCFlag.ROOT)


func is_silenced() -> bool:
	return _has_cc_flag(Effect.CCFlag.SILENCE)


func is_invulnerable() -> bool:
	return _has_cc_flag(Effect.CCFlag.INVULNERABLE)


func is_ethereal() -> bool:
	return _has_cc_flag(Effect.CCFlag.ETHEREAL)


func _has_cc_flag(flag: Effect.CCFlag) -> bool:
	for effect in _active_effects:
		if effect.cc_flag == flag:
			return true
	return false


## Public read-only lookup -- used by DebugInspector-style tooling and
## tests that need to inspect a specific active Effect's state (e.g.
## elapsed time) directly, rather than inferring it indirectly through
## timing.
func get_effect(id: String) -> Effect:
	return _find_effect_by_id(id)


## Read-only snapshot for HUD display (see UI/HUD.gd's buff/debuff row) --
## a duplicate, not the live array, so a caller iterating it is never
## upset by _tick_effects()/apply_effect() mutating the original mid-loop.
func get_active_effects() -> Array[Effect]:
	return _active_effects.duplicate()


func _find_effect_by_id(id: String) -> Effect:
	for effect in _active_effects:
		if effect.id == id:
			return effect
	return null


func _remove_effect(effect: Effect) -> void:
	_active_effects.erase(effect)
	if effect.stat != "":
		stat_block.remove_modifiers_from_source(effect)


func _tick_effects(delta: float) -> void:
	_stun_immunity_remaining = maxf(_stun_immunity_remaining - delta, 0.0)

	for effect in _active_effects.duplicate():
		if effect.duration <= 0.0:
			continue # permanent -- only removed by remove_effects_from_source() or clear_all_effects()
		effect.elapsed += delta
		if effect.elapsed >= effect.duration:
			var was_stun: bool = effect.cc_flag == Effect.CCFlag.STUN
			_remove_effect(effect)
			if was_stun:
				_stun_immunity_remaining = _STUN_IMMUNITY_DURATION

	_refresh_status_indicator()


## Priority order for which single active Effect's color gets shown when
## more than one is active at once -- a CC flag always wins over a plain
## stat modifier, since losing control of your unit is the thing a player
## most needs to notice; arbitrary among the CC flags themselves. One
## marker, not a full per-effect icon stack -- see UnitStatusMarker.gd's
## own doc comment for why.
const _CC_STATUS_COLORS := {
	Effect.CCFlag.STUN: Color(1.0, 0.85, 0.1),
	Effect.CCFlag.SILENCE: Color(0.6, 0.2, 0.9),
	Effect.CCFlag.ROOT: Color(0.45, 0.3, 0.1),
	Effect.CCFlag.ETHEREAL: Color(0.7, 0.9, 1.0),
	Effect.CCFlag.INVULNERABLE: Color(0.9, 0.9, 0.95),
}
const _BUFF_STATUS_COLOR := Color(0.3, 1.0, 0.4)
const _DEBUFF_STATUS_COLOR := Color(1.0, 0.3, 0.3)


func _refresh_status_indicator() -> void:
	for effect in _active_effects:
		if _CC_STATUS_COLORS.has(effect.cc_flag):
			_status_indicator.show_status(_CC_STATUS_COLORS[effect.cc_flag])
			return
	for effect in _active_effects:
		if effect.stat != "":
			_status_indicator.show_status(_BUFF_STATUS_COLOR if _is_buff(effect) else _DEBUFF_STATUS_COLOR)
			return
	_status_indicator.hide_status()


## MULTIPLY and ADD need different "is this actually helping me" math --
## a MULTIPLY of 0.5 (Frost Bolt's slow) is a debuff despite being a
## positive number, which a naive stat_value >= 0.0 check would miss.
func _is_buff(effect: Effect) -> bool:
	if effect.stat_op == StatBlock.ModifierOp.MULTIPLY:
		return effect.stat_value >= 1.0
	return effect.stat_value >= 0.0


func clear_all_effects() -> void:
	for effect in _active_effects.duplicate():
		_remove_effect(effect)


# ---------------------------------------------------------------------
# Abilities (see Ability.gd)
# ---------------------------------------------------------------------

func _tick_aura(delta: float) -> void:
	if stats.aura_ability == null:
		return
	_aura_tick_elapsed += delta
	if _aura_tick_elapsed < _AURA_TICK_INTERVAL:
		return
	_aura_tick_elapsed = 0.0
	stats.aura_ability.apply_aura(self)


func _apply_passive_abilities() -> void:
	for ability in stats.abilities:
		if ability != null and ability.cast_type == Ability.CastType.PASSIVE:
			ability.cast_passive(self)


func _tick_ability_cooldowns(delta: float) -> void:
	for index in _ability_cooldowns.keys():
		_ability_cooldowns[index] = maxf(_ability_cooldowns[index] - delta, 0.0)


## Read-only lookup for HUD display (see UI/HUD.gd's ability hotbar) --
## 0.0 for a slot never cast yet (not in the dictionary at all), same as
## cast_ability()'s own read of it.
func get_ability_cooldown_remaining(index: int) -> float:
	return _ability_cooldowns.get(index, 0.0)


## No-op for a non-hero unit -- XP/leveling only exists when
## stats.is_hero is true (see GameManager._on_unit_died(), the only
## caller). A while loop, not a single if, so one big grant can carry a
## hero through more than one level at once.
func gain_xp(amount: float) -> void:
	if not stats.is_hero:
		return
	xp += amount
	while xp >= get_xp_to_next_level():
		xp -= get_xp_to_next_level()
		level += 1
		_on_level_up()


func get_xp_to_next_level() -> float:
	return 100.0 * level


## Flat per-level growth (not a percentage -- keeps this simple and
## avoids any compounding-multiplication edge cases), then a full heal --
## the classic RTS/MOBA "leveling up tops you off" convention, rather than
## leaving a hero at a now-smaller fraction of a bigger health pool.
func _on_level_up() -> void:
	stat_block.base_max_health += 20.0
	stat_block.base_damage += 3.0
	stat_block.base_armor += 1.0
	current_health = stat_block.max_health()
	_health_bar.set_fraction(1.0)


## Triggers stats.abilities[index] (Q/W/E in Main.gd's input wiring).
## Returns false (and does nothing) if the slot is empty, on cooldown,
## not yet unlocked (stats.is_hero only -- see stats.ability_unlock_levels),
## not a player-triggerable cast type, this unit can't currently act
## (stunned/silenced), or -- for UNIT_TARGET -- target is missing/out of
## range, so callers can tell a no-op from a successful cast.
func cast_ability(index: int, target: Unit = null) -> bool:
	if index < 0 or index >= stats.abilities.size():
		return false
	var ability: Ability = stats.abilities[index]
	if ability == null or ability.cast_type == Ability.CastType.PASSIVE or ability.cast_type == Ability.CastType.ON_HIT or ability.cast_type == Ability.CastType.AURA:
		return false
	if stats.is_hero and index < stats.ability_unlock_levels.size() and level < stats.ability_unlock_levels[index]:
		return false
	if life_state != LifeState.ALIVE or is_stunned() or is_silenced():
		return false
	if _ability_cooldowns.get(index, 0.0) > 0.0:
		return false

	match ability.cast_type:
		Ability.CastType.NO_TARGET:
			ability.cast_no_target(self)
		Ability.CastType.UNIT_TARGET:
			if target == null or not is_instance_valid(target) or target.life_state != LifeState.ALIVE:
				return false
			if _distance_to_target_edge(target) > ability.range:
				return false
			ability.cast_unit_target(self, target)

	_ability_cooldowns[index] = ability.cooldown
	return true


## Auto-battle only (see GameMode.is_auto_battle()) -- Blood Tournament
## units have no player pressing Q/W/E, so ability use has to happen on
## its own. Deliberately simple, matching this project's "prove the
## mechanic, not a smart AI" scope elsewhere: tries every equipped
## ability slot in order whenever this unit has an enemy actively
## engaged (target_enemy != null) -- cast_ability() itself already
## rejects anything not actually castable right now (on cooldown, wrong
## cast type, out of range, hero level-gated, stunned/silenced), so this
## needs no separate "is this a good time" heuristic beyond that.
func _maybe_auto_cast_abilities() -> void:
	if target_enemy == null:
		return
	for index in stats.abilities.size():
		cast_ability(index, target_enemy)


func _build_appearance() -> void:
	var mesh: Mesh
	match stats.mesh_shape:
		"Capsule":
			var capsule := CapsuleMesh.new()
			capsule.radius = stats.mesh_size.x
			capsule.height = stats.mesh_size.y
			mesh = capsule
		"Cone":
			var cone := CylinderMesh.new()
			cone.top_radius = 0.0
			cone.bottom_radius = stats.mesh_size.x
			cone.height = stats.mesh_size.y
			mesh = cone
		_:
			var box := BoxMesh.new()
			box.size = stats.mesh_size
			mesh = box

	_body_material = StandardMaterial3D.new()
	_body_material.albedo_color = player.color
	mesh.surface_set_material(0, _body_material)

	_mesh_instance.mesh = mesh
	# Half the mesh height keeps the unit resting on the ground instead of
	# being centered through the floor.
	_mesh_instance.position.y = stats.mesh_size.y * 0.5

	_build_collision()
	_build_health_bar()
	_build_status_indicator()


func _build_collision() -> void:
	var shape := CapsuleShape3D.new()
	shape.radius = stats.collision_radius
	# A capsule's height must be at least 2x its radius (Godot clamps
	# otherwise); maxf keeps this valid regardless of how mesh_size or
	# collision_radius get tuned later.
	shape.height = maxf(stats.mesh_size.y, stats.collision_radius * 2.0)
	_collision_shape.shape = shape
	_collision_shape.position.y = stats.mesh_size.y * 0.5


func _build_health_bar() -> void:
	_health_bar = HealthBar.new()
	_health_bar.position.y = stats.mesh_size.y + 0.35
	add_child(_health_bar)


func _build_status_indicator() -> void:
	_status_indicator = UnitStatusMarker.new()
	_status_indicator.position.y = stats.mesh_size.y + 0.65
	add_child(_status_indicator)


func _build_avoidance() -> void:
	_nav_agent = NavigationAgent3D.new()
	_nav_agent.radius = stats.collision_radius
	_nav_agent.max_speed = stat_block.move_speed()
	_nav_agent.neighbor_distance = _AVOIDANCE_NEIGHBOR_DISTANCE
	_nav_agent.avoidance_enabled = true
	# Godot's default (1.0m) is looser than this game's own tolerances --
	# attack_range is as low as 0.9m and _ARRIVAL_EPSILON is 0.3m. Left
	# at the default, NavigationAgent3D considers itself "close enough"
	# well before either of those, and get_next_path_position() starts
	# returning the agent's own current position (no further progress
	# needed, as far as it's concerned) -- which reads as the unit
	# getting permanently stuck just short of anything closer than 1m.
	_nav_agent.target_desired_distance = 0.1
	add_child(_nav_agent)
	_nav_agent.velocity_computed.connect(_on_safe_velocity_computed)


func _physics_process(delta: float) -> void:
	if life_state == LifeState.DEAD:
		_decay_elapsed += delta
		_body_material.albedo_color = _body_color_at_death.lerp(Color.BLACK, clampf(_decay_elapsed / _CORPSE_DECAY_DURATION, 0.0, 1.0))
		if _decay_elapsed >= _CORPSE_DECAY_DURATION:
			queue_free()
		return

	_tick_effects(delta)
	_tick_ability_cooldowns(delta)
	_tick_aura(delta)

	if _is_airborne:
		_process_knockback(delta)
		return

	desired_velocity = Vector3.ZERO
	_is_seeking = false
	# Kept in sync every frame (not just at spawn) so a future move_speed
	# buff/debuff actually changes how fast avoidance lets this unit go.
	_nav_agent.max_speed = stat_block.move_speed()

	# Stunned: fully disabled -- no movement, no attacking, no orders
	# processed at all (they just wait; an order issued while stunned
	# still applies once it wears off, current_order is untouched).
	if not is_stunned():
		var is_battling := GameManager.battle_state == GameManager.BattleState.BATTLE and current_health > 0.0
		if is_battling:
			if current_order != null:
				_process_order(delta)
			else:
				_update_target()
				if target_enemy != null:
					if _distance_to_target_edge(target_enemy) > stat_block.attack_range():
						_seek_target()
					else:
						_attack(delta)
				if GameManager.current_mode.is_auto_battle():
					_maybe_auto_cast_abilities()

		# Rooted: can still attack (handled above, attacking doesn't move
		# anything) but never seeks/chases -- cancel the seek itself
		# rather than the desired_velocity it would produce, since that's
		# computed below from _is_seeking, not set directly by the
		# branches above anymore (see _seek_position()'s doc comment).
		if is_rooted():
			_is_seeking = false

	# target_position drives real pathfinding, against Main.tscn's
	# NavigationRegion3D, whenever something upstream actually called
	# _seek_position() this frame; anchored to the unit's own current
	# position otherwise. Still requested every physics frame regardless
	# of _is_seeking -- avoidance won't produce a non-zero safe_velocity
	# at all without a target_position each frame (undocumented on the
	# property itself), which is what keeps it resolving resting overlap
	# (e.g. units placed too close together) for a unit that isn't
	# seeking anything right now.
	if _is_seeking:
		if stats.is_flying:
			# Flying units fly *over* ground obstacles by design (same
			# reasoning as _resting_height()/horizontal_distance_to()
			# elsewhere) -- they never query the ground NavigationMesh at
			# all, just seek their destination directly. They also sit
			# well above the mesh's own Y plane, which real path queries
			# handle poorly: NavigationAgent3D reports no path from an
			# agent that elevated, and get_next_path_position() falls
			# back to returning the agent's own position -- a
			# zero-length vector, i.e. permanently stuck.
			var direction := _seek_destination - global_position
			direction.y = 0.0
			desired_velocity = direction.normalized() * stat_block.move_speed() if direction.length() > 0.01 else Vector3.ZERO
			_nav_agent.target_position = global_position + desired_velocity
		else:
			_nav_agent.target_position = _seek_destination
			var next_waypoint := _nav_agent.get_next_path_position()
			var to_waypoint := next_waypoint - global_position
			to_waypoint.y = 0.0
			desired_velocity = to_waypoint.normalized() * stat_block.move_speed() if to_waypoint.length() > 0.01 else Vector3.ZERO
	else:
		_nav_agent.target_position = global_position

	_nav_agent.set_velocity(desired_velocity)


## NavigationAgent3D returns the RVO-adjusted "safe" velocity here, one
## frame after set_velocity() -- this is where movement actually applies.
func _on_safe_velocity_computed(safe_velocity: Vector3) -> void:
	# NavigationAgent3D keeps emitting this every physics frame for as
	# long as avoidance is enabled, whether or not set_velocity() was
	# called that frame -- not a strict one-shot request/response. While
	# airborne, _process_knockback() owns global_position directly; this
	# callback firing anyway would silently clobber it back to resting
	# height every frame if not guarded here.
	if _is_airborne:
		return
	velocity = safe_velocity
	if velocity.length() > 0.05:
		look_at(global_position + velocity, Vector3.UP)

	move_and_slide()
	_clamp_to_arena()

	# move_and_slide() (MOTION_MODE_FLOATING) resolves penetration along
	# whichever axis has the least overlap. Units spawned at or very near
	# the same point have no well-defined *horizontal* separating axis --
	# their capsules are coincident along the vertical axis too -- so the
	# physics server can occasionally choose to push one straight up
	# instead of sideways. Nothing here simulates height or gravity, so
	# any such drift is permanent unless corrected: this line is the fix,
	# re-asserting the resting-height invariant every frame regardless of
	# what direction collision resolution picked. It also forecloses
	# vertical stacking, since two units can never end up on different Y
	# layers long enough to stop colliding horizontally.
	global_position.y = _resting_height()


## Keeps every unit inside whichever arena shape is currently live
## (Main._sync_arena_shape()), including mid-knockback -- nothing else
## stops move_and_slide() or a knockback arc from carrying a unit off the
## edge and into the void permanently, since nothing simulates falling
## once it's off. Only clamps X/Z; Y is owned by _resting_height()/knockback.
func _clamp_to_arena() -> void:
	if GameManager.current_mode.uses_cross_map():
		_clamp_to_cross_arena()
	else:
		global_position.x = clampf(global_position.x, -GameManager.ARENA_HALF_EXTENT, GameManager.ARENA_HALF_EXTENT)
		global_position.z = clampf(global_position.z, -GameManager.ARENA_HALF_EXTENT, GameManager.ARENA_HALF_EXTENT)


## A cross isn't a square, so this isn't a plain clampf() on each axis:
## a point is in-bounds if it's within the vertical bar (|x| <= half_width,
## any z within the outer extent) OR the horizontal bar (|z| <= half_width,
## any x within the outer extent). A point in neither -- a "dead corner"
## diagonally outside both arms -- gets pulled onto whichever bar it's
## already closer to (the axis with the smaller magnitude is the one
## pulled in to half_width; the other is just capped at outer_extent).
func _clamp_to_cross_arena() -> void:
	var half_width := GameManager.CROSS_ARM_HALF_WIDTH
	var outer := GameManager.CROSS_ARM_OUTER_EXTENT
	var x := global_position.x
	var z := global_position.z

	if absf(x) <= half_width:
		z = clampf(z, -outer, outer)
	elif absf(z) <= half_width:
		x = clampf(x, -outer, outer)
	elif absf(x) < absf(z):
		x = clampf(x, -half_width, half_width)
		z = clampf(z, -outer, outer)
	else:
		z = clampf(z, -half_width, half_width)
		x = clampf(x, -outer, outer)

	global_position.x = x
	global_position.z = z


## 0.0 for every ground unit (unchanged Sprint 4 invariant); flight_height
## for a flying one. Knockback overrides this transiently -- see
## apply_knockback() -- rather than changing what a unit rests at.
func _resting_height() -> float:
	return stats.flight_height if stats.is_flying else 0.0


## XZ-plane distance, ignoring Y. Used for every combat-range/targeting
## check instead of Vector3.distance_to() so a flying unit's height
## doesn't count against its reach -- without this, nothing could ever
## get "in range" of a unit sitting flight_height meters up. A no-op for
## any two units at the same Y (true of every non-flying unit today).
static func horizontal_distance_to(a: Vector3, b: Vector3) -> float:
	return Vector2(a.x, a.z).distance_to(Vector2(b.x, b.z))


## Distance from this unit's own collision edge to target's center --
## attack_range means "reach beyond my body," not "gap between two
## centers." Subtracting only the attacker's own radius (not the
## target's too) keeps attack_range a per-unit constant independent of
## who it's fighting, rather than something that has to be reasoned
## about per matchup. Without this, two units whose combined radii are
## close to attack_range (e.g. two Giants, radius 1.1 each, range 2.2)
## have essentially zero room to both stand in range of the same target
## without their own capsules overlapping -- avoidance can't resolve
## that cleanly and the pair visibly circles/jostles instead of settling.
func _distance_to_target_edge(target: Unit) -> float:
	return horizontal_distance_to(global_position, target.global_position) - stats.collision_radius


## Launches this unit along a fixed-duration parabolic arc, horizontally
## in `direction` by `distance` meters, peaking at `height` meters up.
## _physics_process() returns early while airborne, so avoidance/
## move_and_slide() never run for this unit until it lands -- it moves
## by direct position assignment instead, which is what makes "flies
## over other units" literal rather than approximate. Collision is
## disabled for the same reason: a unit landing exactly on a ground
## unit's position at low arc height (near launch/landing) could
## otherwise still get blocked right as this starts or ends.
## No-ops if already airborne: without this, a second knockback landing
## mid-arc resets _knockback_start/_knockback_elapsed to the unit's
## current (mid-air) position, and since _physics_process() early-returns
## for airborne units, the victim never gets a physics frame back to
## fight or path -- two attackers can juggle it indefinitely. Simplest
## fix per the PR #4 review: airborne units are immune to further
## knockback until they land. Diminishing-returns-style partial immunity
## can wait for a real CC-immunity framework, if one turns out to be needed.
func apply_knockback(direction: Vector3, distance: float, height: float) -> void:
	if _is_airborne:
		return
	_is_airborne = true
	_knockback_elapsed = 0.0
	_knockback_start = global_position
	_knockback_direction = direction
	_knockback_distance = distance
	_knockback_peak_height = height
	_collision_shape.disabled = true


func _process_knockback(delta: float) -> void:
	_knockback_elapsed += delta
	var t := clampf(_knockback_elapsed / _KNOCKBACK_DURATION, 0.0, 1.0)

	global_position = _knockback_start + _knockback_direction * _knockback_distance * t
	global_position.y = _resting_height() + _knockback_peak_height * 4.0 * t * (1.0 - t)
	_clamp_to_arena()

	if t >= 1.0:
		_is_airborne = false
		_collision_shape.disabled = false


## Keeps the current target_enemy only if it's still alive AND still
## within acquisition_range of this unit's *current* position -- checked
## fresh every call, not just at the moment a target was first picked, so
## a target that drifts out of range gets given up on rather than chased
## forever. Otherwise re-acquires via GameManager.find_nearest_enemy(),
## which applies the same acquisition_range cap to the search itself.
func _update_target() -> void:
	var target_is_valid := target_enemy != null and is_instance_valid(target_enemy) and target_enemy.current_health > 0.0
	if target_is_valid and horizontal_distance_to(global_position, target_enemy.global_position) <= stats.acquisition_range:
		return
	target_enemy = GameManager.find_nearest_enemy(self)


func _seek_target() -> void:
	_seek_position(target_enemy.global_position)


## Records `position` as this frame's movement destination -- the actual
## desired_velocity (toward the *next* NavigationMesh waypoint on the way
## there, not necessarily a straight line to `position`) is resolved once,
## centrally, at the end of _physics_process(), for whichever seek call
## happened (if any) this frame. Centralizing it there instead of setting
## desired_velocity directly here is what makes real pathfinding possible:
## NavigationAgent3D needs target_position set to the actual final
## destination to path against Main.tscn's baked NavigationRegion3D, not
## synthesized fresh each frame from whatever direction avoidance alone
## happened to want (the old approach, before real navmesh pathfinding
## existed -- see the roadmap's Phase 7).
func _seek_position(position: Vector3) -> void:
	_seek_destination = position
	_is_seeking = true


## Dispatches to the behavior for current_order.type. Every branch that
## can fight reuses _update_target()/_attack() exactly as the default
## autonomous AI does -- orders change *where* a unit goes when it's not
## fighting, not how combat itself resolves once something's in range.
func _process_order(delta: float) -> void:
	match current_order.type:
		OrderType.STOP:
			pass # fully idle: no movement, no auto-acquire
		OrderType.HOLD:
			_update_target()
			if target_enemy != null and _distance_to_target_edge(target_enemy) <= stat_block.attack_range():
				_attack(delta)
			# else: stays put -- Hold Position never chases
		OrderType.MOVE:
			_move_toward_and_clear_when_arrived(current_order.target_position)
		OrderType.ATTACK_MOVE:
			var forced_target: Unit = current_order.target_unit
			if forced_target != null and is_instance_valid(forced_target) and forced_target.current_health > 0.0:
				# A direct attack-unit order (right-click on a specific
				# enemy) always chases that one enemy, at any distance --
				# unlike the plain-destination case below, this order
				# doesn't have a "point" to fall back to.
				target_enemy = forced_target
				if _distance_to_target_edge(target_enemy) <= stat_block.attack_range():
					_attack(delta)
				else:
					_seek_target()
				return

			# Plain attack-move to a point: only fight something already
			# within attack range right now, never _seek_target() toward
			# whatever _update_target() (via GameManager.find_nearest_enemy(),
			# now capped by UnitStats.acquisition_range) picks. Chasing
			# that unconditionally (the bug this replaced, back when
			# find_nearest_enemy() had no cutoff at all) meant attack-move
			# degenerated into the default autonomous "seek nearest enemy"
			# the instant any enemy existed anywhere on the field, and the
			# actual clicked destination was never reachable. Falling back
			# to the destination instead of _seek_target() is what makes
			# "move there, fighting anything actually in the way" the real
			# behavior.
			_update_target()
			if target_enemy != null and _distance_to_target_edge(target_enemy) <= stat_block.attack_range():
				_attack(delta)
			else:
				_move_toward_and_clear_when_arrived(current_order.target_position)
		OrderType.PATROL:
			_update_target()
			if target_enemy != null and _distance_to_target_edge(target_enemy) <= stat_block.attack_range():
				_attack(delta)
			else:
				_patrol_step()
		OrderType.FOLLOW:
			if current_order.target_unit == null or not is_instance_valid(current_order.target_unit) or current_order.target_unit.current_health <= 0.0:
				clear_order()
				return
			_update_target()
			if target_enemy != null and _distance_to_target_edge(target_enemy) <= stat_block.attack_range():
				_attack(delta)
			else:
				_seek_position(current_order.target_unit.global_position)


## Shared by MOVE/ATTACK_MOVE's "nothing to fight, keep heading to the
## destination" branch: advances to the next queued order (or falls back
## to the default autonomous AI) once within _ARRIVAL_EPSILON.
func _move_toward_and_clear_when_arrived(target_position: Vector3) -> void:
	if horizontal_distance_to(global_position, target_position) <= _ARRIVAL_EPSILON:
		_advance_order_queue()
	else:
		_seek_position(target_position)


## Bounces between current_order.target_position and .patrol_origin,
## flipping _patrol_forward at each end -- a PATROL order never
## completes/clears on its own, only clear_order()/a new order ends it.
func _patrol_step() -> void:
	var waypoint := current_order.target_position if _patrol_forward else current_order.patrol_origin
	if horizontal_distance_to(global_position, waypoint) <= _ARRIVAL_EPSILON:
		_patrol_forward = not _patrol_forward
	else:
		_seek_position(waypoint)


## UnitStats.attack_windup (default 0.0) delays the hit landing after a
## swing commits -- 0.0 (every archetype until this system was populated)
## lands the hit the same frame the cooldown allows, exactly the old
## behavior. attack_interval's own cooldown only starts counting once the
## hit actually lands (whether instantly or after a windup), not at the
## moment the swing commits -- keeps "time between hits" the single thing
## attack_interval means, regardless of whether windup is 0 or not, rather
## than needing every windup archetype's attack_interval re-tuned to
## compensate for a windup that eats into it.
func _attack(delta: float) -> void:
	if _windup_remaining > 0.0:
		_windup_remaining -= delta
		if _windup_remaining <= 0.0:
			_release_attack_at(_windup_target)
			_windup_target = null
			_attack_cooldown = stat_block.attack_interval()
		return

	_attack_cooldown -= delta
	if _attack_cooldown > 0.0:
		return

	if stats.attack_windup > 0.0:
		_windup_remaining = stats.attack_windup
		_windup_target = target_enemy
	else:
		_release_attack_at(target_enemy)
		_attack_cooldown = stat_block.attack_interval()


## Fires the hit itself (projectile or instant) at `target` -- shared by
## _attack()'s instant path (windup == 0.0) and the windup-elapsed path
## above. No-ops silently if `target` died or was freed while a windup
## was in progress -- a fizzled swing, not a crash.
func _release_attack_at(target: Unit) -> void:
	if target == null or not is_instance_valid(target) or target.current_health <= 0.0:
		return
	if stats.projectile_speed > 0.0:
		_fire_projectile_at(target)
	else:
		resolve_hit(target, global_position)


## Instantiates a Projectile (Scripts/Projectile.gd) aimed at `target`,
## carrying this Unit's stats forward so the hit -- resolve_hit() below --
## only lands once it actually arrives, instead of the instant the attack
## cooldown allows.
func _fire_projectile_at(target: Unit) -> void:
	var projectile: Projectile = _PROJECTILE_SCENE.instantiate()
	GameManager.units_container.add_child(projectile)
	# Roughly chest height, not the ground -- purely cosmetic (Projectile
	# does its own horizontal-only distance checks either way).
	projectile.global_position = global_position + Vector3(0, stats.mesh_size.y * 0.5, 0)
	var guidance := Projectile.GuidanceType.HOMING if stats.projectile_homing else Projectile.GuidanceType.BALLISTIC
	projectile.setup(self, target, stats.projectile_speed, guidance)


## Applies this attack's damage (and any on-hit ability -- e.g. Giant's
## knockback, see UnitStats.on_hit_ability) to `target`, as if it landed
## right now -- shared by the instant-melee path in _attack() and
## Projectile._impact(), so a hit resolves identically regardless of
## whether it was instant or delayed by travel time. `source_position` is
## only used for on-hit knockback direction (target is knocked away from
## wherever the hit effectively came from) -- for a projectile that's its
## impact position, not necessarily where this Unit is standing by the
## time a slow shot lands.
func resolve_hit(target: Unit, source_position: Vector3) -> void:
	if not is_instance_valid(target) or target.current_health <= 0.0:
		return
	target.take_damage(DamageInstance.new(stat_block.damage(), self))

	if stats.on_hit_ability != null:
		stats.on_hit_ability.trigger_on_hit(self, target, source_position)


## PURE damage skips armor entirely (see DamageInstance); ATTACK/SPELL are
## reduced flat by armor(), floored at 1 so armor can't fully negate a hit
## outright -- a WC3-style minimum. ATTACK damage additionally passes
## through AttackArmorTable's attack-type x armor-type multiplier
## (source's UnitStats.attack_type against this unit's own armor_type) --
## SPELL does not, matching WC3's own convention that the type table only
## applies to normal attacks. Mitigation happens here, not at the source,
## so it always applies regardless of who/what dealt the DamageInstance.
## No-ops on a corpse -- without this, e.g. a lingering AoE tick could
## re-run die() during the decay window and double-fire the died signal.
## INVULNERABLE blocks every damage type outright, no exceptions;
## ETHEREAL (WC3's "spells only" state) blocks ATTACK specifically but
## still takes SPELL/PURE.
func take_damage(instance: DamageInstance) -> void:
	if life_state == LifeState.DEAD:
		return
	if is_invulnerable():
		return
	if is_ethereal() and instance.damage_type == DamageInstance.DamageType.ATTACK:
		return

	var mitigated := instance.amount
	if instance.damage_type != DamageInstance.DamageType.PURE:
		mitigated = maxf(instance.amount - stat_block.armor(), 1.0)
		if instance.damage_type == DamageInstance.DamageType.ATTACK and instance.source != null:
			mitigated *= AttackArmorTable.multiplier(instance.source.stats.attack_type, stats.armor_type)

	current_health -= mitigated
	_health_bar.set_fraction(current_health / stat_block.max_health())
	damaged.emit(self, instance, mitigated)

	if current_health <= 0.0:
		die(instance.source)


## Enters the DEAD state -- collision off (no longer blocks or gets
## targeted), health bar hidden, died signal fired immediately (so
## GameManager's roster/win-condition check happens at the moment of
## death, not after decay) -- but does NOT free the node. The corpse
## keeps existing, decaying in _physics_process, until
## _CORPSE_DECAY_DURATION elapses. See LifeState. Also drops every active
## Effect -- a corpse shouldn't keep ticking down a slow/stun, and
## stat_block becomes irrelevant once dead anyway.
func die(killer: Unit = null) -> void:
	current_health = 0.0
	life_state = LifeState.DEAD
	_decay_elapsed = 0.0
	_body_color_at_death = _body_material.albedo_color
	_collision_shape.disabled = true
	_health_bar.visible = false
	_status_indicator.hide_status()
	clear_all_effects()
	died.emit(self, killer)


## Read-only snapshot for Scripts/DebugInspector.gd / UI/DebugPanel.gd,
## shown regardless of debug-menu toggles. Everything here is derived by
## re-reading existing public state -- this method never sets anything,
## so it can't affect AI, combat, or targeting. Values are pre-formatted
## display strings by design, so the debug panel stays a generic "print
## whatever keys this returns" renderer and never needs unit-specific
## formatting logic of its own.
func get_debug_info() -> Dictionary:
	return {
		"Name": stats.unit_name,
		"Team": player.display_name,
		"Health": "%.0f / %.0f" % [current_health, stat_block.max_health()],
		"AI State": _describe_state(),
		"Target": target_enemy.stats.unit_name if target_enemy != null else "(none)",
	}


## Same contract and rules as get_debug_info(), but only shown when
## DebugSettings.FLAG_DETAILED_STATS is on -- DebugPanel checks
## has_method() before calling this, so it's optional for any future
## inspectable object.
func get_debug_info_detailed() -> Dictionary:
	return {
		"Distance to Target": _describe_distance_to_target(),
		"Attack Range": "%.1f m" % stat_block.attack_range(),
		"Attack Cooldown": "%.1fs" % maxf(_attack_cooldown, 0.0),
		"Armor": "%.1f" % stat_block.armor(),
		"Position": "(%.1f, %.1f, %.1f)" % [global_position.x, global_position.y, global_position.z],
		"Avoidance": _describe_avoidance(),
		"Flying": "Yes" if stats.is_flying else "No",
		"Airborne": "Yes (knocked back)" if _is_airborne else "No",
		"Effects": _describe_effects(),
	}


func _describe_effects() -> String:
	if _active_effects.is_empty():
		return "-"
	var parts: Array[String] = []
	for effect in _active_effects:
		var remaining := "permanent" if effect.duration <= 0.0 else "%.1fs" % maxf(effect.duration - effect.elapsed, 0.0)
		parts.append("%s (%s)" % [effect.id, remaining])
	return ", ".join(parts)


## Mirrors the branches in _physics_process (without altering any of
## them) to describe, in words, which one is currently active.
func _describe_state() -> String:
	if life_state == LifeState.DEAD:
		return "Dead (decaying, %.1fs left)" % maxf(_CORPSE_DECAY_DURATION - _decay_elapsed, 0.0)
	if _is_airborne:
		return "Airborne (knocked back)"
	match GameManager.battle_state:
		GameManager.BattleState.PLACEMENT:
			return "Waiting (Placement)"
		GameManager.BattleState.GAME_OVER:
			return "Waiting (Game Over)"
	if current_order != null:
		return _describe_order_state()
	if target_enemy == null:
		return "Searching for Target"
	return "Moving" if _distance_to_target_edge(target_enemy) > stat_block.attack_range() else "Attacking"


func _describe_order_state() -> String:
	var is_attacking := target_enemy != null and _distance_to_target_edge(target_enemy) <= stat_block.attack_range()
	match current_order.type:
		OrderType.STOP:
			return "Stopped"
		OrderType.HOLD:
			return "Attacking (Hold)" if is_attacking else "Holding Position"
		OrderType.MOVE:
			return "Moving to Order"
		OrderType.ATTACK_MOVE:
			return "Attacking (Order)" if is_attacking else "Attack-Moving"
		OrderType.PATROL:
			return "Attacking (Patrol)" if is_attacking else "Patrolling"
		OrderType.FOLLOW:
			return "Attacking (Follow)" if is_attacking else "Following"
	return "Following Order"


func _describe_distance_to_target() -> String:
	if target_enemy == null:
		return "-"
	return "%.1f m" % _distance_to_target_edge(target_enemy)


## How far avoidance is steering velocity away from the raw seek
## direction -- large values mean it's actively routing around a blocker.
func _describe_avoidance() -> String:
	if desired_velocity.length() < 0.05:
		return "-"
	var deviation_degrees := rad_to_deg(desired_velocity.angle_to(velocity))
	return "%.0f°" % deviation_degrees
