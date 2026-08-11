## Data-driven definition of one shop upgrade: a gold cost plus the
## permanent Effect it applies. Deliberately thin -- `ability` does all the
## actual work via Ability.cast_unit_target() (see
## GameManager.buy_upgrade()), the same Resource/Effect machinery
## abilities already use, just re-fired with the owning unit as both
## caster and target instead of an enemy. `ability` is expected to be a
## permanent effect (effect_duration == 0, or a PASSIVE-style stat
## modifier) -- a timed one would just wear off, which is a valid if odd
## thing to buy, not something this class needs to forbid.
class_name UnitUpgrade
extends Resource

@export var upgrade_name: String = "Upgrade"
@export var cost: int = 0
@export var ability: Ability
## When true, GameManager.buy_roster_upgrade()/_spawn_roster_squad_at()
## only apply this to squads whose UnitStats.is_hero is true, instead of
## every squad in the roster.
@export var heroes_only: bool = false
