## Orbit camera: scroll to zoom, right-click-drag to orbit around a fixed
## target. Self-contained -- Main.gd no longer touches the camera at all.
extends Camera3D

const _TARGET := Vector3.ZERO
const _ZOOM_STEP := 2.0
const _MIN_DISTANCE := 8.0
const _MAX_DISTANCE := 45.0
const _MIN_PITCH := deg_to_rad(15.0)
const _MAX_PITCH := deg_to_rad(85.0)
const _ORBIT_SENSITIVITY := 0.005

var _distance := 25.6
var _yaw := 0.0
var _pitch := deg_to_rad(51.0) # matches the previous fixed position (0, 20, 16)


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


func _update_transform() -> void:
	var offset := Vector3(
		_distance * cos(_pitch) * sin(_yaw),
		_distance * sin(_pitch),
		_distance * cos(_pitch) * cos(_yaw)
	)
	global_position = _TARGET + offset
	look_at(_TARGET, Vector3.UP)
