## Tests for the GameMode extraction (D3): GameManager delegating victory
## conditions to GameManager.current_mode instead of hardcoding
## elimination itself (see Scripts/GameMode.gd, Scripts/ClassicEliminationMode.gd),
## and the first real mode built on top of it, BloodTournamentMode
## (Scripts/BloodTournamentMode.gd) -- best-of-N rounds with the arena
## auto-resetting between them.
extends GutTest

const TANK_STATS: UnitStats = preload("res://Resources/Units/TankStats.tres")
const FIGHTER_STATS: UnitStats = preload("res://Resources/Units/FighterStats.tres")

var _main: Node3D


func before_each() -> void:
	GameManager.reset_battle()
	GameManager.current_mode = ClassicEliminationMode.new() # GameManager is an autoload -- don't let a mode set by an earlier test leak into this one
	# Player is a plain RefCounted that outlives each test the same way --
	# an earlier test (test_ai_opponent.gd's, most likely) could leave
	# Red's is_human false, which would make _main._on_tournament_toggled(true)
	# below silently have the AI spawn bonus Red units on top of whatever
	# a test spawns itself.
	GameManager.get_player(GameManager.RED_TEAM_ID).is_human = true
	_main = load("res://Scenes/Main.tscn").instantiate()
	add_child_autofree(_main)
	await wait_physics_frames(2)


func test_default_mode_is_classic_elimination() -> void:
	assert_true(GameManager.current_mode is ClassicEliminationMode)


func test_set_mode_resets_to_placement() -> void:
	GameManager.spawn_unit(TANK_STATS, GameManager.get_player(GameManager.BLUE_TEAM_ID), Vector3(-3, 0, 0))
	GameManager.spawn_unit(FIGHTER_STATS, GameManager.get_player(GameManager.RED_TEAM_ID), Vector3(3, 0, 0))
	GameManager.start_battle()
	assert_true(GameManager.is_battle_active())

	GameManager.set_mode(BloodTournamentMode.new())

	assert_true(GameManager.is_placement_phase(), "set_mode should reset to PLACEMENT")
	assert_false(GameManager.can_start_battle(), "rosters should be cleared by the reset")


func test_blood_tournament_tracks_round_wins_and_emits_round_ended() -> void:
	var mode := BloodTournamentMode.new()
	GameManager.set_mode(mode)
	watch_signals(mode)

	var blue := GameManager.get_player(GameManager.BLUE_TEAM_ID)
	var red := GameManager.get_player(GameManager.RED_TEAM_ID)
	GameManager.spawn_unit(TANK_STATS, blue, Vector3(-3, 0, 0))
	var loser := GameManager.spawn_unit(FIGHTER_STATS, red, Vector3(3, 0, 0))
	GameManager.start_battle()

	loser.take_damage(DamageInstance.new(loser.stat_block.max_health() + 100.0))

	assert_eq(mode.round_number, 1)
	assert_eq(mode.get_wins(GameManager.BLUE_TEAM_ID), 1)
	assert_eq(mode.get_wins(GameManager.RED_TEAM_ID), 0)
	assert_signal_emitted_with_parameters(mode, "round_ended", [1, GameManager.BLUE_TEAM_ID, false])


func test_blood_tournament_match_ends_after_reaching_rounds_to_win() -> void:
	var mode := BloodTournamentMode.new(2)
	GameManager.set_mode(mode)
	watch_signals(mode)

	var blue := GameManager.get_player(GameManager.BLUE_TEAM_ID)
	var red := GameManager.get_player(GameManager.RED_TEAM_ID)

	GameManager.spawn_unit(TANK_STATS, blue, Vector3(-3, 0, 0))
	var loser1 := GameManager.spawn_unit(FIGHTER_STATS, red, Vector3(3, 0, 0))
	GameManager.start_battle()
	loser1.take_damage(DamageInstance.new(loser1.stat_block.max_health() + 100.0))
	assert_false(mode.is_match_over(), "one round shouldn't decide a best-of-2")

	GameManager.reset_battle()

	GameManager.spawn_unit(TANK_STATS, blue, Vector3(-3, 0, 0))
	var loser2 := GameManager.spawn_unit(FIGHTER_STATS, red, Vector3(3, 0, 0))
	GameManager.start_battle()
	loser2.take_damage(DamageInstance.new(loser2.stat_block.max_health() + 100.0))

	assert_true(mode.is_match_over(), "the same team winning twice should decide a best-of-2")
	assert_signal_emitted_with_parameters(mode, "match_ended", [GameManager.BLUE_TEAM_ID])


func test_blood_tournament_draw_increments_round_but_not_wins() -> void:
	var mode := BloodTournamentMode.new()

	mode.on_battle_ended(GameManager.BLUE_TEAM_ID, true) # simulate a draw directly -- easier than forcing a real stalemate timeout

	assert_eq(mode.round_number, 1)
	assert_eq(mode.get_wins(GameManager.BLUE_TEAM_ID), 0)
	assert_eq(mode.get_wins(GameManager.RED_TEAM_ID), 0)


## Integration: goes through Main._on_tournament_toggled() (what HUD's
## Blood Tournament button actually calls), not a hand-built
## BloodTournamentMode + GameManager.set_mode() pair, so this also
## proves the deferred auto-reset (_advance_to_next_round(), deferred to
## avoid a same-frame signal-ordering hazard with GameManager.battle_ended
## -- see its doc comment) actually fires.
func test_main_auto_advances_to_next_round_after_a_win() -> void:
	_main._on_tournament_toggled(true)

	var blue := GameManager.get_player(GameManager.BLUE_TEAM_ID)
	var red := GameManager.get_player(GameManager.RED_TEAM_ID)
	GameManager.spawn_unit(TANK_STATS, blue, Vector3(-3, 0, 0))
	var loser := GameManager.spawn_unit(FIGHTER_STATS, red, Vector3(3, 0, 0))
	GameManager.start_battle()

	loser.take_damage(DamageInstance.new(loser.stat_block.max_health() + 100.0))
	assert_true(GameManager.is_game_over(), "sanity check: the round should have ended")

	await wait_physics_frames(2) # let the deferred _advance_to_next_round() run

	assert_true(GameManager.is_placement_phase(), "Main.gd should auto-reset for the next round")


## Slice 1 of the roadmap's Blood Tournament persistence work: the winning
## team's still-alive unit should carry over into the next round's
## PLACEMENT instead of being freed like a normal reset_battle() call would.
func test_reset_battle_preserves_units_still_alive_when_told_to() -> void:
	var blue := GameManager.get_player(GameManager.BLUE_TEAM_ID)
	var red := GameManager.get_player(GameManager.RED_TEAM_ID)
	var survivor := GameManager.spawn_unit(TANK_STATS, blue, Vector3(-3, 0, 0))
	var other_survivor := GameManager.spawn_unit(FIGHTER_STATS, red, Vector3(3, 0, 0))

	GameManager.reset_battle(true)

	assert_true(is_instance_valid(survivor) and not survivor.is_queued_for_deletion())
	assert_true(is_instance_valid(other_survivor) and not other_survivor.is_queued_for_deletion())
	assert_true(GameManager.is_placement_phase())
	assert_true(GameManager.can_start_battle(), "both rosters should already be non-empty from the carried-over units")


## Regression guard: the default reset_battle() (no arg) must keep freeing
## everyone even when units are still alive, exactly like before this
## feature -- only an explicit reset_battle(true) call opts into carryover.
func test_reset_battle_default_still_frees_living_units() -> void:
	var blue := GameManager.get_player(GameManager.BLUE_TEAM_ID)
	var unit := GameManager.spawn_unit(TANK_STATS, blue, Vector3(-3, 0, 0))

	GameManager.reset_battle()

	assert_true(unit.is_queued_for_deletion())
	assert_false(GameManager.can_start_battle())


## Dead units (permadeath) must never carry over, even mid-decay -- only
## Unit.LifeState.ALIVE counts as a survivor.
func test_reset_battle_preserve_does_not_carry_over_dead_units() -> void:
	var blue := GameManager.get_player(GameManager.BLUE_TEAM_ID)
	var red := GameManager.get_player(GameManager.RED_TEAM_ID)
	var survivor := GameManager.spawn_unit(TANK_STATS, blue, Vector3(-3, 0, 0))
	var loser := GameManager.spawn_unit(FIGHTER_STATS, red, Vector3(3, 0, 0))
	GameManager.start_battle()
	loser.take_damage(DamageInstance.new(loser.stat_block.max_health() + 100.0))

	GameManager.reset_battle(true)

	assert_true(is_instance_valid(survivor) and not survivor.is_queued_for_deletion())
	assert_true(loser.is_queued_for_deletion(), "a dead unit's corpse should still be freed by a preserving reset")


## Full integration through Main.gd's actual round-advance path (not a
## direct GameManager.reset_battle(true) call), proving
## _advance_to_next_round() passes true and the loser's now-empty roster
## requires a fresh placement while the winner's survivor is already there.
func test_blood_tournament_round_transition_preserves_the_winning_teams_survivor() -> void:
	_main._on_tournament_toggled(true)

	var blue := GameManager.get_player(GameManager.BLUE_TEAM_ID)
	var red := GameManager.get_player(GameManager.RED_TEAM_ID)
	var survivor := GameManager.spawn_unit(TANK_STATS, blue, Vector3(-3, 0, 0))
	var loser := GameManager.spawn_unit(FIGHTER_STATS, red, Vector3(3, 0, 0))
	GameManager.start_battle()

	loser.take_damage(DamageInstance.new(loser.stat_block.max_health() + 100.0))
	await wait_physics_frames(2) # let the deferred _advance_to_next_round() run

	assert_true(is_instance_valid(survivor) and not survivor.is_queued_for_deletion(), "Blue's surviving Tank should carry into round 2")
	assert_false(is_instance_valid(loser), "Red's dead Fighter should not carry over -- it should already be freed")
	assert_false(GameManager.can_start_battle(), "Red's roster is empty until a new unit is placed for it")


## A surviving unit sitting in PLACEMENT can be picked up and moved by a
## left-click-drag on it (see Main._try_start_unit_drag()/_drag_unit_to()),
## rather than only ever being able to place a brand-new unit.
func test_owned_unit_can_be_repositioned_via_drag_during_placement() -> void:
	var blue := GameManager.get_player(GameManager.BLUE_TEAM_ID)
	var survivor := GameManager.spawn_unit(TANK_STATS, blue, Vector3(-3, 0, 0))
	await wait_physics_frames(1) # let the physics server register the new collision shape before raycasting it
	var camera: Camera3D = _main.get_node("Camera3D")

	_main._try_start_unit_drag(camera.unproject_position(survivor.global_position))
	assert_eq(_main._dragging_unit, survivor, "clicking an owned unit during PLACEMENT should start dragging it")

	var destination := Vector3(6, survivor.global_position.y, -4)
	_main._drag_unit_to(camera.unproject_position(destination))

	assert_almost_eq(survivor.global_position.x, destination.x, 0.05)
	assert_almost_eq(survivor.global_position.z, destination.z, 0.05)


## Ownership-gated: dragging must not let a player pick up the opposing
## team's unit, same as placement/orders elsewhere.
func test_drag_does_not_pick_up_an_enemy_unit() -> void:
	var red := GameManager.get_player(GameManager.RED_TEAM_ID)
	var enemy := GameManager.spawn_unit(FIGHTER_STATS, red, Vector3(3, 0, 0))
	await wait_physics_frames(1)
	var camera: Camera3D = _main.get_node("Camera3D")

	_main._try_start_unit_drag(camera.unproject_position(enemy.global_position))

	assert_null(_main._dragging_unit, "the default placement side (Blue) must not be able to drag Red's unit")


## Dragging is a PLACEMENT-only interaction -- once BATTLE starts,
## left-click is drag-box selection instead (see _handle_mouse_motion()).
func test_drag_is_disabled_outside_placement_phase() -> void:
	var blue := GameManager.get_player(GameManager.BLUE_TEAM_ID)
	var red := GameManager.get_player(GameManager.RED_TEAM_ID)
	var unit := GameManager.spawn_unit(TANK_STATS, blue, Vector3(-3, 0, 0))
	GameManager.spawn_unit(FIGHTER_STATS, red, Vector3(3, 0, 0))
	GameManager.start_battle()
	await wait_physics_frames(1)
	var camera: Camera3D = _main.get_node("Camera3D")

	_main._try_start_unit_drag(camera.unproject_position(unit.global_position))

	assert_null(_main._dragging_unit)
