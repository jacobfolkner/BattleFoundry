## Describes one hit: how much, from whom, and what kind. Passed into
## Unit.take_damage() instead of a bare float so mitigation (armor),
## kill attribution, and future on-hit effects (lifesteal, thorns, crits)
## all have the information they need without take_damage() growing a new
## positional argument for each one.
##
## `damage_type` gates armor mitigation (PURE bypasses it entirely --
## the WC3-style "true damage" case). This is deliberately just enough
## to unblock the damage pipeline itself; a full attack-type x
## armor-type multiplier table is future work, not implemented here.
class_name DamageInstance
extends RefCounted

enum DamageType { ATTACK, SPELL, PURE }

var amount: float
var source: Unit ## Unit that dealt the hit. Null for environmental/scripted damage.
var damage_type: DamageType
var is_dodgeable: bool ## Reserved for a future miss/evasion system; unused today.
var is_reflectable: bool ## Reserved for a future spell-reflect effect; unused today.


func _init(p_amount: float, p_source: Unit = null, p_damage_type: DamageType = DamageType.ATTACK) -> void:
	amount = p_amount
	source = p_source
	damage_type = p_damage_type
	is_dodgeable = damage_type != DamageType.PURE
	is_reflectable = damage_type == DamageType.SPELL
