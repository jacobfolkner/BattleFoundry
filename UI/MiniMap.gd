## Top-down dot map, bottom-right corner: one colored dot per living unit
## (Player.color), redrawn every frame. A hand-drawn Control._draw(),
## not a SubViewport-rendered camera -- this project's whole visual style
## is still primitive meshes/flat colors (see BattleFoundry-Roadmap.md's
## Phase 9), so a second real 3D render target would be pure cost for no
## benefit over just plotting positions directly; revisit this choice if
## Phase 9 ever adds real terrain/geometry worth actually seeing.
##
## Parented directly to HUD's own top-level Control (the same
## "PanelContainer positioned via anchors on a parentless Control never
## resolves" trap CLAUDE.md documents) -- positioned from
## get_viewport_rect().size after reset_size(), same pattern HUD.gd's own
## gold label/hero level label/targeting prompt already use, not anchors.
class_name MiniMap
extends Control

const _SIZE := 160.0
const _MARGIN := 16.0
const _DOT_RADIUS := 3.0

var _background: ColorRect


func _ready() -> void:
	custom_minimum_size = Vector2(_SIZE, _SIZE)
	reset_size()
	mouse_filter = Control.MOUSE_FILTER_IGNORE

	_background = ColorRect.new()
	_background.color = Color(0.05, 0.05, 0.05, 0.75)
	_background.size = Vector2(_SIZE, _SIZE)
	_background.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_background)

	_reposition()


func _process(_delta: float) -> void:
	_reposition() # viewport can resize; cheap enough to just redo every frame, same as HUD.gd's other viewport-relative labels
	queue_redraw()


func _reposition() -> void:
	var viewport_size := get_viewport_rect().size
	position = viewport_size - Vector2(_SIZE + _MARGIN, _SIZE + _MARGIN)


## Half-extent of whichever arena shape is currently active, in world
## units -- the cross map's arms reach further from center
## (GameManager.CROSS_ARM_OUTER_EXTENT) than the plain square arena
## (GameManager.ARENA_HALF_EXTENT) does, so a unit near a cross-map arm's
## spawn point would otherwise plot outside the square arena's tighter
## bounds. Read once per frame (_process()'s queue_redraw() already runs
## once per frame regardless of unit count), not per-unit -- unlike
## GameMode.uses_cross_map()'s own per-unit-per-frame hot path in
## Unit._clamp_to_arena(), there's no equivalent cost concern here.
func _current_half_extent() -> float:
	return GameManager.CROSS_ARM_OUTER_EXTENT if GameManager.current_mode.uses_cross_map() else GameManager.ARENA_HALF_EXTENT


func _world_to_map(world_position: Vector3, half_extent: float) -> Vector2:
	var normalized_x := clampf(world_position.x / half_extent, -1.0, 1.0)
	var normalized_z := clampf(world_position.z / half_extent, -1.0, 1.0)
	return Vector2((normalized_x * 0.5 + 0.5) * _SIZE, (normalized_z * 0.5 + 0.5) * _SIZE)


func _draw() -> void:
	var half_extent := _current_half_extent()
	for unit in GameManager.get_all_units():
		if unit.life_state != Unit.LifeState.ALIVE:
			continue
		var dot_position := _world_to_map(unit.global_position, half_extent)
		draw_circle(dot_position, _DOT_RADIUS, unit.player.color)
