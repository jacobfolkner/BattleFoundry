## A one-shot floating damage number: rises and fades over its lifetime,
## then frees itself -- roadmap Phase 9's "floating combat text," the first
## piece of that phase to land (no animation/team-color shader/audio yet,
## still out of scope). Uses Label3D for the actual glyph rendering rather
## than a flat quad the way HealthBar/UnitStatusMarker do -- there's no way
## to draw an arbitrary number on an unshaded quad without a texture atlas,
## and Label3D needs no imported font/asset, matching this project's "no
## art assets at all" constraint just as much as a primitive mesh does.
## Closer in shape to Projectile.gd (spawns into GameManager.units_container,
## lives for a bounded lifetime, frees itself) than to HealthBar/
## UnitStatusMarker (both owned long-term by the Unit they decorate) --
## nothing owns a DamagePopup after Unit.take_damage() spawns it.
class_name DamagePopup
extends Node3D

const _LIFETIME := 0.8
const _RISE_SPEED := 1.3 ## Meters/second, straight up.

## Colored by DamageInstance.damage_type -- free differentiation, no new
## field needed on DamageInstance itself. Loosely mirrors WC3's own
## convention (white-ish physical hits, blue/purple magic).
const _COLOR_BY_DAMAGE_TYPE := {
	DamageInstance.DamageType.ATTACK: Color(1.0, 0.9, 0.2),
	DamageInstance.DamageType.SPELL: Color(0.55, 0.65, 1.0),
	DamageInstance.DamageType.PURE: Color(0.95, 0.95, 0.95),
}

var _elapsed: float = 0.0
var _label: Label3D


func _ready() -> void:
	_label = Label3D.new()
	_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_label.no_depth_test = true # always readable, even through another unit standing in front of it
	_label.font_size = 48
	_label.outline_size = 8
	add_child(_label)


func setup(amount: float, damage_type: DamageInstance.DamageType) -> void:
	_label.text = "%.0f" % amount
	_label.modulate = _COLOR_BY_DAMAGE_TYPE.get(damage_type, Color.WHITE)


## Ticked from Unit._spawn_damage_popup()'s caller's own _physics_process()
## indirectly -- this node has no Unit reference and isn't parented to one,
## so it ticks itself, matching Projectile.gd's own self-contained
## _physics_process() lifecycle rather than relying on anything else to
## drive it. Gameplay-timing convention (not _process()) for the same
## reason every other delta-driven timer in this project uses
## _physics_process() -- see CLAUDE.md/this file's own siblings -- so a
## GUT test can drive it deterministically via wait_physics_frames().
func _physics_process(delta: float) -> void:
	_elapsed += delta
	position.y += _RISE_SPEED * delta
	_label.modulate.a = clampf(1.0 - _elapsed / _LIFETIME, 0.0, 1.0)
	if _elapsed >= _LIFETIME:
		queue_free()
