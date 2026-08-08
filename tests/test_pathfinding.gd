## Proves Unit actually paths against a baked NavigationMesh now (see
## Unit._seek_position()'s doc comment) instead of just feeding avoidance
## a straight-line direction to the target -- a real static wall, with
## real physics collision, sits directly between the unit and its
## destination. If pathfinding weren't real, the unit would either walk
## straight through the wall's x range (if collision didn't stop it) or
## get stuck at the wall face (if it did); routing around means it must
## swing out well past the wall's end at some point during the trip.
##
## Built in its own isolated scene/NavigationRegion3D rather than added
## to Scenes/Main.tscn's shared arena -- Main.tscn stays a single open
## rectangle deliberately (see Main._build_navigation()'s doc comment),
## since a shared obstacle there would sit in the footsteps of the ~89
## other tests that spawn/path units anywhere in the open 40x40 plane.
extends GutTest

const TANK_STATS: UnitStats = preload("res://Resources/Units/TankStats.tres")

## Half the wall's width -- spans x=[-_WALL_HALF_WIDTH, _WALL_HALF_WIDTH]
## at z=0. Kept small (not the whole 40m arena) so the routed-around trip
## stays short enough for a reasonably fast test.
const _WALL_HALF_WIDTH := 4.0

var _arena: Node3D


func before_each() -> void:
	GameManager.reset_battle()
	_arena = Node3D.new()
	add_child_autofree(_arena)

	var units_container := Node3D.new()
	_arena.add_child(units_container)
	GameManager.units_container = units_container

	_build_navigation_with_wall()
	await wait_physics_frames(2)


## Ground (a flat box -- baking source for the walkable surface) and a
## solid wall (StaticBody3D so it's also a real physics obstacle, not
## just a navmesh hole) both parented under the NavigationRegion3D, which
## is the default source-geometry scope bake_navigation_mesh() uses.
func _build_navigation_with_wall() -> void:
	var region := NavigationRegion3D.new()
	var nav_mesh := NavigationMesh.new()
	nav_mesh.agent_radius = TANK_STATS.collision_radius
	nav_mesh.agent_height = 2.0
	nav_mesh.agent_max_slope = 45.0
	nav_mesh.cell_size = 0.25
	nav_mesh.cell_height = 0.25
	region.navigation_mesh = nav_mesh
	_arena.add_child(region)

	var ground := MeshInstance3D.new()
	var ground_mesh := BoxMesh.new()
	ground_mesh.size = Vector3(40, 0.1, 40)
	ground.mesh = ground_mesh
	ground.position = Vector3(0, -0.05, 0)
	region.add_child(ground)

	var wall_body := StaticBody3D.new()
	var wall_box := BoxMesh.new()
	wall_box.size = Vector3(_WALL_HALF_WIDTH * 2.0, 3.0, 1.0)
	var wall_mesh := MeshInstance3D.new()
	wall_mesh.mesh = wall_box
	wall_body.add_child(wall_mesh)
	var wall_shape := CollisionShape3D.new()
	var box_shape := BoxShape3D.new()
	box_shape.size = wall_box.size
	wall_shape.shape = box_shape
	wall_body.add_child(wall_shape)
	wall_body.position = Vector3(0, 1.5, 0)
	region.add_child(wall_body)

	region.bake_navigation_mesh(false) # synchronous -- needs to be ready before physics starts


func test_unit_routes_around_a_wall_instead_of_walking_through_it() -> void:
	var start := Vector3(0, 0, -3)
	var destination := Vector3(0, 0, 3)
	var tank := GameManager.spawn_unit(TANK_STATS, GameManager.get_player(GameManager.BLUE_TEAM_ID), start)
	# Order-processing (and everything else in _physics_process gated on
	# is_battling) only runs during BATTLE -- can_start_battle() also
	# requires both teams to have a unit, hence the far-off, inert dummy.
	var dummy := GameManager.spawn_unit(TANK_STATS, GameManager.get_player(GameManager.RED_TEAM_ID), Vector3(-19, 0, -19))
	dummy.order_stop()
	GameManager.start_battle()

	tank.order_move(destination) # straight through the wall's center, if nothing routed around it

	var max_abs_x := 0.0
	for i in range(700):
		await wait_physics_frames(1)
		max_abs_x = maxf(max_abs_x, absf(tank.global_position.x))

	assert_gt(max_abs_x, _WALL_HALF_WIDTH - 0.5,
		"routing around the wall means swinging out near/past its end at some point, not staying near x=0 the whole trip")
	assert_almost_eq(tank.global_position.z, destination.z, 1.0,
		"the unit should have actually reached the far side, not gotten stuck at the wall face")
