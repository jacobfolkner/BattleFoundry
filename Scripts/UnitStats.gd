## Data-driven definition of a unit archetype (Tank, Fighter, Archer, ...).
##
## Stored as a Resource (.tres) so new unit types can be added or tuned
## from the editor without touching code. See Resources/TankStats.tres,
## FighterStats.tres, and ArcherStats.tres for the concrete archetypes
## used by the prototype.
class_name UnitStats
extends Resource

@export var unit_name: String = "Unit"

@export_group("Combat")
@export var max_health: float = 100.0
@export var damage: float = 10.0
## Reach beyond this unit's own collision_radius, to the target's
## center -- not raw center-to-center distance. See
## Unit._distance_to_target_edge(). Keeps this a per-unit constant
## independent of the target's size, and leaves room for multiple
## attackers to stand in range of one target without their own bodies
## overlapping (a real problem when a unit's radius is a large fraction
## of its attack_range, as Giant's is).
@export var attack_range: float = 2.0
@export var attack_interval: float = 1.0 ## Seconds between attacks.
## Whether this unit can target a flying enemy at all. False by default
## (the classic "ground can't hit air" RTS convention) so a new
## archetype has to opt in rather than opt out -- see
## GameManager.find_nearest_enemy(). Irrelevant for a flying unit
## attacking a ground one; that's always allowed.
@export var can_attack_flying: bool = false
## Flat damage reduction applied to incoming ATTACK/SPELL damage (not
## PURE -- see DamageInstance). Seeds StatBlock.base_armor; buffs/debuffs
## modify the runtime copy, never this archetype value. This is a flat
## reduction only -- no attack-type x armor-type multipliers yet.
@export var armor: float = 0.0

@export_group("Abilities")
## Index 0/1/2 map to the Q/W/E hotkeys in Main.gd. NO_TARGET/UNIT_TARGET
## abilities here are player-triggered via Unit.cast_ability(); a PASSIVE
## one here is instead applied once, automatically, at spawn (see
## Unit._apply_passive_abilities()) -- it still lives in this same array,
## it just never responds to a hotkey since cast_ability() rejects
## PASSIVE. ON_HIT abilities don't go here at all -- see on_hit_ability
## below. An empty array is the common case: most archetypes have no
## abilities at all.
@export var abilities: Array[Ability] = []
## Fires automatically from Unit.resolve_hit() every time this archetype
## lands an attack -- e.g. Giant's knockback (Resources/GiantSlamAbility.tres).
## null (default, most archetypes) means no on-hit effect at all.
@export var on_hit_ability: Ability = null

@export_group("Projectile")
## 0 (default) means this attack deals damage the instant the cooldown
## allows, exactly like every archetype before this system existed.
## Above 0, Unit._attack() spawns a Projectile (Scripts/Projectile.gd)
## instead, which delivers the hit -- damage and any knockback -- only
## once it actually arrives, via Unit.resolve_hit().
@export var projectile_speed: float = 0.0
## Only read when projectile_speed > 0. True (default): the projectile
## tracks its target's current position every frame (WC3 arrows/most
## ranged autoattacks). False: aims once at the target's position at the
## moment it's fired and travels a straight line from there, so it can
## miss if the target moves out of the way before it arrives.
@export var projectile_homing: bool = true

@export_group("Movement")
@export var move_speed: float = 3.0 ## Meters per second.

@export_group("Flight")
## Flying units rest at flight_height instead of the ground plane, and
## combat range checks become horizontal-only for everyone as a result
## -- see Unit.horizontal_distance_to(). False (default) means this
## unit behaves exactly as before: ground-locked at y=0.
@export var is_flying: bool = false
@export var flight_height: float = 0.0

@export_group("Collision")
## Radius of the unit's physical footprint (a CapsuleShape3D in Unit.gd).
## Larger values make a unit harder to path around and more effective at
## physically blocking others -- this is how "tanks block movement" is
## expressed, entirely through data rather than unit-specific code.
@export var collision_radius: float = 0.5

@export_group("Appearance")
## Which primitive mesh represents this unit. Team color is applied
## separately at spawn time, so archetypes are told apart by shape/size.
@export_enum("Box", "Capsule", "Cone") var mesh_shape: String = "Box"
## Interpreted per-shape in Unit.gd:
## Box -> full size (x, y, z). Capsule -> radius (x), height (y).
## Cone -> base radius (x), height (y).
@export var mesh_size: Vector3 = Vector3(1.0, 1.0, 1.0)
