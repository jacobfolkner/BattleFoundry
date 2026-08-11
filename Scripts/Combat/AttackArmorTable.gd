## WC3-style attack-type x armor-type damage multiplier grid -- roadmap
## Phase 2's first combat-depth item ("armor is flat-reduction only right
## now"). Approximated from the reference genre's own table (exact
## percentages aren't load-bearing here, just the shape: PIERCING shreds
## light/unarmored targets and struggles against heavy ones, SIEGE excels
## against FORTIFIED, NORMAL is the flat/uneventful baseline). Applied on
## top of the existing flat armor subtraction in Unit.take_damage(), not a
## replacement for it.
##
## Static-only, never instantiated -- same shape as a plain lookup
## function, just namespaced under a class_name so callers don't need a
## bare global function or a singleton for something this small.
class_name AttackArmorTable
extends RefCounted

const _TABLE := {
	UnitStats.AttackType.NORMAL: {
		UnitStats.ArmorType.UNARMORED: 1.0,
		UnitStats.ArmorType.LIGHT: 1.0,
		UnitStats.ArmorType.MEDIUM: 1.0,
		UnitStats.ArmorType.HEAVY: 1.0,
		UnitStats.ArmorType.FORTIFIED: 0.7,
		UnitStats.ArmorType.HERO: 1.0,
	},
	UnitStats.AttackType.PIERCING: {
		UnitStats.ArmorType.UNARMORED: 1.5,
		UnitStats.ArmorType.LIGHT: 1.5,
		UnitStats.ArmorType.MEDIUM: 0.75,
		UnitStats.ArmorType.HEAVY: 0.5,
		UnitStats.ArmorType.FORTIFIED: 0.35,
		UnitStats.ArmorType.HERO: 0.5,
	},
	UnitStats.AttackType.SIEGE: {
		UnitStats.ArmorType.UNARMORED: 1.0,
		UnitStats.ArmorType.LIGHT: 1.0,
		UnitStats.ArmorType.MEDIUM: 1.0,
		UnitStats.ArmorType.HEAVY: 1.0,
		UnitStats.ArmorType.FORTIFIED: 1.5,
		UnitStats.ArmorType.HERO: 0.7,
	},
	UnitStats.AttackType.HERO: {
		UnitStats.ArmorType.UNARMORED: 1.0,
		UnitStats.ArmorType.LIGHT: 1.0,
		UnitStats.ArmorType.MEDIUM: 1.0,
		UnitStats.ArmorType.HEAVY: 1.0,
		UnitStats.ArmorType.FORTIFIED: 0.5,
		UnitStats.ArmorType.HERO: 1.0,
	},
}


static func multiplier(attack_type: UnitStats.AttackType, armor_type: UnitStats.ArmorType) -> float:
	return _TABLE[attack_type][armor_type]
