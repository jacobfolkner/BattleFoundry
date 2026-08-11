## A timed or permanent effect applied to a Unit -- the "Effect" half of
## the roadmap's "Effect / Modifier framework." Carries at most one CC
## flag (stun/root/silence/invulnerable/ethereal) and at most one
## StatBlock stat modifier; either or both may be unused (empty string
## `stat` means "no stat modifier"). Unit owns applying/removing these --
## see Unit.apply_effect()/_active_effects.
class_name Effect
extends RefCounted

## STACK: multiple instances with the same id can coexist independently
## (each expires on its own timer). REFRESH: a reapplication just resets
## the existing instance's elapsed time back to 0, instead of adding a
## second one. STRONGEST_WINS: a reapplication only replaces the existing
## instance if its `magnitude` is greater; a weaker reapplication is
## dropped entirely.
enum StackRule { STACK, REFRESH, STRONGEST_WINS }

enum CCFlag { NONE, STUN, ROOT, SILENCE, INVULNERABLE, ETHEREAL }

## Identifies this effect for stacking/lookup purposes -- e.g. "stun",
## "frost_bolt_slow". Two Effects with the same id are what
## stack_rule's REFRESH/STRONGEST_WINS compare against each other.
var id: String
## Whatever applied this -- an Ability, another Unit, a plain string tag.
## Opaque here, same pattern as StatBlock.Modifier.source.
var source: Variant
## 0.0 means permanent -- only removed by clear_all_effects() (on death)
## or an explicit remove_effects_from_source() call, never by its own
## elapsed timer.
var duration: float
var elapsed: float = 0.0
var cc_flag: CCFlag = CCFlag.NONE
var stack_rule: StackRule = StackRule.REFRESH
## Only meaningful for STRONGEST_WINS -- larger magnitude beats smaller
## when both apply the same id (e.g. two different slows fighting over
## which percentage actually applies).
var magnitude: float = 0.0

## Optional StatBlock modifier applied for the lifetime of this Effect --
## see StatBlock.add_modifier(). `stat == ""` means this Effect carries
## no stat modifier at all (a pure CC effect, e.g. plain stun).
var stat: String = ""
var stat_op: StatBlock.ModifierOp = StatBlock.ModifierOp.ADD
var stat_value: float = 0.0


func _init(p_id: String, p_duration: float, p_source: Variant = null) -> void:
	id = p_id
	duration = p_duration
	source = p_source


func with_cc(flag: CCFlag) -> Effect:
	cc_flag = flag
	return self


func with_stat_modifier(p_stat: String, p_op: StatBlock.ModifierOp, p_value: float) -> Effect:
	stat = p_stat
	stat_op = p_op
	stat_value = p_value
	return self


func with_stack_rule(rule: StackRule, p_magnitude: float = 0.0) -> Effect:
	stack_rule = rule
	magnitude = p_magnitude
	return self
