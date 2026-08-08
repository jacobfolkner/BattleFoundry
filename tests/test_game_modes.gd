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
	# a test spawns itself. Roster/gold need the same reset -- an earlier
	# Blood Tournament test in this file leaves them non-zero otherwise.
	var blue := GameManager.get_player(GameManager.BLUE_TEAM_ID)
	var red := GameManager.get_player(GameManager.RED_TEAM_ID)
	blue.resources = 0
	red.resources = 0
	blue.blood_points = 0
	red.blood_points = 0
	blue.roster.clear()
	red.roster.clear()
	blue.roster_upgrades.clear()
	red.roster_upgrades.clear()
	red.is_human = true
	_main = load("res://Scenes/Main.tscn").instantiate()
	add_child_autofree(_main)
	await wait_physics_frames(2)


## Kills every currently-live unit belonging to `team_id` -- squad-sized
## roster slots (UnitStats.squad_size, e.g. Fighter's 5 or Tank's 3) mean
## a single kill rarely eliminates a whole team, so round-end tests need
## to clear the entire squad, not just one member of it.
func _kill_team(team_id: int) -> void:
	for unit in GameManager.get_all_units():
		if unit.player.team_id == team_id:
			unit.take_damage(DamageInstance.new(unit.stat_block.max_health() + 1000.0))


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
	blue.roster = [TANK_STATS]
	red.roster = [FIGHTER_STATS] # can_start_battle() now checks roster, not live units -- see BloodTournamentMode.can_start_battle()
	GameManager.start_battle()
	await wait_physics_frames(2) # let the staggered deployment queue actually spawn the roster

	_kill_team(GameManager.RED_TEAM_ID) # FIGHTER_STATS.squad_size is 5 -- one kill wouldn't eliminate the team

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
	blue.roster = [TANK_STATS]
	red.roster = [FIGHTER_STATS]

	GameManager.start_battle()
	await wait_physics_frames(2)
	_kill_team(GameManager.RED_TEAM_ID)
	assert_false(mode.is_match_over(), "one round shouldn't decide a best-of-2")

	GameManager.reset_battle() # no permadeath -- roster persists, so round 2 doesn't need buying anything new

	GameManager.start_battle()
	await wait_physics_frames(2)
	_kill_team(GameManager.RED_TEAM_ID)

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
	blue.roster = [TANK_STATS]
	red.roster = [FIGHTER_STATS]
	GameManager.start_battle()
	await wait_physics_frames(2)

	_kill_team(GameManager.RED_TEAM_ID)
	assert_true(GameManager.is_game_over(), "sanity check: the round should have ended")

	await wait_physics_frames(2) # let the deferred _advance_to_next_round() run

	assert_true(GameManager.is_placement_phase(), "Main.gd should auto-reset for the next round")


## Blood Tournament v2 correction: no permadeath. reset_battle() always
## frees every unit, dead or alive -- what persists between rounds is
## Player.roster (data), not a literal surviving Unit node. See
## Main._respawn_rosters() for the other half.
func test_reset_battle_always_frees_every_unit_dead_or_alive() -> void:
	var blue := GameManager.get_player(GameManager.BLUE_TEAM_ID)
	var red := GameManager.get_player(GameManager.RED_TEAM_ID)
	var alive_unit := GameManager.spawn_unit(TANK_STATS, blue, Vector3(-3, 0, 0))
	var dead_unit := GameManager.spawn_unit(FIGHTER_STATS, red, Vector3(3, 0, 0))
	GameManager.start_battle()
	dead_unit.take_damage(DamageInstance.new(dead_unit.stat_block.max_health() + 100.0))

	GameManager.reset_battle()

	assert_true(alive_unit.is_queued_for_deletion(), "no survivor carryover -- reset_battle() always frees every unit now")
	assert_true(dead_unit.is_queued_for_deletion())
	assert_false(GameManager.can_start_battle())


## Full integration through Main.gd's actual round-advance path: a unit
## that DIES in round 1 must still stay on the roster for round 2 (no
## permadeath), and a unit that survived gets no special treatment over
## one that died -- both are just "on the roster," and neither literal
## Unit node survives the round transition. Under the staggered/staging-
## area deployment model (Main._begin_staggered_deployment()), the roster
## only becomes live Units again once BATTLE actually starts for round 2
## -- reopening PLACEMENT alone does not respawn anything, unlike the
## earlier instant-respawn design this superseded.
func test_blood_tournament_round_transition_keeps_the_full_roster_no_permadeath() -> void:
	_main._on_tournament_toggled(true)

	var blue := GameManager.get_player(GameManager.BLUE_TEAM_ID)
	var red := GameManager.get_player(GameManager.RED_TEAM_ID)
	blue.roster = [TANK_STATS]
	red.roster = [FIGHTER_STATS]
	GameManager.start_battle()
	await wait_physics_frames(2) # let the staggered deployment queue spawn round 1's squads

	var round_1_units := GameManager.get_all_units() # TANK_STATS/FIGHTER_STATS both deploy multi-unit squads (squad_size 3/5)
	_kill_team(GameManager.RED_TEAM_ID)
	await wait_physics_frames(2) # let the deferred _advance_to_next_round() run

	for unit in round_1_units:
		assert_false(is_instance_valid(unit), "no unit survives as a literal node across rounds, winner included -- reset_battle() frees everyone")
	assert_true(GameManager.is_placement_phase())
	assert_eq(blue.roster, [TANK_STATS], "Blue's roster should persist into round 2 -- no permadeath")
	assert_eq(red.roster, [FIGHTER_STATS], "Red's roster should persist despite dying last round -- no permadeath")
	assert_true(GameManager.team_is_empty(GameManager.BLUE_TEAM_ID), "nothing spawns live again until the next battle actually starts -- see Main._begin_staggered_deployment()")
	assert_true(GameManager.team_is_empty(GameManager.RED_TEAM_ID))


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
