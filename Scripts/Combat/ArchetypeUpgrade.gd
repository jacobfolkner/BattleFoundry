## Data-driven definition of one per-archetype shop upgrade -- gameplay
## feedback, 2026-08-12: "we dont currently have much use for blood
## points.. in real blood tournament games you have optional upgrades
## for units, like for archers it may add 1 mortar unit and 2 additional
## archers for some cost or add an aura."
##
## Distinct from UnitUpgrade (that class is a flat, account-wide stat
## buff applied to every squad or every hero, via Ability.cast_unit_target()) --
## this one is scoped to a single `archetype` and can change what a
## purchased squad of that archetype actually deploys as, not just its
## stats. Bought once per player via GameManager.buy_archetype_upgrade(),
## persists for the rest of the match the same way Player.roster_upgrades
## does, and is re-applied by GameManager._spawn_roster_squad_at() every
## time a squad of `archetype` is realized from then on (a fresh round's
## courtyard sync, a mid-round purchase, ...).
##
## All three effects below are optional and independently combinable on
## one upgrade (a real WC3 Blood Tournament upgrade might grant a bonus
## unit AND an aura at once) -- an upgrade that sets none of them is a
## harmless no-op, not an error.
class_name ArchetypeUpgrade
extends Resource

@export var upgrade_name: String = "Upgrade"
@export var cost: int = 0
## Which archetype this upgrade applies to -- GameManager._spawn_roster_squad_at()
## only expands/buffs a squad whose roster-slot UnitStats matches this
## exactly (same object identity, not just unit_name).
@export var archetype: UnitStats

@export_group("Squad composition")
## How many EXTRA copies of `archetype` itself to add to the squad, on
## top of archetype.squad_size -- "2 additional archers."
@export var extra_base_units: int = 0
## An optional different unit type to add to the squad -- "1 mortar
## unit." Null (default) means no bonus unit type at all.
@export var bonus_unit_stats: UnitStats = null
@export var bonus_unit_count: int = 0

@export_group("Aura")
## Granted to every member of the squad as Unit.granted_aura_ability
## (NOT stats.aura_ability -- see that field's own doc comment for why
## this has to be per-instance) -- "or add an aura." Null (default)
## means no aura granted.
@export var aura_ability: Ability = null
