## Orbit camera: scroll to zoom, right-click-drag to orbit, arrow keys or
## edge-pan to move the focus point around the arena, Space to jump to
## your own hero. Self-contained -- Main.gd doesn't touch the camera at
## all, including for jump-to-hero (queries GameManager/SelectionManager
## directly, both autoloads).
extends Camera3D

## Arrow keys, not WASD -- W/A/S/D are already claimed by this project's
## own hotkeys (W = ability slot 1, S = Stop, see Main._handle_key()).
## Panning with W would also fire that ability once on the initial
## keydown (InputEventKey.echo only suppresses repeats, not the first
## press) -- arrow keys avoid the collision entirely, at the cost of not
## matching the "WASD" wording in the roadmap's original generic phrasing
## (written before this project had its own Q/W/E/S/H scheme).
const _ZOOM_STEP := 2.0
const _MIN_DISTANCE := 8.0
const _MAX_DISTANCE := 45.0
const _MIN_PITCH := deg_to_rad(15.0)
const _MAX_PITCH := deg_to_rad(85.0)
const _ORBIT_SENSITIVITY := 0.005
## Generous enough to cover the 8-team cross map's arms (Main.ARM_SPAWN_POINTS
## reach roughly +-30) without this camera needing to know which arena
## shape is active -- panning a little past the smaller square arena's
## edge into empty space is harmless.
const _PAN_BOUND := 36.0
const _PAN_SPEED := 24.0 ## Meters per second, arrow keys and edge-pan alike.
const _EDGE_PAN_MARGIN := 12.0 ## Pixels from the viewport edge that starts edge-pan.

var _distance := 25.6
var _yaw := 0.0
var _pitch := deg_to_rad(51.0) # matches the previous fixed position (0, 20, 16)
var _focus_point := Vector3.ZERO


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
## that would misdiagnose as an unrelated failure. Arrow-key panning
## doesn't need the same guard -- Input.is_key_pressed() correctly reads
## false with no real input device under headless.
func _process(delta: float) -> void:
	var pan_direction := _arrow_key_pan_direction()
	if DisplayServer.get_name() != "headless":
		pan_direction += _edge_pan_direction()
	if pan_direction == Vector2.ZERO:
		return

	pan_direction = pan_direction.normalized()
	var forward := Vector3(sin(_yaw), 0.0, cos(_yaw))
	var right := Vector3(forward.z, 0.0, -forward.x)
	var movement := (right * pan_direction.x + forward * pan_direction.y) * _PAN_SPEED * delta
	_focus_point = Vector3(
		clampf(_focus_point.x + movement.x, -_PAN_BOUND, _PAN_BOUND),
		0.0,
		clampf(_focus_point.z + movement.z, -_PAN_BOUND, _PAN_BOUND)
	)
	_update_transform()


func _arrow_key_pan_direction() -> Vector2:
	var direction := Vector2.ZERO
	if Input.is_action_pressed("camera_pan_up"):
		direction.y += 1.0
	if Input.is_action_pressed("camera_pan_down"):
		direction.y -= 1.0
	if Input.is_action_pressed("camera_pan_right"):
		direction.x += 1.0
	if Input.is_action_pressed("camera_pan_left"):
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


func _update_transform() -> void:
	var offset := Vector3(
		_distance * cos(_pitch) * sin(_yaw),
		_distance * sin(_pitch),
		_distance * cos(_pitch) * cos(_yaw)
	)
	global_position = _focus_point + offset
	look_at(_focus_point, Vector3.UP)
