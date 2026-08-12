## Top-down dot map, bottom-right corner: one colored dot per living unit
## (Player.color), redrawn every frame, plus a gray outline showing the
## current OrbitCamera's own view footprint on the ground (see
## _camera_view_corners_on_ground()). A hand-drawn Control._draw(),
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

const _SIZE := 220.0
const _MARGIN := 16.0
const _DOT_RADIUS := 4.0 # scaled up alongside _SIZE so a unit dot doesn't shrink relative to the bigger map
const _VIEW_BOX_COLOR := Color(0.9, 0.9, 0.9, 0.7)
const _VIEW_BOX_WIDTH := 1.5
const _GROUND_PLANE := Plane(Vector3.UP, 0.0)
## Lighter than _background -- reads as "walkable ground" against the
## dark surrounding void; a blank square with only dots on it gives no
## sense of where you are relative to the playable area.
const _ARENA_SHAPE_COLOR := Color(0.48, 0.51, 0.44, 1.0)
## Mirrors CrossArenaMap's own per-arm tints (brightened to hold contrast
## against the minimap's own near-black background) so the minimap reads
## as the same map, not a differently-colored abstraction of it.
const _NORTH_ARM_COLOR := Color(0.4, 0.48, 0.56, 1.0)
const _EAST_ARM_COLOR := Color(0.56, 0.42, 0.4, 1.0)
const _SOUTH_ARM_COLOR := Color(0.4, 0.56, 0.44, 1.0)
const _WEST_ARM_COLOR := Color(0.56, 0.53, 0.38, 1.0)
## A visible edge so the minimap reads as a defined instrument panel
## rather than blending into whatever's behind it in the viewport corner.
const _BORDER_COLOR := Color(0.75, 0.75, 0.7, 0.9)

var _background: ColorRect


func _ready() -> void:
	custom_minimum_size = Vector2(_SIZE, _SIZE)
	reset_size()
	mouse_filter = Control.MOUSE_FILTER_IGNORE

	_background = ColorRect.new()
	_background.color = Color(0.08, 0.08, 0.08, 0.8)
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
## units -- the cross map's arms (and, further out, their spawn
## platforms -- GameManager.CROSS_ARM_PLATFORM_OUTER_EXTENT) reach
## further from center than the plain square arena
## (GameManager.ARENA_HALF_EXTENT) does, so a unit near a cross-map
## platform's spawn point would otherwise plot outside the square arena's
## tighter bounds. Read once per frame (_process()'s queue_redraw()
## already runs once per frame regardless of unit count), not per-unit --
## unlike GameMode.uses_cross_map()'s own per-unit-per-frame hot path in
## Unit._clamp_to_arena(), there's no equivalent cost concern here.
func _current_half_extent() -> float:
	return GameManager.CROSS_ARM_PLATFORM_OUTER_EXTENT if GameManager.current_mode.uses_cross_map() else GameManager.ARENA_HALF_EXTENT


func _world_to_map(world_position: Vector3, half_extent: float) -> Vector2:
	var normalized_x := clampf(world_position.x / half_extent, -1.0, 1.0)
	var normalized_z := clampf(world_position.z / half_extent, -1.0, 1.0)
	return Vector2((normalized_x * 0.5 + 0.5) * _SIZE, (normalized_z * 0.5 + 0.5) * _SIZE)


## The 4 viewport-corner rays, intersected against the ground plane (y=0).
## The actual visible-on-the-ground area for an OrbitCamera looking down
## at an angle is a trapezoid (the far edge of the view covers more
## ground per pixel than the near edge), but the overlay this feeds
## (_draw()) deliberately draws an upright rectangle instead of that raw
## shape -- simple full-coverage from a birds-eye read, not perspective
## accuracy. Skips (rather than aborts on) any corner ray that doesn't
## hit the ground plane at all -- can happen at OrbitCamera's shallowest
## pitch, where a ray toward the top of the screen points above the
## horizon -- so a partial hit still produces a usable, if smaller, box
## instead of the overlay vanishing entirely. Empty only if literally
## none of the 4 hit.
func _camera_view_corners_on_ground() -> Array[Vector3]:
	var camera := get_viewport().get_camera_3d()
	if camera == null:
		return []
	var viewport_size := get_viewport().get_visible_rect().size
	var screen_corners := [Vector2.ZERO, Vector2(viewport_size.x, 0), viewport_size, Vector2(0, viewport_size.y)]
	var world_corners: Array[Vector3] = []
	for screen_corner in screen_corners:
		var from := camera.project_ray_origin(screen_corner)
		var direction := camera.project_ray_normal(screen_corner)
		var hit = _GROUND_PLANE.intersects_ray(from, direction)
		if hit != null:
			world_corners.append(hit)
	return world_corners


## Fills in the actual arena footprint (a plain square for classic mode,
## the cross's center-plus-4-arms shape for Blood Tournament) so the
## minimap reads as "a map" rather than an undifferentiated dark square
## with dots on it -- drawn first, everything else layers on top.
func _draw_arena_shape() -> void:
	if GameManager.current_mode.uses_cross_map():
		_draw_cross_arena_shape()
	else:
		draw_rect(Rect2(Vector2.ZERO, Vector2(_SIZE, _SIZE)), _ARENA_SHAPE_COLOR)


## 5 filled rects (center square + 4 arms) plus 4 more for the wider
## spawn platform at each arm's outer end, the same footprint
## CrossArenaMap.build() lays out, plus one small team-colored rect per
## registered team's lineup courtyard. Mapped through _world_to_map()
## and Rect2(...).expand(...) the same way the view-box overlay does,
## robust regardless of which world axis maps to which minimap-local sign.
func _draw_cross_arena_shape() -> void:
	var half_extent := _current_half_extent()
	var w := GameManager.CROSS_ARM_HALF_WIDTH
	var o := GameManager.CROSS_ARM_OUTER_EXTENT
	var p := GameManager.CROSS_ARM_PLATFORM_HALF_WIDTH
	var po := GameManager.CROSS_ARM_PLATFORM_OUTER_EXTENT
	var pieces: Array = [
		[Vector3(-w, 0, -w), Vector3(w, 0, w), _ARENA_SHAPE_COLOR],  # center -- untinted, shared convergence point
		[Vector3(-w, 0, -o), Vector3(w, 0, -w), _NORTH_ARM_COLOR],
		[Vector3(-w, 0, w), Vector3(w, 0, o), _SOUTH_ARM_COLOR],
		[Vector3(w, 0, -w), Vector3(o, 0, w), _EAST_ARM_COLOR],
		[Vector3(-o, 0, -w), Vector3(-w, 0, w), _WEST_ARM_COLOR],
		[Vector3(-p, 0, -po), Vector3(p, 0, -o), _NORTH_ARM_COLOR],
		[Vector3(-p, 0, o), Vector3(p, 0, po), _SOUTH_ARM_COLOR],
		[Vector3(o, 0, -p), Vector3(po, 0, p), _EAST_ARM_COLOR],
		[Vector3(-po, 0, -p), Vector3(-o, 0, p), _WEST_ARM_COLOR],
	]
	for piece in pieces:
		var mapped_min := _world_to_map(piece[0], half_extent)
		var mapped_max := _world_to_map(piece[1], half_extent)
		draw_rect(Rect2(mapped_min, Vector2.ZERO).expand(mapped_max), piece[2])

	var courtyard_half := Vector3(CrossArenaMap.COURTYARD_HALF_EXTENT, 0, CrossArenaMap.COURTYARD_HALF_EXTENT)
	for team_id in GameManager.all_team_ids():
		var center := CrossArenaMap.get_courtyard_center(team_id)
		var color := GameManager.get_player(team_id).color
		color.a = 0.55 # translucent -- a team area reads as "part of the map," not a full-strength dot-like marker competing with the live unit dots drawn on top later
		var mapped_min := _world_to_map(center - courtyard_half, half_extent)
		var mapped_max := _world_to_map(center + courtyard_half, half_extent)
		draw_rect(Rect2(mapped_min, Vector2.ZERO).expand(mapped_max), color)


func _draw() -> void:
	var half_extent := _current_half_extent()

	_draw_arena_shape()

	var view_corners := _camera_view_corners_on_ground()
	if not view_corners.is_empty():
		var min_x := view_corners[0].x
		var max_x := view_corners[0].x
		var min_z := view_corners[0].z
		var max_z := view_corners[0].z
		for corner in view_corners:
			min_x = minf(min_x, corner.x)
			max_x = maxf(max_x, corner.x)
			min_z = minf(min_z, corner.z)
			max_z = maxf(max_z, corner.z)
		# Rect2(...).expand(...), not a raw min/max pairing -- robust
		# regardless of which world axis maps to which minimap-local
		# sign (same idiom HUD.gd's own drag box uses).
		var mapped_min := _world_to_map(Vector3(min_x, 0, min_z), half_extent)
		var mapped_max := _world_to_map(Vector3(max_x, 0, max_z), half_extent)
		var rect := Rect2(mapped_min, Vector2.ZERO).expand(mapped_max)
		draw_rect(rect, _VIEW_BOX_COLOR, false, _VIEW_BOX_WIDTH)

	for unit in GameManager.get_all_units():
		if unit.life_state != Unit.LifeState.ALIVE:
			continue
		var dot_position := _world_to_map(unit.global_position, half_extent)
		draw_circle(dot_position, _DOT_RADIUS, unit.player.color)

	draw_rect(Rect2(Vector2.ZERO, Vector2(_SIZE, _SIZE)), _BORDER_COLOR, false, 1.5)
