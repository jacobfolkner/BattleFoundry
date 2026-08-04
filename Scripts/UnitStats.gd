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
@export var attack_range: float = 2.0
@export var attack_interval: float = 1.0 ## Seconds between attacks.

@export_group("Movement")
@export var move_speed: float = 3.0 ## Meters per second.

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
