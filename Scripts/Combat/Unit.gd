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
## a different enemy instead (gameplay feedback, 2026-08-11: "units often
## run around chasing a target when there's other units following them" --
## GameManager.find_nearest_enemy() is purely geometric-distance-based
## with no crowding awareness, so once several allies converge on the
## same nearest enemy, whichever ones can't find an open attack_range
## slot around it keep re-pathing toward an already-occupied spot,
## getting deflected by avoidance every time -- the "circling" this
## fixes). Deliberately NOT applied to a forced ATTACK_MOVE target
## (right-click a specific enemy) -- see _process_order()'s own
## ATTACK_MOVE branch, which sets target_enemy directly and never calls
## _update_target() at all, so a deliberate player order is never
## silently overridden, only the default autonomous "fight whatever's
## nearest" acquisition is.
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
## Roadmap Phase 9's "hit flash" -- how long a landed hit tints
## _body_material toward _HIT_FLASH_COLOR before easing back to
## player.color. Purely cosmetic, ticked in _physics_process() (not
## _process()) for the same reason every other delta-driven timer in this
## project is -- see _tick_hit_flash()'s own doc comment.
const _HIT_FLASH_DURATION := 0.15
const _HIT_FLASH_COLOR := Color(1.0, 1.0, 1.0)

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
## while a purchased squad is just standing in its courtyard -- a
## squad_size-5 Fighter purchase used to spawn all 5 visibly stacked
## side by side in the (relatively small) courtyard, which read as
## visual clutter for what's really "one roster slot" (usability
## feedback, 2026-08-11). All squad_size members are still real, fully
## set-up Unit instances the whole time (upgrades/hero-progress applied
## once at spawn, same as before) -- only rendering and click/raycast
## targeting are suppressed; BloodTournamentController.begin_march()
## calls this with `true` on every squad member to reveal the full squad
## again the instant marching starts. Node visibility already hides
## every child (health bar, status marker) for free.
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
	if stats.aura_ability == null:
		return
	_aura_tick_elapsed += delta
	if _aura_tick_elapsed < _AURA_TICK_INTERVAL:
		return
	_aura_tick_elapsed = 0.0
	stats.aura_ability.apply_aura(self)


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


## Eases _body_material back toward player.color over _HIT_FLASH_DURATION
## -- take_damage() is what actually starts a flash (sets
## _hit_flash_remaining), this just ticks it down every physics frame.
## Never runs while DEAD (see _physics_process()'s early return above) --
## die()'s own corpse-decay tick owns _body_material.albedo_color
## exclusively from that point on, so the two never fight over it.
func _tick_hit_flash(delta: float) -> void:
	if _hit_flash_remaining <= 0.0:
		return
	_hit_flash_remaining = maxf(_hit_flash_remaining - delta, 0.0)
	_body_material.albedo_color = player.color.lerp(_HIT_FLASH_COLOR, _hit_flash_remaining / _HIT_FLASH_DURATION)


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

	_body_material = StandardMaterial3D.new()
	_body_material.albedo_color = player.color
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

	# The Builder is a permanent, invulnerable, move_speed == 0 courtyard
	# fixture (see GameManager.spawn_courtyard_fixture()'s own doc
	# comment) -- it never has a _nav_agent (see _build_avoidance() below)
	# and should never move at all. Without this it still called
	# move_and_slide() every frame via _on_safe_velocity_computed(),
	# which resolves any physical overlap (another unit bumping it,
	# another courtyard squad spawned too close) by pushing it away --
	# reading as the Builder wandering off its spawn point over a long
	# match (gameplay feedback, 2026-08-11: "the builder should just be a
	# stationary unit").
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
	# Kept in sync every frame (not just at spawn) so a future move_speed
	# buff/debuff actually changes how fast avoidance lets this unit go.
	_nav_agent.max_speed = stat_block.move_speed()

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
## regular movement facing (_on_safe_velocity_computed()'s look_at()) is
## untouched by this, since turn_rate only governs combat facing.
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
	if stats.crit_chance > 0.0 and randf() < stats.crit_chance:
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
	if instance.damage_type == DamageInstance.DamageType.ATTACK and stats.evasion > 0.0 and randf() < stats.evasion:
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
	_body_color_at_death = _body_material.albedo_color
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
