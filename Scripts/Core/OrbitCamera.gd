## Orbit camera: scroll to zoom, right-click-drag to orbit, arrow keys or
## WASD or edge-pan to move the focus point around the arena, Space to
## jump to your own hero. Self-contained -- Main.gd doesn't touch the
## camera at all beyond focus_and_zoom() (used to frame a fresh Blood
## Tournament round), including for jump-to-hero (queries
## GameManager/SelectionManager directly, both autoloads).
class_name OrbitCamera
extends Camera3D

## Both arrow keys and WASD pan the camera (see _key_pan_direction()) --
## ability/order hotkeys were moved to Q/E/R + X specifically so W/A/S/D
## have zero collision with a real in-battle action (see Hotkeys.gd's
## own doc comment).
const _ZOOM_STEP := 2.0
const _MIN_DISTANCE := 8.0
const _MAX_DISTANCE := 45.0
const _MIN_PITCH := deg_to_rad(15.0)
const _MAX_PITCH := deg_to_rad(85.0)
const _ORBIT_SENSITIVITY := 0.005
## Generous enough to cover the 8-team cross map's arms
## (CrossArenaMap.SPAWN_POINTS reach roughly +-32) without this camera
## needing to know which arena shape is active -- panning a little past
## the smaller square arena's edge into empty space is harmless.
const _PAN_BOUND := 44.0
const _PAN_SPEED := 24.0 ## Meters per second, arrow keys and edge-pan alike.
const _EDGE_PAN_MARGIN := 12.0 ## Pixels from the viewport edge that starts edge-pan.

var _distance := 25.6
var _yaw := 0.0
var _pitch := deg_to_rad(51.0) # matches the previous fixed position (0, 20, 16)
var _focus_point := Vector3.ZERO

## Screen shake state -- see shake()/_current_shake_offset(). Magnitude
## decays linearly to zero over _shake_duration so a shake always settles
## back to the camera's real position rather than snapping.
var _shake_duration := 0.0
var _shake_time_remaining := 0.0
var _shake_magnitude := 0.0


func _ready() -> void:
	_update_transform()


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP:
			_distance = clampf(_distance - _ZOOM_STEP, _MIN_DISTANCE, _MAX_DISTANCE)
			_update_transform()
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_distance = clampf(_distance + _ZOOM_STEP, _MIN_DISTANCE, _MAX_DISTANCE)
			_update_transform()
	elif event is InputEventMouseMotion and Input.is_mouse_button_pressed(MOUSE_BUTTON_RIGHT):
		_yaw -= event.relative.x * _ORBIT_SENSITIVITY
		_pitch = clampf(_pitch + event.relative.y * _ORBIT_SENSITIVITY, _MIN_PITCH, _MAX_PITCH)
		_update_transform()
	elif event is InputEventKey and event.pressed and not event.echo and event.is_action_pressed("jump_to_hero"):
		_jump_to_own_hero()


## Continuous (held-key/cursor-position) panning, not discrete events --
## belongs in _process(), not _unhandled_input(). Skips edge-pan entirely
## under the headless display driver GUT's test suite runs under: with no
## real cursor, get_mouse_position() reads a fixed (0, 0) every frame,
## which sits exactly in the top-left edge-pan zone -- left unguarded,
## every test that loads Main.tscn (nearly all of them) would silently
## drift the camera every physics frame, corrupting any test's
## screen-to-world raycasts (_camera.project_ray_origin()/project_ray_normal(),
## used throughout click-to-place/select/drag-reposition tests) in a way
## that would misdiagnose as an unrelated failure. Key-based panning
## (arrows or WASD) doesn't need the same guard -- Input.is_action_pressed()
## correctly reads false with no real input device under headless.
func _process(delta: float) -> void:
	var shake_active := _shake_time_remaining > 0.0
	if shake_active:
		_shake_time_remaining = maxf(_shake_time_remaining - delta, 0.0)

	var pan_direction := _key_pan_direction()
	if DisplayServer.get_name() != "headless":
		pan_direction += _edge_pan_direction()
	if pan_direction == Vector2.ZERO:
		if shake_active:
			_update_transform() # nothing panned, but the shake offset still needs to decay on-screen
		return

	pan_direction = pan_direction.normalized()
	# _update_transform() places the camera on the +forward side of
	# _focus_point (looking back at it), so the vector pointing away from
	# the camera into the screen -- "up"/"forward" panning -- is the
	# negation of the (yaw-only) direction the camera itself sits along.
	# right stays the old (unnegated) sin/cos pairing -- deliberately not
	# re-derived from the corrected forward, or left/right would flip too.
	var forward := Vector3(-sin(_yaw), 0.0, -cos(_yaw))
	var right := Vector3(cos(_yaw), 0.0, -sin(_yaw))
	var movement := (right * pan_direction.x + forward * pan_direction.y) * _PAN_SPEED * delta
	_focus_point = Vector3(
		clampf(_focus_point.x + movement.x, -_PAN_BOUND, _PAN_BOUND),
		0.0,
		clampf(_focus_point.z + movement.z, -_PAN_BOUND, _PAN_BOUND)
	)
	_update_transform()


## Arrows and their WASD alternates (Hotkeys.gd's camera_pan_*_alt
## actions) both drive the same direction -- either (or both held at
## once) pans.
func _key_pan_direction() -> Vector2:
	var direction := Vector2.ZERO
	if Input.is_action_pressed("camera_pan_up") or Input.is_action_pressed("camera_pan_up_alt"):
		direction.y += 1.0
	if Input.is_action_pressed("camera_pan_down") or Input.is_action_pressed("camera_pan_down_alt"):
		direction.y -= 1.0
	if Input.is_action_pressed("camera_pan_right") or Input.is_action_pressed("camera_pan_right_alt"):
		direction.x += 1.0
	if Input.is_action_pressed("camera_pan_left") or Input.is_action_pressed("camera_pan_left_alt"):
		direction.x -= 1.0
	return direction


func _edge_pan_direction() -> Vector2:
	var viewport := get_viewport()
	if viewport == null or not viewport.get_window() or not viewport.get_window().has_focus():
		return Vector2.ZERO

	var mouse := viewport.get_mouse_position()
	var size := viewport.get_visible_rect().size
	var direction := Vector2.ZERO
	if mouse.x <= _EDGE_PAN_MARGIN:
		direction.x -= 1.0
	elif mouse.x >= size.x - _EDGE_PAN_MARGIN:
		direction.x += 1.0
	if mouse.y <= _EDGE_PAN_MARGIN:
		direction.y += 1.0
	elif mouse.y >= size.y - _EDGE_PAN_MARGIN:
		direction.y -= 1.0
	return direction


## Centers the focus point on whichever of SelectionManager.local_player's
## units has stats.is_hero true -- a harmless no-op if they don't have one
## (or don't own one yet, e.g. before PLACEMENT). Only ever the first hero
## found; this project has never supported more than one hero per player.
func _jump_to_own_hero() -> void:
	for unit in GameManager.get_all_units():
		if unit.player == SelectionManager.local_player and unit.stats.is_hero:
			_focus_point = Vector3(unit.global_position.x, 0.0, unit.global_position.z)
			_update_transform()
			return


## Recenters the focus point and sets zoom distance in one call -- used by
## Main.gd to jump the camera onto a Blood Tournament round's actual
## clash point the instant marching starts (see
## Main._focus_camera_on_local_battle()). Default framing centers on the
## map origin at a distance tuned for the older, smaller square arena;
## against the cross map's larger reach (SPAWN_POINTS out near +-32) that
## left the actual fight a tiny cluster near the frame's edge. `distance`
## still gets clamped to the normal zoom bounds, so this can never leave
## the camera somewhere the player's own scroll wheel couldn't reach.
func focus_and_zoom(position: Vector3, distance: float) -> void:
	_focus_point = Vector3(position.x, 0.0, position.z)
	_distance = clampf(distance, _MIN_DISTANCE, _MAX_DISTANCE)
	_update_transform()


## Hero-ultimate juice -- GameManager.hero_ultimate_cast, wired up by
## Main.gd. `magnitude` in meters; decays linearly to 0 over `duration`
## seconds. A second call while one is still active just replaces it
## (no stacking) -- fine at this prototype's cast-cadence, real cooldowns
## keep ultimates from overlapping in practice anyway.
func shake(duration: float, magnitude: float) -> void:
	_shake_duration = duration
	_shake_time_remaining = duration
	_shake_magnitude = magnitude


func _current_shake_offset() -> Vector3:
	if _shake_time_remaining <= 0.0 or _shake_duration <= 0.0:
		return Vector3.ZERO
	var strength := _shake_magnitude * (_shake_time_remaining / _shake_duration)
	return Vector3(randf_range(-1.0, 1.0), randf_range(-1.0, 1.0), randf_range(-1.0, 1.0)) * strength


func _update_transform() -> void:
	var offset := Vector3(
		_distance * cos(_pitch) * sin(_yaw),
		_distance * sin(_pitch),
		_distance * cos(_pitch) * cos(_yaw)
	)
	global_position = _focus_point + offset
	look_at(_focus_point, Vector3.UP)
	global_position += _current_shake_offset() # after look_at -- perturbs position only, orientation stays aimed at the real focus point
