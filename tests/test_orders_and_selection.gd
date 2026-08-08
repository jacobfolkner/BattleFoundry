## Tests for Unit's order system (order_move/order_attack_move/order_stop/
## order_hold/order_patrol/order_follow) and SelectionManager (single/
## drag-box/control-group selection, ownership enforcement).
##
## Every existing combat test spawns units and never issues an order at
## all, relying on the pre-orders default autonomous "seek and attack
## nearest enemy" behavior (current_order == null) -- that those still
## pass is the regression guarantee this system didn't change what
## happens when nobody gives an order. These tests cover what changes
## once one is given.
extends GutTest

const TANK_STATS: UnitStats = preload("res://Resources/TankStats.tres")
const FIGHTER_STATS: UnitStats = preload("res://Resources/FighterStats.tres")

var _main: Node3D
var _camera: Camera3D


func before_each() -> void:
	GameManager.reset_battle()
	SelectionManager.selected_units.clear()
	_main = load("res://Scenes/Main.tscn").instantiate()
	add_child_autofree(_main)
	_camera = _main.get_node("Camera3D")
	await wait_physics_frames(2)


## A far corner, off the path of anything these tests actually move
## along -- exists purely so GameManager.can_start_battle() (which
## requires both BLUE_TEAM_ID and RED_TEAM_ID to have a unit) is
## satisfied without the dummy ever factoring into an assertion. Given a
## STOP order immediately: left on default autonomous AI, it would
## eventually walk over and pick a fight of its own (it's the only
## hostile unit on the field, so it's always "nearest") -- fine for a
## short test, but the longer-running ones here have enough simulated
## time for a 2 m/s dummy to cross the ~24m gap and interfere for real.
func _spawn_irrelevant_red_dummy() -> void:
	var dummy := GameManager.spawn_unit(TANK_STATS, GameManager.get_player(GameManager.RED_TEAM_ID), Vector3(-19, 0, -19))
	dummy.order_stop()


# ---------------------------------------------------------------------
# Unit orders
# ---------------------------------------------------------------------

func test_order_move_relocates_and_never_attacks() -> void:
	var blue := GameManager.get_player(GameManager.BLUE_TEAM_ID)
	var red := GameManager.get_player(GameManager.RED_TEAM_ID)
	var tank := GameManager.spawn_unit(TANK_STATS, blue, Vector3.ZERO)
	var fighter := GameManager.spawn_unit(FIGHTER_STATS, red, Vector3(1, 0, 0)) # well within Tank's attack range
	GameManager.start_battle()

	tank.order_move(Vector3(10, 0, 0))

	for i in range(30):
		await wait_physics_frames(1)

	assert_eq(fighter.current_health, FIGHTER_STATS.max_health, "MOVE should never attack, even with an enemy adjacent")
	assert_gt(tank.global_position.x, 0.5, "the tank should have moved toward its order destination")


func test_order_move_clears_and_reverts_to_autonomous_on_arrival() -> void:
	var tank := GameManager.spawn_unit(TANK_STATS, GameManager.get_player(GameManager.BLUE_TEAM_ID), Vector3.ZERO)
	_spawn_irrelevant_red_dummy()
	GameManager.start_battle()

	tank.order_move(Vector3(1, 0, 0)) # short enough (Tank: 2 m/s) to arrive well within the frame budget below

	for i in range(90): # 1.5s
		await wait_physics_frames(1)

	assert_null(tank.current_order, "MOVE should clear itself and fall back to autonomous AI once the destination is reached")


func test_order_attack_move_fights_enemy_encountered_en_route() -> void:
	var tank := GameManager.spawn_unit(TANK_STATS, GameManager.get_player(GameManager.BLUE_TEAM_ID), Vector3.ZERO)
	var fighter := GameManager.spawn_unit(FIGHTER_STATS, GameManager.get_player(GameManager.RED_TEAM_ID), Vector3(1, 0, 0))
	GameManager.start_battle()

	tank.order_attack_move(Vector3(10, 0, 0)) # far past the fighter blocking the path

	for i in range(90): # comfortably covers Tank's 1.2s attack_interval
		await wait_physics_frames(1)

	assert_lt(fighter.current_health, FIGHTER_STATS.max_health, "ATTACK_MOVE should fight an enemy encountered en route")


## Regression test for a real bug (reported by a user manually testing
## the build, not caught by any test at the time): ATTACK_MOVE's
## "target not yet in range" branch used to call _seek_target(), chasing
## whatever GameManager.find_nearest_enemy() returned -- which has no
## distance cutoff, so it always returns *some* enemy if one exists
## anywhere on the field. Right-clicking to attack-move would silently
## hijack toward that enemy instead of the clicked point the instant any
## enemy existed at all, making attack-move indistinguishable from
## default autonomous behavior and the actual destination unreachable.
## Checks the *closest* approach to the destination reached at any point
## during the run, not the final position -- ATTACK_MOVE correctly clears
## itself and falls back to default autonomous AI once it arrives (same
## contract as MOVE), and that pre-existing autonomous AI has no
## acquisition-range cap of its own, so it's expected to head back off
## toward the distant enemy again afterward. What this test actually
## needs to prove is narrower: that the destination gets reached *at
## all*, which the bug this guards against broke entirely.
func test_order_attack_move_still_reaches_destination_past_a_distant_off_path_enemy() -> void:
	var tank := GameManager.spawn_unit(TANK_STATS, GameManager.get_player(GameManager.BLUE_TEAM_ID), Vector3.ZERO)
	GameManager.spawn_unit(TANK_STATS, GameManager.get_player(GameManager.RED_TEAM_ID), Vector3(-15, 0, 15)) # far away, off to the side
	GameManager.start_battle()

	var destination := Vector3(3, 0, 0)
	tank.order_attack_move(destination)

	var closest_distance := tank.global_position.distance_to(destination)
	for i in range(120): # 2s -- comfortably covers the ~1.5s trip at 2 m/s
		await wait_physics_frames(1)
		closest_distance = minf(closest_distance, tank.global_position.distance_to(destination))

	assert_lt(closest_distance, 1.0,
		"attack-move should reach its actual destination at some point, not chase a distant off-path enemy the whole way")


func test_order_stop_halts_attacking() -> void:
	var tank := GameManager.spawn_unit(TANK_STATS, GameManager.get_player(GameManager.BLUE_TEAM_ID), Vector3.ZERO)
	var fighter := GameManager.spawn_unit(FIGHTER_STATS, GameManager.get_player(GameManager.RED_TEAM_ID), Vector3(1, 0, 0))
	GameManager.start_battle()

	for i in range(90): # let them engage first
		await wait_physics_frames(1)
	var health_at_stop := fighter.current_health

	tank.order_stop()

	for i in range(90):
		await wait_physics_frames(1)

	assert_eq(fighter.current_health, health_at_stop, "STOP should halt attacking immediately")


## "Never moves to chase" means never *intentionally* seeks (desired_velocity
## stays zero -- checked at the end, once things have settled) -- it does
## NOT mean immune to being physically jostled by another unit's own
## avoidance steering as it closes in and attacks at melee range. That
## jostle is the same pre-existing avoidance behavior
## test_crowded_units_all_make_progress_not_just_the_front_one already
## exercises; asserting zero displacement here would fail on correct
## behavior, not catch a bug.
func test_order_hold_never_seeks_but_attacks_once_in_range() -> void:
	var tank := GameManager.spawn_unit(TANK_STATS, GameManager.get_player(GameManager.BLUE_TEAM_ID), Vector3.ZERO)
	var fighter := GameManager.spawn_unit(FIGHTER_STATS, GameManager.get_player(GameManager.RED_TEAM_ID), Vector3(4, 0, 0))
	tank.order_hold()
	GameManager.start_battle()

	for i in range(180): # 3s -- enough for the Fighter (4.5 m/s, autonomous) to close the gap
		await wait_physics_frames(1)

	assert_eq(tank.desired_velocity, Vector3.ZERO, "a Hold Position unit should never intentionally seek toward anything")
	assert_lt(fighter.current_health, FIGHTER_STATS.max_health,
		"Hold Position should still attack once something comes into range on its own")


func test_order_follow_keeps_pace_with_target_unit() -> void:
	var blue := GameManager.get_player(GameManager.BLUE_TEAM_ID)
	var leader := GameManager.spawn_unit(TANK_STATS, blue, Vector3.ZERO)
	var follower := GameManager.spawn_unit(FIGHTER_STATS, blue, Vector3(-3, 0, 0))
	_spawn_irrelevant_red_dummy()
	GameManager.start_battle()

	leader.order_move(Vector3(10, 0, 0))
	follower.order_follow(leader)

	for i in range(180): # 3s
		await wait_physics_frames(1)

	assert_lt(follower.global_position.distance_to(leader.global_position), 3.0,
		"a follower should keep pace with its leader instead of falling behind or standing still")


func test_order_follow_clears_when_target_unit_is_freed() -> void:
	var blue := GameManager.get_player(GameManager.BLUE_TEAM_ID)
	var leader := GameManager.spawn_unit(TANK_STATS, blue, Vector3(5, 0, 0))
	var follower := GameManager.spawn_unit(FIGHTER_STATS, blue, Vector3(-3, 0, 0))
	_spawn_irrelevant_red_dummy()
	GameManager.start_battle()

	follower.order_follow(leader)
	assert_not_null(follower.current_order)

	leader.queue_free()
	await wait_physics_frames(3) # let the free actually process, then one tick to notice

	assert_null(follower.current_order, "FOLLOW should clear itself once its target is no longer valid")


## Tracks the min/max X visited over a generous budget instead of
## pinning an exact position at an exact frame count -- avoidance
## introduces real, if small, per-transition settling (most visible right
## at spawn and at each waypoint turnaround) that makes exact frame-to-
## distance predictions fragile without actually indicating a logic bug
## (a raw, non-GUT physics loop running this same order confirms the
## direction/rate are correct; it just isn't perfectly linear). A wide
## visited range plus current_order still being PATROL (which, unlike
## MOVE, never clears itself) is what actually distinguishes "patrolling"
## from "stuck," without needing to predict exactly where it'll be when.
func test_order_patrol_bounces_between_two_points() -> void:
	var blue := GameManager.get_player(GameManager.BLUE_TEAM_ID)
	var origin := Vector3(-2, 0, 0)
	var far_point := Vector3(2, 0, 0)
	var tank := GameManager.spawn_unit(TANK_STATS, blue, origin)
	_spawn_irrelevant_red_dummy()
	GameManager.start_battle()

	tank.order_patrol(far_point)

	var min_x := tank.global_position.x
	var max_x := tank.global_position.x
	for i in range(600):
		await wait_physics_frames(1)
		min_x = minf(min_x, tank.global_position.x)
		max_x = maxf(max_x, tank.global_position.x)

	assert_gt(max_x - min_x, 2.0, "patrol should visibly travel back and forth between its two waypoints, not sit still")
	assert_not_null(tank.current_order)
	if tank.current_order != null:
		assert_eq(tank.current_order.type, Unit.OrderType.PATROL, "a PATROL order should never clear itself the way MOVE does")


func test_queued_order_runs_after_current_completes() -> void:
	var tank := GameManager.spawn_unit(TANK_STATS, GameManager.get_player(GameManager.BLUE_TEAM_ID), Vector3.ZERO)
	_spawn_irrelevant_red_dummy()
	GameManager.start_battle()

	# point_a is trivially close (completes almost immediately regardless
	# of exact timing); point_b is far enough that no plausible frame
	# budget below finishes it too -- keeps this test from depending on
	# a precise frames-to-simulated-seconds ratio.
	var point_a := Vector3(0.2, 0, 0)
	var point_b := Vector3(100, 0, 0)
	tank.order_move(point_a)
	tank.order_move(point_b, true) # shift-queued

	for i in range(120):
		await wait_physics_frames(1)

	assert_not_null(tank.current_order, "the queued MOVE to point_b should have taken over")
	if tank.current_order != null:
		assert_eq(tank.current_order.target_position, point_b)


# ---------------------------------------------------------------------
# Default autonomous AI (current_order == null) -- acquisition_range
# ---------------------------------------------------------------------

## The "known rough edge" this project shipped with from the start:
## GameManager.find_nearest_enemy() had no distance cutoff, so an idle
## unit would immediately start walking toward -- and never give up on --
## whatever enemy existed anywhere on the field, however far away. See
## UnitStats.acquisition_range/Unit._update_target().
func test_idle_unit_does_not_chase_an_enemy_beyond_acquisition_range() -> void:
	var tank := GameManager.spawn_unit(TANK_STATS, GameManager.get_player(GameManager.BLUE_TEAM_ID), Vector3.ZERO)
	GameManager.spawn_unit(FIGHTER_STATS, GameManager.get_player(GameManager.RED_TEAM_ID), Vector3(TANK_STATS.acquisition_range + 5.0, 0, 0))
	GameManager.start_battle()

	for i in range(30):
		await wait_physics_frames(1)

	assert_null(tank.target_enemy, "an enemy beyond acquisition_range should never be auto-targeted")
	assert_almost_eq(tank.global_position.distance_to(Vector3.ZERO), 0.0, 0.1,
		"an idle unit with nothing within acquisition_range should not wander at all")


func test_an_already_engaged_unit_gives_up_once_its_target_drifts_beyond_acquisition_range() -> void:
	var tank := GameManager.spawn_unit(TANK_STATS, GameManager.get_player(GameManager.BLUE_TEAM_ID), Vector3.ZERO)
	var fighter := GameManager.spawn_unit(FIGHTER_STATS, GameManager.get_player(GameManager.RED_TEAM_ID), Vector3(2, 0, 0))
	GameManager.start_battle()
	await wait_physics_frames(2) # let the tank auto-acquire the fighter as target_enemy

	assert_eq(tank.target_enemy, fighter)

	fighter.global_position = Vector3(TANK_STATS.acquisition_range + 10.0, 0, 0) # simulate having drifted far away
	await wait_physics_frames(2)

	assert_null(tank.target_enemy, "a target that drifts beyond acquisition_range should be given up on, not chased forever")


# ---------------------------------------------------------------------
# SelectionManager
# ---------------------------------------------------------------------

func test_select_single_ignores_enemy_unit() -> void:
	var enemy := GameManager.spawn_unit(TANK_STATS, GameManager.get_player(GameManager.RED_TEAM_ID), Vector3.ZERO)

	SelectionManager.select_single(enemy)

	assert_true(SelectionManager.selected_units.is_empty(), "ownership enforcement should reject selecting an enemy unit")


func test_select_single_shift_click_toggles_off() -> void:
	var tank := GameManager.spawn_unit(TANK_STATS, GameManager.get_player(GameManager.BLUE_TEAM_ID), Vector3.ZERO)

	SelectionManager.select_single(tank)
	assert_true(SelectionManager.selected_units.has(tank))

	SelectionManager.select_single(tank, true) # shift-clicking an already-selected unit
	assert_false(SelectionManager.selected_units.has(tank), "shift-clicking a selected unit should deselect it")


func test_selection_indicator_ring_follows_the_selection() -> void:
	var tank := GameManager.spawn_unit(TANK_STATS, GameManager.get_player(GameManager.BLUE_TEAM_ID), Vector3.ZERO)

	SelectionManager.select_single(tank)
	await wait_physics_frames(1) # _process() is what actually syncs the indicator pool

	assert_eq(_visible_indicator_count(), 1, "one selected unit should show exactly one indicator ring")

	SelectionManager.clear_selection()
	await wait_physics_frames(1)

	assert_eq(_visible_indicator_count(), 0, "clearing the selection should hide its indicator ring")


func _visible_indicator_count() -> int:
	var count := 0
	for indicator in SelectionManager._indicator_pool:
		if indicator.visible:
			count += 1
	return count


func test_select_in_rect_selects_owned_units_and_excludes_enemies() -> void:
	var ally := GameManager.spawn_unit(TANK_STATS, GameManager.get_player(GameManager.BLUE_TEAM_ID), Vector3(-1, 0, 0))
	var enemy := GameManager.spawn_unit(TANK_STATS, GameManager.get_player(GameManager.RED_TEAM_ID), Vector3(1, 0, 0))
	await wait_physics_frames(2)

	# A rect spanning both units' projected screen positions -- proves
	# the enemy is excluded by ownership, not by missing the drag box.
	var ally_screen := _camera.unproject_position(ally.global_position)
	var enemy_screen := _camera.unproject_position(enemy.global_position)
	var rect := Rect2(ally_screen, Vector2.ZERO).expand(enemy_screen).grow(20)

	SelectionManager.select_in_rect(_camera, rect)

	assert_true(SelectionManager.selected_units.has(ally))
	assert_false(SelectionManager.selected_units.has(enemy), "drag-box selection must not pick up enemy units")


func test_control_group_assign_and_recall() -> void:
	var tank := GameManager.spawn_unit(TANK_STATS, GameManager.get_player(GameManager.BLUE_TEAM_ID), Vector3.ZERO)
	SelectionManager.select_single(tank)
	SelectionManager.assign_control_group(1)
	SelectionManager.clear_selection()
	assert_true(SelectionManager.selected_units.is_empty())

	SelectionManager.select_control_group(1)

	assert_eq(SelectionManager.selected_units, [tank])


func test_order_methods_ignore_units_not_owned_by_local_player() -> void:
	var enemy := GameManager.spawn_unit(TANK_STATS, GameManager.get_player(GameManager.RED_TEAM_ID), Vector3.ZERO)
	SelectionManager.selected_units.append(enemy) # bypasses select_single()'s own ownership filter directly

	SelectionManager.order_move(Vector3(10, 0, 0))

	assert_null(enemy.current_order,
		"order_*() methods must enforce ownership themselves, not just rely on selection having filtered already")


## Full path from the Q hotkey (SelectionManager.cast_ability(), what
## Main._handle_key() calls) rather than calling Unit.cast_ability()
## directly -- validates the selection -> ability wiring itself, same
## reasoning as test_archer_attack_spawns_a_projectile_instead_of_instant_damage
## going through the real AI loop instead of a manual construction.
## Tank's War Stomp (see test_effects_and_abilities.gd for the full
## Effect/Ability framework tests) is a NO_TARGET AoE stun, so this only
## needs a selected caster and a nearby enemy, not a pre-existing target.
func test_cast_ability_via_selection_manager_hits_selected_units_targets() -> void:
	var tank := GameManager.spawn_unit(TANK_STATS, GameManager.get_player(GameManager.BLUE_TEAM_ID), Vector3.ZERO)
	var nearby_enemy := GameManager.spawn_unit(FIGHTER_STATS, GameManager.get_player(GameManager.RED_TEAM_ID), Vector3(2, 0, 0))
	SelectionManager.select_single(tank)

	SelectionManager.cast_ability(0) # War Stomp

	assert_true(nearby_enemy.is_stunned(), "casting War Stomp through SelectionManager should stun the nearby enemy")
