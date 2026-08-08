## Data-driven definition of one ability -- cast type, range, cooldown,
## and what it actually does (damage, an Effect, knockback) -- stored as
## a Resource so new abilities are authored from the editor, the same
## pattern UnitStats already established for archetypes.
##
## v1 scope, deliberately: cast_time always 0 (instant) -- there's no
## cast-bar UI to show progress against, and no interruption mechanic
## yet, so a nonzero cast_time would just be dead data. Real cast times
## are the natural next increment once a UI exists to represent them.
class_name Ability
extends Resource

## PASSIVE applies once, permanently, the instant the owning Unit spawns
## -- never player-triggered, never goes on cooldown. ON_HIT isn't
## player-triggered either: Unit.resolve_hit() fires it automatically on
## every landed attack, the same moment the old hardcoded
## stats.knockback_distance check used to (see knockback_distance below
## -- this is knockback ported into the ability framework, not a new
## mechanic).
enum CastType { NO_TARGET, UNIT_TARGET, PASSIVE, ON_HIT }

@export var ability_name: String = "Ability"
@export var cast_type: CastType = CastType.NO_TARGET
@export var range: float = 0.0 ## UNIT_TARGET only -- max distance (beyond the caster's own collision edge) to a legal target.
@export var cooldown: float = 0.0 ## Seconds. Ignored by PASSIVE/ON_HIT.

## NO_TARGET only. 0 (default) means "affects the caster itself" (a
## self-buff/utility ability); above 0 means "every hostile unit within
## this many meters of the caster" (an AoE like War Stomp).
@export var aoe_radius: float = 0.0

@export_group("Effect")
## 0 means this ability applies no Effect at all (a pure-damage nuke, or
## an ON_HIT ability that's only knockback). See Effect.gd.
@export var effect_duration: float = 0.0
@export var effect_cc_flag: Effect.CCFlag = Effect.CCFlag.NONE
@export var effect_stat: String = "" ## StatBlock stat name, e.g. "move_speed". "" means no stat modifier.
@export var effect_stat_op: StatBlock.ModifierOp = StatBlock.ModifierOp.ADD
@export var effect_stat_value: float = 0.0

@export_group("Damage")
@export var damage: float = 0.0 ## 0 means this ability deals no direct damage.
@export var damage_type: DamageInstance.DamageType = DamageInstance.DamageType.SPELL

@export_group("Knockback (ON_HIT only)")
## Positional, not a StatBlock/CC concept, so it's applied via
## Unit.apply_knockback() directly rather than through the Effect
## framework -- see Effect.gd's doc comment. 0 means this ability has no
## knockback component.
@export var knockback_distance: float = 0.0
@export var knockback_height: float = 0.0


## NO_TARGET: hits the caster itself (aoe_radius == 0) or every hostile
## unit within aoe_radius (aoe_radius > 0).
func cast_no_target(caster: Unit) -> void:
	if aoe_radius <= 0.0:
		_apply_to(caster, caster)
		return
	for unit in GameManager.get_all_units():
		if unit == caster or unit.life_state != Unit.LifeState.ALIVE:
			continue
		if not GameManager.alliances.is_hostile(caster.player.team_id, unit.player.team_id):
			continue
		if Unit.horizontal_distance_to(caster.global_position, unit.global_position) <= aoe_radius:
			_apply_to(caster, unit)


func cast_unit_target(caster: Unit, target: Unit) -> void:
	_apply_to(caster, target)


## Called once by Unit._apply_passive_abilities() at spawn -- never
## again, and never gated by cooldown (PASSIVE abilities don't have one).
func cast_passive(caster: Unit) -> void:
	_apply_to(caster, caster)


## Triggered from Unit.resolve_hit(), not cast by a player -- fires
## automatically whenever the owning archetype lands an attack. This is
## knockback's new home: Giant's on-hit launch used to be a hardcoded
## `stats.knockback_distance > 0.0` check in resolve_hit() itself;
## that's now just an ON_HIT Ability like any other, with the exact same
## distance/height values (see Resources/GiantSlamAbility.tres).
func trigger_on_hit(caster: Unit, target: Unit, source_position: Vector3) -> void:
	_apply_to(caster, target)
	if knockback_distance > 0.0 and is_instance_valid(target) and target.current_health > 0.0:
		var direction := target.global_position - source_position
		direction.y = 0.0
		if direction.length_squared() < 0.0001:
			direction = Vector3.FORWARD
		target.apply_knockback(direction.normalized(), knockback_distance, knockback_height)


func _apply_to(caster: Unit, target: Unit) -> void:
	if not is_instance_valid(target) or target.life_state != Unit.LifeState.ALIVE:
		return
	if damage > 0.0:
		target.take_damage(DamageInstance.new(damage, caster, damage_type))
	if target.life_state != Unit.LifeState.ALIVE:
		return # the damage above could have killed it -- nothing left to apply an Effect to
	if effect_duration > 0.0 or effect_cc_flag != Effect.CCFlag.NONE or effect_stat != "":
		var effect := Effect.new(ability_name, effect_duration, self)
		if effect_cc_flag != Effect.CCFlag.NONE:
			effect.with_cc(effect_cc_flag)
		if effect_stat != "":
			effect.with_stat_modifier(effect_stat, effect_stat_op, effect_stat_value)
		target.apply_effect(effect)
