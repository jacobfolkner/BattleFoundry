## Root controller for the prototype scene.
##
## Owns the arena, points the camera at it, wires the HUD to unit
## placement, and turns mouse clicks into spawned units while
## GameManager is in the PLACEMENT phase.
extends Node3D

const GROUND_PLANE := Plane(Vector3.UP, 0.0)

@onready var _camera: Camera3D = $Camera3D
@onready var _units_container: Node3D = $UnitsContainer
@onready var _hud: Control = $HUDLayer/HUD

var _selected_stats: UnitStats
var _selected_team: Team.Type = Team.Type.BLUE


func _ready() -> void:
	_camera.look_at(Vector3.ZERO, Vector3.UP)

	GameManager.units_container = _units_container
	GameManager.battle_ended.connect(_hud.show_winner)

	_hud.unit_type_selected.connect(_on_unit_type_selected)
	_hud.team_selected.connect(_on_team_selected)
	_hud.start_battle_pressed.connect(GameManager.start_battle)


func _unhandled_input(event: InputEvent) -> void:
	if GameManager.battle_state != GameManager.BattleState.PLACEMENT:
		return
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		_try_place_unit(event.position)


func _try_place_unit(screen_position: Vector2) -> void:
	if _selected_stats == null:
		return

	var ray_origin := _camera.project_ray_origin(screen_position)
	var ray_direction := _camera.project_ray_normal(screen_position)
	var hit_position = GROUND_PLANE.intersects_ray(ray_origin, ray_direction)
	if hit_position == null:
		return

	GameManager.spawn_unit(_selected_stats, _selected_team, hit_position)


func _on_unit_type_selected(stats: UnitStats) -> void:
	_selected_stats = stats


func _on_team_selected(team: Team.Type) -> void:
	_selected_team = team
