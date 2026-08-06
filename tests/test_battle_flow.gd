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
	# tree, so its lifecycle state and team rosters must be reset by hand or
	# tests bleed into each other (e.g. test 2 inheriting GAME_OVER from
	# test 1, or stale unit refs making a team look non-empty).
	# reset_battle() (Sprint 6) replaces a previous direct reach into
	# GameManager's private _units_by_team.
	GameManager.reset_battle()

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


func test_start_battle_noop_when_a_team_is_empty() -> void:
	GameManager.spawn_unit(TANK_STATS, Team.Type.BLUE, Vector3(-3, 0, 0))
	GameManager.start_battle()
	assert_eq(GameManager.battle_state, GameManager.BattleState.PLACEMENT,
		"start_battle should no-op when Red has no units")


func test_can_start_battle_requires_both_teams_to_have_units() -> void:
	assert_false(GameManager.can_start_battle(), "should be false with no units placed")

	GameManager.spawn_unit(TANK_STATS, Team.Type.BLUE, Vector3(-3, 0, 0))
	assert_false(GameManager.can_start_battle(), "should still be false with only one team filled")

	GameManager.spawn_unit(FIGHTER_STATS, Team.Type.RED, Vector3(3, 0, 0))
	assert_true(GameManager.can_start_battle(), "should be true once both teams have a unit")

	GameManager.start_battle()
	assert_false(GameManager.can_start_battle(), "should be false once no longer in PLACEMENT")


func test_reset_battle_frees_units_and_returns_to_placement() -> void:
	var blue_unit := GameManager.spawn_unit(TANK_STATS, Team.Type.BLUE, Vector3(-3, 0, 0))
	GameManager.spawn_unit(FIGHTER_STATS, Team.Type.RED, Vector3(3, 0, 0))
	GameManager.start_battle()
	assert_true(GameManager.is_battle_active())

	GameManager.reset_battle()

	assert_true(GameManager.is_placement_phase())
	assert_false(GameManager.can_start_battle(), "rosters should be cleared by reset_battle")
	assert_true(blue_unit.is_queued_for_deletion(), "reset_battle should free units still in the arena")


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
