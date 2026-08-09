## Thin wrapper around a set of candidate Abilities for one hero ability
## slot -- exists only because GDScript's @export typing can't express
## "array of typed arrays" directly (UnitStats.ability_draft_choices
## needs an Array[Array[Ability]] shape, which isn't expressible as one
## @export field). candidates[0] is always the slot's default, applied
## automatically if the player never makes an explicit pick -- see
## Unit._resolve_abilities().
class_name AbilityChoiceSet
extends Resource

@export var candidates: Array[Ability] = []
