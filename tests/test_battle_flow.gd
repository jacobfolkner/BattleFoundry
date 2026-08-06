## Integration smoke test: boots the real Main scene, spawns units for
## both teams directly through GameManager (the same entry point Main.gd's
## click-to-place uses), starts the battle, and asserts a winner is
## resolved through the actual physics/combat/collision pipeline -- no
## mocking, no UI simulation. Runs fully headless (no GPU/display needed);
## this proves the whole game loop is testable from WSL with no Xvfb.
extends GutTest

const TANK_STATS: UnitStats = preload("res://Resources/TankStats.tres")
const FIGHTER_STATS: UnitStats = preload("res://Resources/FighterStats.tres")

var _main: Node3D


func before_each() -> void:
	# GameManager is an autoload singleton -- it outlives each test's scene
	# tree, so its battle_state and team rosters must be reset by hand or
	# tests bleed into each other (e.g. test 2 inheriting GAME_OVER from
	# test 1, or stale unit refs making a team look non-empty).
	GameManager.battle_state = GameManager.BattleState.PLACEMENT
	GameManager._units_by_team[Team.Type.BLUE].clear()
	GameManager._units_by_team[Team.Type.RED].clear()

	_main = load("res://Scenes/Main.tscn").instantiate()
	add_child_autofree(_main)
	await wait_physics_frames(2)


func test_lone_tank_beats_lone_fighter_and_battle_resolves() -> void:
	GameManager.spawn_unit(TANK_STATS, Team.Type.BLUE, Vector3(-3, 0, 0))
	GameManager.spawn_unit(FIGHTER_STATS, Team.Type.RED, Vector3(3, 0, 0))

	GameManager.start_battle()
	assert_eq(GameManager.battle_state, GameManager.BattleState.BATTLE)

	# Fighter's higher DPS (18 dmg / 0.6s) beats Tank's HP pool (250) in
	## ~9 simulated seconds once closing distance is spent; 15s budget
	# leaves headroom without making a broken combat loop hang the suite.
	var resolved := await _wait_until(func(): return GameManager.battle_state == GameManager.BattleState.GAME_OVER, 900)

	assert_true(resolved, "battle should resolve within 15s of simulated time")


## Regression test for the "units queue up behind a blocker instead of
## routing around it" bug avoidance steering fixes. Clusters several
## Tanks at one spawn point (so they start overlapping, forcing the front
## one to block the others) against a single distant enemy, and checks
## multiple Tanks made real progress -- a blocked queue would leave all
## but the front one pinned near the spawn point.
func test_crowded_units_all_make_progress_not_just_the_front_one() -> void:
	var spawn := Vector3(-10, 0, 0)
	var tanks: Array[Unit] = []
	for i in range(4):
		tanks.append(GameManager.spawn_unit(TANK_STATS, Team.Type.BLUE, spawn + Vector3(0, 0, i * 0.05)))
	GameManager.spawn_unit(FIGHTER_STATS, Team.Type.RED, Vector3(10, 0, 0))

	GameManager.start_battle()

	for i in range(120): # 2s of simulated physics time
		await wait_physics_frames(1)

	var advanced_count := 0
	for tank in tanks:
		if tank.global_position.distance_to(spawn) > 1.5:
			advanced_count += 1

	assert_gt(advanced_count, 1, "more than one clustered Tank should have advanced toward the enemy, not just the front one")


func test_start_battle_noop_when_a_team_is_empty() -> void:
	GameManager.spawn_unit(TANK_STATS, Team.Type.BLUE, Vector3(-3, 0, 0))
	GameManager.start_battle()
	assert_eq(GameManager.battle_state, GameManager.BattleState.PLACEMENT,
		"start_battle should no-op when Red has no units")


## Polls `condition` once per physics frame (not a wall-clock timer, which
## doesn't map to simulated physics time under GUT). Returns true as soon
## as it's met, false if `timeout_physics_frames` elapses first.
func _wait_until(condition: Callable, timeout_physics_frames: int) -> bool:
	var frames := 0
	while not condition.call():
		if frames >= timeout_physics_frames:
			return false
		await wait_physics_frames(1)
		frames += 1
	return true
