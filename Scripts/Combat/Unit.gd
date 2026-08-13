## A single combat unit: a primitive-mesh body that fights automatically
## once GameManager enters the BATTLE state.
##
## Seeks target_enemy via NavigationAgent3D pathfinding (navmesh queries
## only -- see _build_avoidance()'s own doc comment for why avoidance
## itself is NOT NavigationAgent3D's built-in RVO) rather than a raw
## straight line, so units route around blocking allies instead of
## queuing up behind them. Movement is fully manual (global_position +=
## velocity * delta in _physics_process(), not
## CharacterBody3D.move_and_slide()) -- overlap resolution is
## _compute_avoidance_velocity()'s own separation steering, not
## PhysicsServer3D. Still a CharacterBody3D purely so
## DebugInspector.try_select_at()/SelectionManager's drag-box selection
## have a real CollisionShape3D to raycast/query against -- the physics
## server is never asked to move this body.
class_name Unit
extends CharacterBody3D

## killer is the DamageInstance.source of the killing blow; may be null
## (environmental/scripted damage, or the unit was freed some other way).
signal died(unit: Unit, killer: Unit)
## Emitted after mitigation is applied, on every hit that connects --
## GameManager listens for this to reset its stalemate timer, and it's
## the natural hook point for future damage-meter/on-hit UI.
signal damaged(unit: Unit, instance: DamageInstance, damage_dealt: float)
## Emitted on every successful cast_ability() (not on a rejected/no-op
## attempt) -- GameManager listens for this to detect a hero's ultimate
## specifically (see GameManager._on_unit_ability_cast()) and trigger
## camera shake.
signal ability_cast_used(unit: Unit, index: int)

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
## Extra buffer beyond two units' exact physical touch distance
## (collision_radius + collision_radius) that _compute_avoidance_velocity()
## treats as "close enough to start steering apart" -- see that method's
## own doc comment for why this has to be strictly greater than 0.
const _AVOIDANCE_MARGIN := 0.3
const _ARRIVAL_EPSILON := 0.3 ## Horizontal distance (m) within which a MOVE/ATTACK_MOVE/PATROL destination counts as "reached."
const _KNOCKBACK_DURATION := 0.6 ## Seconds from launch to landing.
## Roadmap Phase 0's "no re-acquisition interval" gap: without this,
## _update_target() calls GameManager.find_nearest_enemy() (an O(n) scan
## over every hostile unit) on literally every physics frame a unit has
## no valid target -- e.g. every unit on a team once the enemy team is
## wiped, or every unit during PLACEMENT -- which is what actually makes
## the whole system O(n^2) per frame, not the occasional single-target
## re-acquisition a unit does once it's already fighting something (that
## path is already cheap: _update_target() only re-scans once its
## current target goes invalid or drifts out of range). 0.2s (5
## scans/sec instead of 60) is a large constant-factor win with no
## gameplay-visible latency -- an idle unit still notices a new enemy
## well within a fraction of a second, not "instead of instantly."
const _TARGET_REACQUISITION_INTERVAL := 0.2
## How long this unit can chase the same target without ever getting
## within attack range before _update_target() gives up on it and picks
## a different enemy instead. GameManager.find_nearest_enemy() is purely
## geometric-distance-based with no crowding awareness, so several
## allies converging on the same nearest enemy could otherwise circle it
## forever, deflected by avoidance every time they re-path toward an
## already-occupied attack_range slot. Not applied to a forced
## ATTACK_MOVE target (right-click a specific enemy) -- see
## _process_order()'s own ATTACK_MOVE branch, which never calls
## _update_target() at all, so a deliberate player order is never
## silently overridden.
const _STUCK_CHASE_THRESHOLD := 2.5
## How long a unit is immune to a *new* application of the same hard-CC
## flag after one wears off -- simplified stand-in for real diminishing
## returns (WC3 halves each successive CC duration within a window; this
## just blocks the next one outright for a bit instead, same simplified
## approach the original stun-only version used, now generalized to
## every flag in _DR_ELIGIBLE_CC_FLAGS below). Same juggling problem PR #4's
## knockback review flagged, but for Effect-based CC rather than
## positional knockback (which already has its own, separate immunity --
## see apply_knockback()'s doc comment; the two don't share a mechanism
## because one is positional and this one is Effect/CC-based).
const _CC_IMMUNITY_DURATION := 1.0
## Which CC flags this diminishing-returns window applies to -- the
## "hard CC, loses you control of your unit" flags a real player would
## feel juggled by. INVULNERABLE/ETHEREAL are deliberately excluded:
## both are self-buffs an ability grants its own caster (see Ability.gd),
## never something an enemy repeatedly lands on you, so there's nothing
## to juggle and no reason to ever block a unit from re-buffing itself.
const _DR_ELIGIBLE_CC_FLAGS: Array[Effect.CCFlag] = [Effect.CCFlag.STUN, Effect.CCFlag.ROOT, Effect.CCFlag.SILENCE]
## How long a corpse lingers -- collision disabled, no longer targetable,
## but still visible -- before being freed. No respawn hook yet (no
## heroes exist); this is purely the "corpse" half of "corpse/decay or
## respawn," so a future hero revive can intercept before the free
## without take_damage()/die() needing another signature change.
const _CORPSE_DECAY_DURATION := 3.0
## Corpse sinks into the ground and fades to transparent over the final
## portion of _CORPSE_DECAY_DURATION, instead of just darkening to black
## and popping out of existence.
const _DISSOLVE_START_FRACTION := 0.6
const _DISSOLVE_SINK_DEPTH := 0.6
## Roadmap Phase 9's "hit flash" -- how long a landed hit tints
## _body_material toward _HIT_FLASH_COLOR before easing back to
## player.color. Purely cosmetic, ticked in _physics_process() (not
## _process()) for the same reason every other delta-driven timer in this
## project is -- see _tick_hit_flash()'s own doc comment.
const _HIT_FLASH_DURATION := 0.15
const _HIT_FLASH_COLOR := Color(1.0, 1.0, 1.0)

const _TEAM_COLOR_SHADER: Shader = preload("res://Resources/Shaders/TeamColor.gdshader")

@export var stats: UnitStats

var player: Player
## Stable identity assigned once by GameManager.spawn_unit(), never
## reused -- lets a Command (Scripts/Core/Command.gd) reference "this
## specific unit" across a tick-delay/network boundary, where a raw Unit
## object reference can't be serialized. -1 for anything spawn_unit()
## didn't create (e.g. the Builder courtyard fixture via
## spawn_courtyard_fixture() -- deliberately excluded, same as it's
## excluded from _all_units/_units_by_team, since nothing ever issues a
## Command targeting it).
var net_id: int = -1
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
## The mesh's own material -- a ShaderMaterial (Resources/Shaders/TeamColor.gdshader,
## this project's first real shader -- see its own doc comment) rather
## than a plain StandardMaterial3D, so a future imported model can plug
## into the same team-color infrastructure via that shader's
## albedo_texture/team_mask uniforms with no Unit.gd changes needed.
## Stored so die()/_physics_process()'s corpse tick can darken and
## dissolve it over _CORPSE_DECAY_DURATION, instead of a corpse just
## sitting there at full team color until it vanishes.
var _body_material: ShaderMaterial
var _body_color_at_death: Color
var _position_y_at_death: float
var _nav_agent: NavigationAgent3D
var _order_queue: Array[Order] = []
var _patrol_forward: bool = true

## Timed/permanent Effects currently on this unit -- see Effect.gd and
## apply_effect(). Anything with a stat modifier also has a matching
## StatBlock.Modifier alive on stat_block for as long as it's in here.
var _active_effects: Array[Effect] = []
## CCFlag -> seconds remaining before that flag can land on this unit
## again -- see _DR_ELIGIBLE_CC_FLAGS/apply_effect()/_tick_effects(). A
## missing/absent key (the common case) means no immunity active for
## that flag at all.
var _cc_immunity_remaining: Dictionary = {}
## Seconds until _update_target() is allowed to call
## GameManager.find_nearest_enemy() again while targetless -- see
## _TARGET_REACQUISITION_INTERVAL. Irrelevant (never consulted) whenever
## target_enemy is already valid and in range, since _update_target()
## returns before ever reaching this check in that case.
var _reacquisition_cooldown: float = 0.0
## Seconds this unit has been chasing _last_chased_target without yet
## getting within attack range of it -- reset to 0 the instant
## target_enemy changes OR it comes into range (see _physics_process()'s
## own tracking). Compared against _STUCK_CHASE_THRESHOLD in
## _update_target() to give up on a target that's evidently unreachable
## (crowded out by allies already occupying every attack_range slot
## around it) rather than orbiting it forever.
var _chase_elapsed: float = 0.0
var _last_chased_target: Unit = null

## Ability slot index (0/1/2, matching stats.abilities) -> remaining
## cooldown seconds. Absent/0 means ready.
var _ability_cooldowns: Dictionary = {}

## Re-ticking stats.aura_ability every physics frame would allocate a
## fresh Effect 60x/sec per aura-bearing unit for no benefit -- REFRESH
## stacking (Effect's own default) only needs to land often enough that
## the buff never actually expires on someone standing in range.
const _AURA_TICK_INTERVAL := 0.25
var _aura_tick_elapsed: float = 0.0
## A second, independent aura source alongside stats.aura_ability --
## per-INSTANCE, not on the shared UnitStats resource, deliberately.
## ArchetypeUpgrade (Scripts/Combat/ArchetypeUpgrade.gd) grants an aura
## to already-existing and future units of one purchased SQUAD at
## purchase time; setting it on `stats` directly would mutate the shared,
## preloaded UnitStats Resource every unit of that archetype (including
## every other player's) references, leaking the aura game-wide the
## instant one player bought it -- the same "shared preloaded Resource"
## mutation trap this codebase's own tests already document elsewhere.
## See GameManager._spawn_roster_squad_at()/buy_archetype_upgrade().
var granted_aura_ability: Ability = null

var _decay_elapsed: float = 0.0
## Seconds remaining on the current hit flash -- 0.0 (the common case,
## most physics frames) means _body_material is just player.color, and
## _tick_hit_flash() does nothing.
var _hit_flash_remaining: float = 0.0
## The in-flight squash-and-recover tween from the most recent landed
## hit (see _play_hit_squash()) -- killed and restarted on every new hit
## rather than left to run alongside a fresh one, which would otherwise
## fight the new tween for _mesh_instance.scale on a unit taking rapid
## hits.
var _hit_squash_tween: Tween = null

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

## Per-instance override of stats.abilities -- every ability-reading call
## site (cast_ability(), HUD's hotbar, PlayerInputController's
## first_selected_ability()) reads THIS instead of stats.abilities
## directly, so a drafted pick (see Player.hero_ability_picks) reflects
## on this one Unit instance without ever mutating the shared archetype
## Resource every other copy of the same hero also references. Populated
## once in setup() -- see _resolve_abilities(). Identical to
## stats.abilities for every non-hero/non-drafting archetype.
var resolved_abilities: Array[Ability] = []


## Called by GameManager right after the unit is added to the scene tree.
func setup(new_stats: UnitStats, new_player: Player) -> void:
	stats = new_stats
	player = new_player
	stat_block = StatBlock.from_archetype(stats)
	current_health = stat_block.max_health()
	_resolve_abilities()
	_build_appearance()
	# The Builder never moves or seeks anything (see _physics_process()'s
	# own is_builder early-return) -- skip building a NavigationAgent3D
	# for it entirely rather than one that's simply never queried.
	if not stats.is_builder:
		_build_avoidance()
	_apply_passive_abilities()


## Used by GameManager to hide every squad member past the first one
## while a purchased squad stands in its courtyard, so it reads as one
## roster slot rather than a stack of overlapping models. All members
## stay real, fully set-up Unit instances -- only rendering and
## click/raycast targeting are suppressed; begin_march() reveals the
## full squad again once marching starts.
func set_courtyard_visible(is_visible: bool) -> void:
	visible = is_visible
	_collision_shape.disabled = not is_visible


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
## existing effect with the same id. An effect whose cc_flag is in
## _DR_ELIGIBLE_CC_FLAGS is silently dropped outright while that flag's
## own diminishing-returns immunity is active -- see _CC_IMMUNITY_DURATION.
func apply_effect(effect: Effect) -> void:
	if effect.cc_flag in _DR_ELIGIBLE_CC_FLAGS and _cc_immunity_remaining.get(effect.cc_flag, 0.0) > 0.0:
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


## Short, player-facing summary for UI/HUD.gd's unit info panel's own
## "Status" line -- WC3-style CC-name list ("Stunned, Silenced"), not
## _describe_effects()'s raw effect-id/duration dump (that one's for
## DebugPanel's detailed-stats mode, a different audience). "-" when
## nothing's active, same convention _describe_effects() already uses.
func status_summary() -> String:
	var parts: Array[String] = []
	if is_stunned():
		parts.append("Stunned")
	if is_rooted():
		parts.append("Rooted")
	if is_silenced():
		parts.append("Silenced")
	if is_invulnerable():
		parts.append("Invulnerable")
	if is_ethereal():
		parts.append("Ethereal")
	return ", ".join(parts) if not parts.is_empty() else "-"


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
	for flag in _cc_immunity_remaining.keys():
		_cc_immunity_remaining[flag] = maxf(_cc_immunity_remaining[flag] - delta, 0.0)

	for effect in _active_effects.duplicate():
		if effect.duration <= 0.0:
			continue # permanent -- only removed by remove_effects_from_source() or clear_all_effects()
		effect.elapsed += delta
		if effect.elapsed >= effect.duration:
			var expiring_cc_flag: Effect.CCFlag = effect.cc_flag
			_remove_effect(effect)
			if expiring_cc_flag in _DR_ELIGIBLE_CC_FLAGS:
				_cc_immunity_remaining[expiring_cc_flag] = _CC_IMMUNITY_DURATION

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
	if stats.aura_ability == null and granted_aura_ability == null:
		return
	_aura_tick_elapsed += delta
	if _aura_tick_elapsed < _AURA_TICK_INTERVAL:
		return
	_aura_tick_elapsed = 0.0
	if stats.aura_ability != null:
		stats.aura_ability.apply_aura(self)
	if granted_aura_ability != null:
		granted_aura_ability.apply_aura(self)


func _apply_passive_abilities() -> void:
	for ability in resolved_abilities:
		if ability != null and ability.cast_type == Ability.CastType.PASSIVE:
			ability.cast_passive(self)


## Populates resolved_abilities: starts as a duplicate of stats.abilities,
## then any drafted slot (UnitStats.ability_draft_choices) with a
## recorded player pick (Player.hero_ability_picks) overwrites that
## index with the chosen candidate. A no-op beyond the plain duplicate
## for every non-hero/non-drafting archetype, since ability_draft_choices
## is empty for all of them.
func _resolve_abilities() -> void:
	resolved_abilities = stats.abilities.duplicate()
	if not stats.is_hero:
		return
	var picks: Dictionary = player.hero_ability_picks.get(stats, {})
	for i in stats.ability_draft_choices.size():
		var choice_set: AbilityChoiceSet = stats.ability_draft_choices[i]
		if choice_set == null or choice_set.candidates.is_empty():
			continue
		var chosen_index: int = picks.get(i, 0)
		resolved_abilities[i] = choice_set.candidates[chosen_index]


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
## hero through more than one level at once. Persists the result to
## player.hero_progress every call (not just on an actual level-up) so
## partial XP toward the next level survives a Blood Tournament round
## boundary too, not just whole levels -- see restore_hero_progress()
## and Player.hero_progress's own doc comment.
func gain_xp(amount: float) -> void:
	if not stats.is_hero:
		return
	xp += amount
	while xp >= get_xp_to_next_level():
		xp -= get_xp_to_next_level()
		level += 1
		_on_level_up()
	player.hero_progress[stats] = {"level": level, "xp": xp}


## Called once, right after a fresh hero Unit spawns (see
## BloodTournamentController.deploy_next_pending_slot()), to fast-forward
## it to a level/xp a previous round's copy of this same hero archetype
## already earned -- see Player.hero_progress's own doc comment for why
## this exists at all. Re-runs _on_level_up()'s stat growth once per
## level rather than jumping stat_block straight to its final values, so
## this always matches whatever gain_xp()'s own level-up loop would have
## produced, with no separate "compute stats for level N" formula to
## keep in sync. No-op for a non-hero unit, or if saved_level isn't
## actually higher than the level this Unit already spawned at (1).
func restore_hero_progress(saved_level: int, saved_xp: float) -> void:
	if not stats.is_hero:
		return
	while level < saved_level:
		level += 1
		_on_level_up()
	xp = saved_xp


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


## Triggers resolved_abilities[index] (Q/E/R in Main.gd's input wiring) --
## a hero's own drafted pick if it has one for this slot (see
## Player.hero_ability_picks/_resolve_abilities()), otherwise identical
## to stats.abilities[index]. Returns false (and does nothing) if the
## slot is empty, on cooldown, not yet unlocked (stats.is_hero only --
## see stats.ability_unlock_levels), not a player-triggerable cast type,
## this unit can't currently act (stunned/silenced), or -- for
## UNIT_TARGET -- target is missing/out of range, so callers can tell a
## no-op from a successful cast.
func cast_ability(index: int, target: Unit = null) -> bool:
	if index < 0 or index >= resolved_abilities.size():
		return false
	var ability: Ability = resolved_abilities[index]
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
	Sfx.play_ability_cast(global_position)
	ImpactBurst.spawn(GameManager.units_container, global_position + Vector3(0, stats.mesh_size.y * 0.8, 0), Color(0.55, 0.8, 1.0), 10, 30.0, 2.5, 0.3)
	ability_cast_used.emit(self, index)
	return true


## Auto-battle only (see GameMode.is_auto_battle()) -- Blood Tournament
## units have no player pressing Q/E/R, so ability use has to happen on
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


## Eases _body_material's team_color shader param back toward player.color
## over _HIT_FLASH_DURATION -- take_damage() is what actually starts a
## flash (sets _hit_flash_remaining), this just ticks it down every
## physics frame. Never runs while DEAD (see _physics_process()'s early
## return above) -- die()'s own corpse-decay tick owns that shader param
## exclusively from that point on, so the two never fight over it.
func _tick_hit_flash(delta: float) -> void:
	if _hit_flash_remaining <= 0.0:
		return
	_hit_flash_remaining = maxf(_hit_flash_remaining - delta, 0.0)
	_body_material.set_shader_parameter("team_color", player.color.lerp(_HIT_FLASH_COLOR, _hit_flash_remaining / _HIT_FLASH_DURATION))


## A quick squash-then-recover on _mesh_instance's own scale -- cheap
## "juice" for a landed hit beyond the existing flash tint/damage popup,
## using nothing but a Tween (no new mesh/material/asset). Kills any
## still-running tween from a previous hit first rather than letting two
## fight over the same scale property on a unit taking rapid hits.
func _play_hit_squash() -> void:
	if _hit_squash_tween != null and _hit_squash_tween.is_valid():
		_hit_squash_tween.kill()
	_mesh_instance.scale = Vector3(1.15, 0.85, 1.15)
	_hit_squash_tween = create_tween()
	_hit_squash_tween.tween_property(_mesh_instance, "scale", Vector3.ONE, 0.15) \
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)


## Roadmap Phase 9's "floating combat text" -- one Scripts/Indicators/DamagePopup.gd
## instance per landed hit, parented into GameManager.units_container
## (same parent Projectile.gd uses) rather than as this Unit's own child,
## since it needs to keep rising/fading and free itself on its own
## schedule, independent of whatever happens to this Unit afterward
## (including this Unit dying in the same hit that spawned it).
func _spawn_damage_popup(amount: float, damage_type: DamageInstance.DamageType) -> void:
	var popup := DamagePopup.new()
	GameManager.units_container.add_child(popup)
	popup.global_position = global_position + Vector3(0, stats.mesh_size.y + 0.9, 0)
	popup.setup(amount, damage_type)


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

	_body_material = ShaderMaterial.new()
	_body_material.shader = _TEAM_COLOR_SHADER
	_body_material.set_shader_parameter("team_color", player.color)
	mesh.surface_set_material(0, _body_material)

	_mesh_instance.mesh = mesh
	# Half the mesh height keeps the unit resting on the ground instead of
	# being centered through the floor.
	_mesh_instance.position.y = stats.mesh_size.y * 0.5

	_build_faction_accent()
	_build_collision()
	_build_health_bar()
	_build_status_indicator()


## A thin flat ring on the ground beneath the unit, colored by
## stats.faction.accent_color -- Phase 11's "team-color/material per
## faction, not just per team" (Faction.gd's own doc comment). Skipped
## entirely when stats.faction is null (Builder/Throne/goblin fixtures),
## same as every other optional-Resource field in this codebase. Kept as
## a separate flat mesh rather than blending into _body_material because
## the body itself already carries the primary (and more important) team
## color -- this is a secondary accent, not a replacement. Sized off the
## body mesh's own footprint (_mesh_footprint_radius()), not
## collision_radius -- the two disagree for some archetypes (e.g. Archer:
## collision_radius 0.4 vs. its cone's 0.5 base radius), which would
## otherwise leave the ring fully hidden under the wider mesh.
func _build_faction_accent() -> void:
	if stats.faction == null:
		return
	var footprint := _mesh_footprint_radius()
	var ring := TorusMesh.new()
	ring.inner_radius = maxf(footprint - 0.05, 0.02)
	ring.outer_radius = footprint + 0.15
	var accent_material := StandardMaterial3D.new()
	accent_material.albedo_color = stats.faction.accent_color
	accent_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	ring.surface_set_material(0, accent_material)
	var accent_instance := MeshInstance3D.new()
	accent_instance.mesh = ring
	accent_instance.position.y = 0.05
	add_child(accent_instance)


## The body mesh's horizontal (XZ) footprint radius, per mesh_shape --
## mirrors the same per-shape sizing _build_appearance() already applies
## to the actual mesh, just reduced to "how far does it reach from the
## unit's own center." Box uses the larger of its X/Z half-extents since
## a box need not be square.
func _mesh_footprint_radius() -> float:
	match stats.mesh_shape:
		"Capsule", "Cone":
			return stats.mesh_size.x
		_:
			return maxf(stats.mesh_size.x, stats.mesh_size.z) * 0.5


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


## avoidance_enabled is deliberately false -- NavigationAgent3D's built-in
## RVO avoidance solver runs off-thread and delivers results one frame
## later via the velocity_computed signal (see the removed
## _on_safe_velocity_computed()'s own former doc comment), and proved
## NOT deterministic across separate process runs given identical
## seed/inputs (BattleFoundry-Roadmap.md's D1 multiplayer plan, Phase A's
## decision-gate trace-and-diff harness). _nav_agent is kept only for
## navmesh PATHFINDING (get_next_path_position() against Main.tscn's
## baked NavigationRegion3D, a static-mesh query with no evidence against
## its own determinism) -- the avoidance step itself is now
## _compute_avoidance_velocity(), synchronous, same-tick, no threading.
func _build_avoidance() -> void:
	_nav_agent = NavigationAgent3D.new()
	_nav_agent.radius = stats.collision_radius
	_nav_agent.avoidance_enabled = false
	# Godot's default (1.0m) is looser than this game's own tolerances --
	# attack_range is as low as 0.9m and _ARRIVAL_EPSILON is 0.3m. Left
	# at the default, NavigationAgent3D considers itself "close enough"
	# well before either of those, and get_next_path_position() starts
	# returning the agent's own current position (no further progress
	# needed, as far as it's concerned) -- which reads as the unit
	# getting permanently stuck just short of anything closer than 1m.
	_nav_agent.target_desired_distance = 0.1
	add_child(_nav_agent)


func _physics_process(delta: float) -> void:
	# Skip movement/avoidance/decay stepping entirely on a real physics
	# frame where the networked sim is stalled waiting for a peer's tick
	# confirmation (CommandQueue.is_stalled()) -- see that function's own
	# doc comment for why this matters: without it, a peer that spends
	# more real frames stalled than another accumulates extra ungated
	# unit movement before the tick counters realign, a real (not just
	# theoretical) source of desync. No-op for local-only play
	# (is_stalled() is always false there).
	if CommandQueue.is_stalled():
		return
	if life_state == LifeState.DEAD:
		_decay_elapsed += delta
		var decay_fraction := clampf(_decay_elapsed / _CORPSE_DECAY_DURATION, 0.0, 1.0)
		var dissolve_fraction := clampf((decay_fraction - _DISSOLVE_START_FRACTION) / (1.0 - _DISSOLVE_START_FRACTION), 0.0, 1.0)
		var darkened := _body_color_at_death.lerp(Color.BLACK, decay_fraction)
		_body_material.set_shader_parameter("team_color", Color(darkened.r, darkened.g, darkened.b, 1.0 - dissolve_fraction))
		global_position.y = _position_y_at_death - _DISSOLVE_SINK_DEPTH * dissolve_fraction
		if _decay_elapsed >= _CORPSE_DECAY_DURATION:
			queue_free()
		return

	# The Builder is a permanent, invulnerable, move_speed == 0 courtyard
	# fixture with no _nav_agent -- without this early return it would
	# still run _compute_avoidance_velocity() every frame, letting a
	# unit bumping it apply a nonzero separation nudge that push it off
	# its spawn point over time.
	if stats.is_builder:
		return

	_tick_effects(delta)
	_tick_ability_cooldowns(delta)
	_tick_aura(delta)
	_tick_hit_flash(delta)
	_reacquisition_cooldown = maxf(_reacquisition_cooldown - delta, 0.0)

	if _is_airborne:
		_process_knockback(delta)
		return

	desired_velocity = Vector3.ZERO
	_is_seeking = false

	# Stunned: fully disabled -- no movement, no attacking, no orders
	# processed at all (they just wait; an order issued while stunned
	# still applies once it wears off, current_order is untouched).
	if not is_stunned():
		var is_battling := GameManager.battle_state == GameManager.BattleState.BATTLE and current_health > 0.0
		if is_battling:
			_tick_chase_elapsed(delta)
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

	# Applied synchronously, same tick -- no async signal, no one-frame
	# delay (see _build_avoidance()'s own doc comment for why). Integrated
	# directly (global_position += velocity * delta) rather than through
	# CharacterBody3D.move_and_slide() -- PhysicsServer3D's own collision
	# response proved to have the same cross-process nondeterminism
	# problem RVO did (confirmed empirically: a 150-unit trace-and-diff
	# run diverged even with avoidance already fixed, resolved by forcing
	# single-threaded GodotPhysics3D, then made moot entirely by removing
	# the physics-server dependency from movement altogether -- see the
	# Roadmap's D1 plan). _collision_shape/CharacterBody3D are kept for
	# click/drag-box selection raycasts (DebugInspector.try_select_at(),
	# SelectionManager's drag box), which still need a real physics shape
	# to query against -- only movement itself no longer goes through the
	# physics server. _compute_avoidance_velocity() is what keeps units
	# from overlapping now that nothing else resolves penetration.
	velocity = _compute_avoidance_velocity(desired_velocity)
	if velocity.length() > 0.05:
		look_at(global_position + velocity, Vector3.UP)

	global_position += velocity * delta
	_clamp_to_arena()
	global_position.y = _resting_height()


## Deterministic replacement for NavigationAgent3D's built-in RVO
## avoidance (see _build_avoidance()'s own doc comment for why) -- a
## simple separation-steering model instead of reciprocal/predictive
## avoidance: every other living unit within _AVOIDANCE_NEIGHBOR_DISTANCE
## whose collision radius overlaps this unit's own deflects it, weighted
## by how deep the overlap is, blended additively onto `seek_velocity`
## (the pathfinding-derived direction computed above) and re-clamped to
## move_speed(). A neighbor roughly BEHIND the seek direction pushes
## straight away from it (plain separation -- also what resolves
## spawn-overlap for an idle, non-seeking unit, whose seek_velocity is
## zero); a neighbor roughly AHEAD of it deflects PERPENDICULAR instead
## (steer around, not straight back) -- a pure radial push directly
## opposing travel direction would just cancel forward progress every
## tick, leaving a unit ordered to walk toward/through a blocking
## neighbor permanently stuck oscillating in place rather than routing
## around it (caught by test_order_move_relocates_and_never_attacks:
## Tank ordered to (10,0,0) with a Fighter already overlapping it 1m
## ahead never made any net progress until this was added). Horizontal-only
## (XZ), matching every other distance/direction calculation in this
## class -- height is never simulated here. Iterates
## GameManager.get_nearby_units_cached() (a per-tick-cached uniform grid,
## 3x3 cells around this unit -- see its own doc comment) in its own
## returned order, never GDScript's Dictionary iteration anywhere -- fixed
## order is what keeps this reproducible given the same unit set, the
## actual property that made the old RVO path fail (see the Roadmap's D1
## plan for the trace-and-diff evidence). The grid exists purely for perf
## (a naive all-units-every-tick scan was a real measured regression on
## tools/benchmark.sh: ~15ms/frame at 200 units under the old RVO path ->
## 43ms uncached -> 29ms cached-but-unfiltered -> back near baseline with
## the grid) -- it returns a superset of "true neighbors" (everyone in the
## nearby cells, not an exact radius filter), so the precise distance
## check below is still what actually decides who gets pushed.
func _compute_avoidance_velocity(seek_velocity: Vector3) -> Vector3:
	var self_pos := Vector2(global_position.x, global_position.z)
	var seek_dir := Vector2(seek_velocity.x, seek_velocity.z)
	var is_moving := seek_dir.length() > 0.01
	if is_moving:
		seek_dir = seek_dir.normalized()
	var separation := Vector2.ZERO
	var all_units := GameManager.get_nearby_units_cached(global_position)
	for other in all_units:
		if other == self:
			continue
		var other_pos := Vector2(other.global_position.x, other.global_position.z)
		var offset := self_pos - other_pos
		var dist := offset.length()
		if dist >= _AVOIDANCE_NEIGHBOR_DISTANCE:
			continue
		# Trigger boundary is deliberately wider than the two units'
		# actual physical CollisionShape3D contact distance (see
		# _build_collision_shape() -- shape.radius == stats.collision_radius
		# exactly, so combined_radius alone IS the real touch boundary) --
		# separation needs room to redirect velocity BEFORE move_and_slide()'s
		# own real collision response hard-stops forward motion at that
		# exact boundary. Without this margin, a unit walking straight at
		# another settles into a stable equilibrium exactly at contact:
		# never quite overlapping enough for this function to push back,
		# yet still fully physically blocked from advancing (caught by
		# test_order_move_relocates_and_never_attacks going permanently
		# stuck ~0.005m short of its start position).
		var combined_radius := stats.collision_radius + other.stats.collision_radius + _AVOIDANCE_MARGIN
		if dist >= combined_radius:
			continue

		var push_dir: Vector2
		if dist > 0.0001:
			push_dir = offset / dist # cheaper than .normalized(), same result, dist already computed
		else:
			# Exactly coincident (two units spawned on the same point) --
			# offset has no direction to normalize. Break the tie with
			# each unit's own index in all_units (spawn/append order,
			# identical across a replayed match) rather than a zero
			# vector, which would otherwise normalize to NaN and leave
			# both units permanently stuck on top of each other.
			var tie_break := float(all_units.find(self) - all_units.find(other))
			push_dir = Vector2(sign(tie_break) if tie_break != 0.0 else 1.0, 0.0)

		var penetration := combined_radius - dist
		var strength := (penetration / combined_radius) * stat_block.move_speed()

		if is_moving and push_dir.dot(seek_dir) < -0.2:
			# Neighbor sits roughly ahead, blocking travel -- deflect to
			# whichever side the neighbor's actual offset already leans
			# (2D cross product sign, deterministic), not a fixed
			# always-left/right bias.
			var side := seek_dir.x * push_dir.y - seek_dir.y * push_dir.x
			var side_sign: float = sign(side) if side != 0.0 else 1.0
			var perp: Vector2 = Vector2(-seek_dir.y, seek_dir.x) * side_sign
			separation += perp * strength
		else:
			separation += push_dir * strength

	var final_velocity := seek_velocity + Vector3(separation.x, 0, separation.y)
	var move_speed := stat_block.move_speed()
	if final_velocity.length() > move_speed:
		final_velocity = final_velocity.normalized() * move_speed
	return final_velocity


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
## a point is in-bounds if it's within the vertical bar (|x| <= the
## effective width at this depth, any z within the platform's outer
## extent) OR the horizontal bar (mirrored). A point in neither -- a
## "dead corner" diagonally outside both arms -- gets pulled onto
## whichever bar it's already closer to (the axis with the smaller
## magnitude is the one pulled in to half_width; the other is just capped
## at the platform's outer extent). One deliberate exception: the 8
## lineup courtyards (CrossArenaMap._courtyard_center()) are themselves
## "dead corners" by this same definition -- without the early-out below,
## a unit standing in one would get yanked back onto an arm every single
## physics frame, starting the instant it's positioned there.
##
## "The effective width at this depth" accounts for the spawn platform at
## each arm's outer end (GameManager.CROSS_ARM_PLATFORM_HALF_WIDTH's own
## doc comment) -- CROSS_ARM_HALF_WIDTH out to CROSS_ARM_OUTER_EXTENT
## (the corridor, matching the center square), widening to
## CROSS_ARM_PLATFORM_HALF_WIDTH beyond that (the platform) -- a step,
## not a smooth taper, matching the platform's own rectangular ground
## visual (see CrossArenaMap.build()) rather than the narrower trapezoid
## its nav mesh actually uses for pathfinding connectivity.
func _clamp_to_cross_arena() -> void:
	if CrossArenaMap.is_in_any_courtyard(global_position):
		return

	var half_width := GameManager.CROSS_ARM_HALF_WIDTH
	var outer := GameManager.CROSS_ARM_OUTER_EXTENT
	var platform_half := GameManager.CROSS_ARM_PLATFORM_HALF_WIDTH
	var platform_outer := GameManager.CROSS_ARM_PLATFORM_OUTER_EXTENT
	var x := global_position.x
	var z := global_position.z

	var vertical_half_width := half_width if absf(z) <= outer else platform_half
	var horizontal_half_width := half_width if absf(x) <= outer else platform_half

	if absf(x) <= vertical_half_width:
		z = clampf(z, -platform_outer, platform_outer)
	elif absf(z) <= horizontal_half_width:
		x = clampf(x, -platform_outer, platform_outer)
	elif absf(x) < absf(z):
		x = clampf(x, -half_width, half_width)
		z = clampf(z, -platform_outer, platform_outer)
	else:
		z = clampf(z, -half_width, half_width)
		x = clampf(x, -platform_outer, platform_outer)

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


## Called once per physics frame while battling (see _physics_process()),
## regardless of order/no-order -- centralizes the delta-driven part of
## _chase_elapsed's bookkeeping so _update_target() itself (called from
## several different branches: default AI, HOLD, ATTACK_MOVE/PATROL/FOLLOW's
## fallback) only needs a threshold comparison, not delta.
func _tick_chase_elapsed(delta: float) -> void:
	if target_enemy != _last_chased_target:
		_last_chased_target = target_enemy
		_chase_elapsed = 0.0
		return
	if target_enemy == null or not is_instance_valid(target_enemy) or target_enemy.current_health <= 0.0:
		_chase_elapsed = 0.0
		return
	if _distance_to_target_edge(target_enemy) <= stat_block.attack_range():
		_chase_elapsed = 0.0 # actively fighting, not stuck
	else:
		_chase_elapsed += delta


## Keeps the current target_enemy only if it's still alive AND still
## within acquisition_range of this unit's *current* position -- checked
## fresh every call, not just at the moment a target was first picked, so
## a target that drifts out of range gets given up on rather than chased
## forever. Otherwise re-acquires via GameManager.find_nearest_enemy(),
## which applies the same acquisition_range cap to the search itself.
## Also gives up on an in-range-but-unreachable target once _chase_elapsed
## (tracked centrally in _physics_process(), incremented whenever
## target_enemy is valid but still outside attack_range) crosses
## _STUCK_CHASE_THRESHOLD -- see that const's own doc comment for the
## "several units orbiting one crowded target" problem this closes.
## _chase_elapsed resets regardless of whether a replacement was actually
## found, throttling retries to once per threshold window rather than
## re-scanning every single frame once stuck.
func _update_target() -> void:
	var target_is_valid := target_enemy != null and is_instance_valid(target_enemy) and target_enemy.current_health > 0.0
	if target_is_valid and horizontal_distance_to(global_position, target_enemy.global_position) <= stats.acquisition_range:
		if _chase_elapsed >= _STUCK_CHASE_THRESHOLD:
			_chase_elapsed = 0.0
			var replacement := GameManager.find_nearest_enemy(self, target_enemy)
			if replacement != null:
				target_enemy = replacement
				_last_chased_target = replacement
		return
	# Dropping an invalid/out-of-range target is immediate, regardless of
	# the reacquisition cooldown below -- only the (expensive) *search for
	# a replacement* is throttled, not "give up on what I can't reach
	# anymore," which existing callers (ATTACK_MOVE/PATROL/FOLLOW's own
	# "fight anything encountered" fallback, and tests like
	# test_an_already_engaged_unit_gives_up_once_its_target_drifts_beyond_acquisition_range)
	# expect to happen essentially the same frame it goes out of range.
	target_enemy = null
	if _reacquisition_cooldown > 0.0:
		return
	_reacquisition_cooldown = _TARGET_REACQUISITION_INTERVAL
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

	# UnitStats.turn_rate (default 0.0) gates a NEW swing on already
	# facing target_enemy -- 0.0 skips this check entirely, exactly the
	# pre-turn-rate behavior (fire regardless of facing). While still
	# turning, neither the cooldown nor a new swing progresses this
	# frame; already-committed windup above is unaffected, since facing
	# was already required before that swing ever committed.
	if stats.turn_rate > 0.0 and target_enemy != null and not _face_toward(target_enemy.global_position, delta):
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


## Rotates this unit toward `target_position` at UnitStats.turn_rate
## degrees/second, horizontal-only (matches every other facing/direction
## calculation in this class). Returns true once already facing within
## _FACING_TOLERANCE (or immediately, if turn_rate is somehow called with
## <= 0.0) -- callers gate on the return value to know whether the turn
## has finished this frame. Only used by _attack()'s turn_rate gate;
## regular movement facing (_physics_process()'s own look_at(), right
## after _compute_avoidance_velocity()) is untouched by this, since
## turn_rate only governs combat facing.
const _FACING_TOLERANCE := deg_to_rad(2.0)

func _face_toward(target_position: Vector3, delta: float) -> bool:
	var to_target := target_position - global_position
	to_target.y = 0.0
	if to_target.length() < 0.01 or stats.turn_rate <= 0.0:
		return true

	var desired_basis := Basis.looking_at(to_target, Vector3.UP)
	var current_quat := global_transform.basis.get_rotation_quaternion()
	var desired_quat := desired_basis.get_rotation_quaternion()
	var angle_remaining := current_quat.angle_to(desired_quat)
	if angle_remaining <= _FACING_TOLERANCE:
		return true

	var max_radians := deg_to_rad(stats.turn_rate) * delta
	if angle_remaining <= max_radians:
		global_transform.basis = desired_basis
		return true

	global_transform.basis = Basis(current_quat.slerp(desired_quat, max_radians / angle_remaining))
	return false


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


## Instantiates a Projectile (Scripts/Combat/Projectile.gd) aimed at `target`,
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
	var damage := stat_block.damage()
	if stats.crit_chance > 0.0 and SimRng.randf() < stats.crit_chance:
		damage *= stats.crit_multiplier
	var hit_landed := target.take_damage(DamageInstance.new(damage, self))
	if not hit_landed:
		return # evaded (see UnitStats.evasion) -- no splash, no on-hit ability, nothing else fires off a miss

	if stats.splash_radius > 0.0:
		_apply_splash_damage(target, damage)
	if stats.on_hit_ability != null:
		stats.on_hit_ability.trigger_on_hit(self, target, source_position)


## UnitStats.splash_radius > 0.0: every other hostile-to-this-unit,
## living unit within splash_radius of `primary_target`'s position also
## takes damage, linearly falling off from full damage at the primary
## target's own position to UnitStats.splash_falloff at the radius's
## edge. `primary_damage` is the primary target's own (possibly
## crit-multiplied) hit amount, passed in rather than re-read from
## stat_block.damage() so a critical hit's splash scales the same way --
## one crit roll per swing (see resolve_hit()), not a separate roll per
## splashed target. Goes through the normal take_damage() pipeline (so
## armor/the attack-armor-type table still apply per splashed target),
## but deliberately does NOT re-trigger on_hit_ability -- e.g. Giant's
## knockback firing once per splashed unit on every swing would be a
## very different (and much stronger) mechanic than "this attack also
## splashes," not what splash is meant to add.
func _apply_splash_damage(primary_target: Unit, primary_damage: float) -> void:
	for unit in GameManager.get_all_units():
		if unit == primary_target or unit == self or unit.life_state != LifeState.ALIVE:
			continue
		if not GameManager.alliances.is_hostile(player.team_id, unit.player.team_id):
			continue
		var distance := horizontal_distance_to(primary_target.global_position, unit.global_position)
		if distance > stats.splash_radius:
			continue
		var falloff := lerpf(1.0, stats.splash_falloff, distance / stats.splash_radius)
		unit.take_damage(DamageInstance.new(primary_damage * falloff, self))


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
## still takes SPELL/PURE. UnitStats.evasion (default 0.0, every
## existing archetype) can also avoid an ATTACK entirely, same as a
## miss -- checked after ETHEREAL but before any mitigation math, so an
## evaded hit costs no health and never reaches armor/the attack-armor
## table at all.
##
## Returns true if the hit actually landed (health was reduced), false
## if it was blocked/evaded/no-opped for any reason above -- resolve_hit()
## uses this to skip splash/on_hit_ability on a miss, since nothing
## should fire off an attack that never connected.
func take_damage(instance: DamageInstance) -> bool:
	if life_state == LifeState.DEAD:
		return false
	if is_invulnerable():
		return false
	if is_ethereal() and instance.damage_type == DamageInstance.DamageType.ATTACK:
		return false
	if instance.damage_type == DamageInstance.DamageType.ATTACK and stats.evasion > 0.0 and SimRng.randf() < stats.evasion:
		return false

	var mitigated := instance.amount
	if instance.damage_type != DamageInstance.DamageType.PURE:
		mitigated = maxf(instance.amount - stat_block.armor(), 1.0)
		if instance.damage_type == DamageInstance.DamageType.ATTACK and instance.source != null:
			mitigated *= AttackArmorTable.multiplier(instance.source.stats.attack_type, stats.armor_type)

	current_health -= mitigated
	_health_bar.set_fraction(current_health / stat_block.max_health())
	_hit_flash_remaining = _HIT_FLASH_DURATION
	_play_hit_squash()
	_spawn_damage_popup(mitigated, instance.damage_type)
	var attack_type := instance.source.stats.attack_type if instance.source != null else UnitStats.AttackType.NORMAL
	Sfx.play_attack_land(global_position, attack_type) # shared by melee and projectile impacts alike -- both funnel through here
	var impact_position := global_position + Vector3(0, stats.mesh_size.y * 0.6, 0)
	ImpactBurst.spawn(GameManager.units_container, impact_position, Color(0.9, 0.9, 0.85), 6, 40.0, 2.0, 0.25)
	damaged.emit(self, instance, mitigated)

	if current_health <= 0.0:
		die(instance.source)
	return true


## Restores up to `amount` health, capped at max -- the counterpart to
## take_damage(), used by Ability.gd's own `heal` field (see its doc
## comment). No mitigation/armor concept here, unlike damage -- a heal is
## never reduced.
func heal(amount: float) -> void:
	if life_state != LifeState.ALIVE:
		return
	current_health = minf(current_health + amount, stat_block.max_health())
	_health_bar.set_fraction(current_health / stat_block.max_health())


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
	_body_color_at_death = _body_material.get_shader_parameter("team_color")
	_position_y_at_death = global_position.y
	_collision_shape.disabled = true
	_health_bar.visible = false
	_status_indicator.hide_status()
	clear_all_effects()
	Sfx.play_death(global_position)
	BloodDecal.spawn(GameManager.units_container, global_position)
	ImpactBurst.spawn(GameManager.units_container, global_position + Vector3(0, stats.mesh_size.y * 0.4, 0), Color(0.55, 0.05, 0.05), 16, 65.0, 3.8, 0.5)
	died.emit(self, killer)


## Read-only snapshot for Scripts/Autoloads/DebugInspector.gd / UI/DebugPanel.gd,
## shown regardless of debug-menu toggles. Everything here is derived by
## re-reading existing public state -- this method never sets anything,
## so it can't affect AI, combat, or targeting. Values are pre-formatted
## display strings by design, so the debug panel stays a generic "print
## whatever keys this returns" renderer and never needs unit-specific
## formatting logic of its own.
##
## Name/Team/Health used to be included here too, but UI/HUD.gd's own
## unit info panel now shows exactly those in the same corner, so this
## stays scoped to genuinely debug-only info instead of duplicating it.
func get_debug_info() -> Dictionary:
	return {
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
