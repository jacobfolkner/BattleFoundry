## Per-instance runtime combat stats, seeded from a UnitStats archetype at
## spawn time.
##
## UnitStats is a shared, preload()ed Resource -- every unit of the same
## archetype (every Tank, say) points at the *same* object. Mutating it
## directly (the first buff that lowers move_speed) would silently affect
## every instance of that archetype, permanently, including units spawned
## in a later battle. StatBlock copies the base values out once at spawn
## and layers Modifiers on top instead, so the archetype Resource itself
## is never written to. Fields that aren't meant to be buffed (mesh,
## collision, flight, knockback) stay read directly off UnitStats -- see
## Unit.stats -- and have no equivalent here.
class_name StatBlock
extends RefCounted

enum ModifierOp { ADD, MULTIPLY }

## One buff/debuff line item. `source` is whatever applied it -- an
## Ability, an Item, a plain string tag -- kept opaque here so a future
## effect/aura framework can key removal/dispel off it without
## StatBlock needing to know those types exist yet.
class Modifier:
	var source: Variant
	var stat: String
	var op: ModifierOp
	var value: float

	func _init(p_source: Variant, p_stat: String, p_op: ModifierOp, p_value: float) -> void:
		source = p_source
		stat = p_stat
		op = p_op
		value = p_value


var base_max_health: float
var base_damage: float
var base_attack_range: float
var base_attack_interval: float
var base_move_speed: float
var base_armor: float

var _modifiers: Array[Modifier] = []


static func from_archetype(archetype: UnitStats) -> StatBlock:
	var block := StatBlock.new()
	block.base_max_health = archetype.max_health
	block.base_damage = archetype.damage
	block.base_attack_range = archetype.attack_range
	block.base_attack_interval = archetype.attack_interval
	block.base_move_speed = archetype.move_speed
	block.base_armor = archetype.armor
	return block


## Returns the Modifier so the caller can remove_modifier() it later (e.g.
## when a timed buff expires). Order of application is additive-then-
## multiplicative, gathered across all modifiers on a stat -- not applied
## one at a time in insertion order -- so modifier order never matters.
func add_modifier(source: Variant, stat: String, op: ModifierOp, value: float) -> Modifier:
	var modifier := Modifier.new(source, stat, op, value)
	_modifiers.append(modifier)
	return modifier


func remove_modifier(modifier: Modifier) -> void:
	_modifiers.erase(modifier)


## Bulk removal for "this Ability/Item is gone, drop everything it applied"
## -- the common case, since individual Modifier references are easy to
## lose track of (e.g. an aura reapplying every tick).
func remove_modifiers_from_source(source: Variant) -> void:
	for i in range(_modifiers.size() - 1, -1, -1):
		if _modifiers[i].source == source:
			_modifiers.remove_at(i)


func _compute(stat: String, base: float) -> float:
	var additive := 0.0
	var multiplier := 1.0
	for modifier in _modifiers:
		if modifier.stat != stat:
			continue
		if modifier.op == ModifierOp.ADD:
			additive += modifier.value
		else:
			multiplier *= modifier.value
	return (base + additive) * multiplier


func max_health() -> float:
	return _compute("max_health", base_max_health)


func damage() -> float:
	return _compute("damage", base_damage)


func attack_range() -> float:
	return _compute("attack_range", base_attack_range)


## Floored well above zero -- a 0s or negative cooldown would fire
## unboundedly many attacks in a single frame instead of just attacking fast.
func attack_interval() -> float:
	return maxf(_compute("attack_interval", base_attack_interval), 0.05)


func move_speed() -> float:
	return _compute("move_speed", base_move_speed)


func armor() -> float:
	return _compute("armor", base_armor)
