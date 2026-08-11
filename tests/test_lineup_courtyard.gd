## Tests for Blood Tournament's literal 3D lineup courtyard (roadmap Phase
## 11, corrected D4): purchased units stand as real, inert Unit instances
## in a per-team courtyard the whole time between rounds, plus one
## permanent invulnerable "Builder" NPC fixture per team
## (Resources/Units/BuilderStats.tres) that never counts toward
## GameManager.team_is_empty()/win conditions -- see
## GameManager.spawn_courtyard_fixture()'s own doc comment for why that
## exclusion is load-bearing, not cosmetic.
extends GutTest

const TANK_STATS: UnitStats = preload("res://Resources/Units/TankStats.tres")
const FIGHTER_STATS: UnitStats = preload("res://Resources/Units/FighterStats.tres")
const BUILDER_STATS: UnitStats = preload("res://Resources/Units/BuilderStats.tres")

var _main: Node3D


func before_each() -> void:
	GameManager.reset_battle()
	GameManager.current_mode = ClassicEliminationMode.new() # don't let an earlier test's mode leak in
	# Player is a plain RefCounted that outlives each test, same as
	# GameManager itself -- reset every field an earlier test could have
	# left dirty (same recurring lesson this codebase's other economy
	# tests already document).
	for team_id in [GameManager.BLUE_TEAM_ID, GameManager.RED_TEAM_ID]:
		var player := GameManager.get_player(team_id)
		player.resources = 0
		player.blood_points = 0
		player.roster.clear()
		player.roster_upgrades.clear()
		player.courtyard_units.clear()
	_main = load("res://Scenes/Main.tscn").instantiate()
	add_child_autofree(_main)
	await wait_physics_frames(2)


func test_builder_is_invulnerable() -> void:
	var blue := GameManager.get_player(GameManager.BLUE_TEAM_ID)
	var builder := GameManager.spawn_courtyard_fixture(BUILDER_STATS, blue, Vector3(20, 0, 20))

	var took_damage := builder.take_damage(DamageInstance.new(builder.stat_block.max_health() + 1000.0))

	assert_false(took_damage, "take_damage() should no-op entirely for an invulnerable Builder")
	assert_almost_eq(builder.current_health, BUILDER_STATS.max_health, 0.01, "health should be completely unaffected")
	assert_eq(builder.life_state, Unit.LifeState.ALIVE)


## Regression: BloodTournamentMode.on_activated() used to be reachable
## twice for real (a mid-match HUD toggle could reactivate an
## already-active mode -- removed entirely, see UI/HUD.gd's own doc
## comment), silently spawning a second Builder fixture and granting
## starting gold a second time. on_activated() itself is now guarded
## per-player against this regardless of how it gets called.
func test_reactivating_blood_tournament_does_not_duplicate_the_builder_or_regrant_gold() -> void:
	_main._on_tournament_toggled(true)
	var blue := GameManager.get_player(GameManager.BLUE_TEAM_ID)
	var gold_after_first_activation := blue.resources

	_main._on_tournament_toggled(true)

	var builder_count := 0
	for child in GameManager.units_container.get_children():
		if child is Unit and child.player == blue and child.stats.is_builder:
			builder_count += 1
	assert_eq(builder_count, 1, "reactivating the same mode should never duplicate the Builder fixture")
	assert_eq(blue.resources, gold_after_first_activation, "reactivating the same mode should never re-grant starting gold")


func test_builder_is_absent_from_get_all_units_and_units_by_team() -> void:
	var blue := GameManager.get_player(GameManager.BLUE_TEAM_ID)
	var units_before := GameManager.get_all_units().size()

	GameManager.spawn_courtyard_fixture(BUILDER_STATS, blue, Vector3(20, 0, 20))

	assert_eq(GameManager.get_all_units().size(), units_before, "a Builder must never appear in get_all_units()")
	assert_true(GameManager.team_is_empty(GameManager.BLUE_TEAM_ID), "a Builder alone must never make team_is_empty() false -- that would silently break BloodTournamentMode.check_victory()'s elimination check")


## The actual bug this exclusion prevents: a real squad unit on the same
## team dies, but the (unregistered) Builder standing right next to it
## must have zero influence on team_is_empty() either way.
func test_builder_does_not_mask_a_real_teams_elimination() -> void:
	var blue := GameManager.get_player(GameManager.BLUE_TEAM_ID)
	GameManager.spawn_courtyard_fixture(BUILDER_STATS, blue, Vector3(20, 0, 20))
	var combatant := GameManager.spawn_unit(TANK_STATS, blue, Vector3(-3, 0, 0))
	assert_false(GameManager.team_is_empty(GameManager.BLUE_TEAM_ID))

	combatant.take_damage(DamageInstance.new(combatant.stat_block.max_health() + 1000.0))

	assert_true(GameManager.team_is_empty(GameManager.BLUE_TEAM_ID), "with the Builder correctly uncounted, the team's last real combatant dying should read as eliminated")


## reset_battle() must never free a Builder -- it's spawned once per team
## for the whole match (BloodTournamentMode.on_activated(), not
## implemented yet in this step), not respawned every round.
func test_reset_battle_does_not_free_a_courtyard_fixture() -> void:
	var blue := GameManager.get_player(GameManager.BLUE_TEAM_ID)
	var builder := GameManager.spawn_courtyard_fixture(BUILDER_STATS, blue, Vector3(20, 0, 20))

	GameManager.reset_battle()

	assert_true(is_instance_valid(builder), "spawn_courtyard_fixture() must not register with _all_units, or reset_battle() would free it")


# ---------------------------------------------------------------------
# Courtyard geometry
# ---------------------------------------------------------------------

func test_all_8_courtyards_are_pairwise_non_overlapping() -> void:
	var min_separation := CrossArenaMap.COURTYARD_HALF_EXTENT * 2.0
	for a in GameManager.all_team_ids():
		for b in GameManager.all_team_ids():
			if a == b:
				continue
			var distance := CrossArenaMap.get_courtyard_position(a).distance_to(CrossArenaMap.get_courtyard_position(b))
			assert_gt(distance, min_separation, "team %d and %d's courtyards should never overlap" % [a, b])


## A courtyard must be a "dead corner" by the pre-existing arm-clamp's own
## definition (outside both the vertical and horizontal bars) -- confirms
## the geometry assumption CrossArenaMap.is_in_any_courtyard()'s early-out
## depends on actually holds, not just that the numbers "look" separated.
func test_every_courtyard_sits_outside_both_cross_arms() -> void:
	var half := GameManager.CROSS_ARM_HALF_WIDTH
	for team_id in GameManager.all_team_ids():
		var pos := CrossArenaMap.get_courtyard_position(team_id)
		var in_vertical_bar := absf(pos.x) <= half
		var in_horizontal_bar := absf(pos.z) <= half
		assert_false(in_vertical_bar or in_horizontal_bar, "team %d's courtyard should be a dead corner, not inside either arm" % team_id)


## The actual bug the clamp fix prevents: without CrossArenaMap.is_in_any_courtyard()'s
## early-out, this unit would get pulled onto the nearest arm within one
## physics frame.
func test_a_unit_standing_in_a_courtyard_does_not_get_clamped_onto_an_arm() -> void:
	GameManager.set_mode(BloodTournamentMode.new()) # uses_cross_map() == true, so the cross-arena clamp branch actually runs
	var blue := GameManager.get_player(GameManager.BLUE_TEAM_ID)
	var unit_anchor := CrossArenaMap.get_courtyard_unit_anchor(GameManager.BLUE_TEAM_ID)
	var unit := GameManager.spawn_unit(TANK_STATS, blue, unit_anchor)

	await wait_physics_frames(5)

	assert_almost_eq(unit.global_position.x, unit_anchor.x, 0.5, "the clamp should never pull a courtyard unit back onto an arm")
	assert_almost_eq(unit.global_position.z, unit_anchor.z, 0.5)


## The Builder and the point purchased squads spawn at used to be the
## exact same position (full overlap) -- now pushed apart to opposite
## sides of the courtyard.
func test_builder_and_unit_anchor_do_not_overlap() -> void:
	for team_id in GameManager.all_team_ids():
		var builder_pos := CrossArenaMap.get_courtyard_position(team_id)
		var unit_pos := CrossArenaMap.get_courtyard_unit_anchor(team_id)
		assert_gt(builder_pos.distance_to(unit_pos), 2.0, "team %d's Builder and unit anchor should be well apart" % team_id)
		# Both anchors should still land inside that same team's own
		# courtyard footprint, not drift into a neighboring one.
		assert_almost_eq(builder_pos.x, unit_pos.x, CrossArenaMap.COURTYARD_HALF_EXTENT * 2.0)
		assert_almost_eq(builder_pos.z, unit_pos.z, CrossArenaMap.COURTYARD_HALF_EXTENT * 2.0)


# ---------------------------------------------------------------------
# buy_roster_slot() / sync_courtyard_to_roster()
# ---------------------------------------------------------------------

## Clicking a build-menu button only ARMS the ghost now (see
## PlayerInputController.begin_build_placement()) -- the actual purchase
## needs a second, confirming click at a legal spot. See the "Ghost
## placement" section below for the click-to-place flow itself; this
## test just proves the whole squad still lands correctly once confirmed.
func test_confirming_placement_spawns_the_full_squad_at_the_clicked_spot() -> void:
	GameManager.set_mode(BloodTournamentMode.new())
	var blue := GameManager.get_player(GameManager.BLUE_TEAM_ID)
	blue.resources = FIGHTER_STATS.cost
	var camera: Camera3D = _main.get_node("Camera3D")
	var target := CrossArenaMap.get_courtyard_unit_anchor(GameManager.BLUE_TEAM_ID)
	camera._focus_point = Vector3(target.x, 0, target.z)
	camera._update_transform()

	_main._on_unit_type_selected(FIGHTER_STATS) # squad_size 5 -- arms the ghost, does not buy yet
	assert_true(blue.courtyard_units.is_empty(), "sanity check: nothing bought until a placement click confirms it")

	_main._try_left_click_at(camera.unproject_position(target))

	assert_eq(blue.courtyard_units.size(), 1, "one roster slot should mean one courtyard_units entry")
	assert_eq(blue.courtyard_units[0].size(), FIGHTER_STATS.squad_size, "the whole squad should stand at the clicked spot, not just one unit")
	for unit in blue.courtyard_units[0]:
		assert_true(is_instance_valid(unit))
		assert_almost_eq(unit.global_position.x, target.x, 4.0, "should stand where the player clicked")


## The AI must go through the exact same buy_roster_slot() gate as the
## human path -- proves it too gets a live courtyard squad, not just a
## data entry (AIController.take_turn() used to append to roster directly).
func test_ai_purchases_also_populate_the_courtyard() -> void:
	GameManager.set_mode(BloodTournamentMode.new())
	var red := GameManager.get_player(GameManager.RED_TEAM_ID)
	red.resources = 500

	AIController.new().take_turn(red)

	assert_false(red.roster.is_empty())
	assert_eq(red.courtyard_units.size(), red.roster.size(), "every AI-bought roster slot should have a matching live courtyard squad")


## The reconciliation safety net: a test (or any caller) that sets
## player.roster directly, bypassing buy_roster_slot() entirely, must
## still end up with the right courtyard units by the time start_battle()
## actually runs -- this is what keeps the existing test suite's dominant
## "player.roster = [...]" setup idiom working unmodified under the new
## courtyard model.
func test_directly_mutating_roster_still_produces_correct_courtyard_units_once_battle_starts() -> void:
	GameManager.set_mode(BloodTournamentMode.new())
	var blue := GameManager.get_player(GameManager.BLUE_TEAM_ID)
	var red := GameManager.get_player(GameManager.RED_TEAM_ID)
	blue.roster = [TANK_STATS] # bypasses buy_roster_slot() entirely, same as most of this codebase's existing tests
	red.roster = [FIGHTER_STATS]
	assert_true(blue.courtyard_units.is_empty(), "sanity check: nothing should have synced yet")

	GameManager.start_battle()

	var blue_units := GameManager.get_all_units().filter(func(u: Unit) -> bool: return u.player == blue and u.stats == TANK_STATS)
	assert_eq(blue_units.size(), TANK_STATS.squad_size, "the roster set directly, with no buy_roster_slot() call, should still have deployed via the safety-net sync inside start_battle()")


## reset_battle() clears courtyard_units, but the roster itself survives
## and gets re-realized into fresh courtyard units the next time PLACEMENT
## opens, without requiring a fresh purchase.
func test_round_transition_repopulates_the_courtyard_from_the_persisted_roster() -> void:
	GameManager.set_mode(BloodTournamentMode.new())
	var blue := GameManager.get_player(GameManager.BLUE_TEAM_ID)
	var red := GameManager.get_player(GameManager.RED_TEAM_ID)
	blue.roster = [TANK_STATS]
	red.roster = [FIGHTER_STATS]
	GameManager.sync_courtyard_to_roster(blue)

	GameManager.reset_battle()
	assert_true(blue.courtyard_units.is_empty(), "reset_battle() should clear courtyard_units")
	GameManager.sync_courtyard_to_roster(blue) # normally BloodTournamentController.advance_to_next_round() does this for every team

	assert_eq(blue.roster, [TANK_STATS], "the roster itself should never have been touched by any of this")
	assert_eq(blue.courtyard_units.size(), 1)
	assert_eq(blue.courtyard_units[0].size(), TANK_STATS.squad_size, "a fresh squad should stand in the courtyard again, with no purchase needed")


# ---------------------------------------------------------------------
# Selling
# ---------------------------------------------------------------------

## Right-clicking the Builder itself must never be treated as a sale --
## it's a permanent fixture, not a roster slot (PlayerInputController.try_sell_unit_at()
## checks UnitStats.is_builder before anything else).
func test_right_clicking_the_builder_does_not_sell_anything() -> void:
	GameManager.set_mode(BloodTournamentMode.new())
	var blue := GameManager.get_player(GameManager.BLUE_TEAM_ID)
	var builder := GameManager.spawn_courtyard_fixture(BUILDER_STATS, blue, CrossArenaMap.get_courtyard_position(GameManager.BLUE_TEAM_ID))
	blue.resources = TANK_STATS.cost
	var camera: Camera3D = _main.get_node("Camera3D")
	# The default camera focuses the arena's center -- Blue's courtyard
	# sits ~30m out, near the edge of (or past) its view frustum, where
	# unproject_position()/raycast precision degrades. Re-focus on the
	# courtyard first so the projected screen position unambiguously
	# targets the Builder and not the nearby (2.5m-offset) Tank squad.
	camera._focus_point = Vector3(builder.global_position.x, 0, builder.global_position.z)
	camera._update_transform()
	_main._on_unit_type_selected(TANK_STATS) # arms the ghost
	_main._try_left_click_at(camera.unproject_position(CrossArenaMap.get_courtyard_unit_anchor(GameManager.BLUE_TEAM_ID))) # confirms it
	await wait_physics_frames(1)
	assert_eq(blue.roster.size(), 1, "sanity check: the Tank should actually be bought before testing that right-clicking the Builder doesn't sell it")
	var gold_before := blue.resources

	_main._try_sell_unit_at(camera.unproject_position(builder.global_position))

	assert_eq(blue.roster.size(), 1, "clicking the Builder should never remove a roster slot")
	assert_eq(blue.resources, gold_before, "clicking the Builder should never grant a refund")
	assert_true(is_instance_valid(builder))


# ---------------------------------------------------------------------
# Build menu (left-click the Builder)
# ---------------------------------------------------------------------

func test_left_clicking_your_own_builder_opens_the_build_menu() -> void:
	GameManager.set_mode(BloodTournamentMode.new())
	var blue := GameManager.get_player(GameManager.BLUE_TEAM_ID)
	var builder := GameManager.spawn_courtyard_fixture(BUILDER_STATS, blue, CrossArenaMap.get_courtyard_position(GameManager.BLUE_TEAM_ID))
	var camera: Camera3D = _main.get_node("Camera3D")
	camera._focus_point = Vector3(builder.global_position.x, 0, builder.global_position.z)
	camera._update_transform()
	await wait_physics_frames(1)
	assert_false(_main._hud.is_build_menu_open(), "sanity check: closed before any click")

	_main._try_left_click_at(camera.unproject_position(builder.global_position))

	assert_true(_main._hud.is_build_menu_open())


func test_left_clicking_an_enemy_builder_does_not_open_your_build_menu() -> void:
	GameManager.set_mode(BloodTournamentMode.new())
	var red := GameManager.get_player(GameManager.RED_TEAM_ID)
	var builder := GameManager.spawn_courtyard_fixture(BUILDER_STATS, red, CrossArenaMap.get_courtyard_position(GameManager.RED_TEAM_ID))
	var camera: Camera3D = _main.get_node("Camera3D")
	camera._focus_point = Vector3(builder.global_position.x, 0, builder.global_position.z)
	camera._update_transform()
	await wait_physics_frames(1) # _main._input.selected_player defaults to Blue -- Red's Builder belongs to someone else

	_main._try_left_click_at(camera.unproject_position(builder.global_position))

	assert_false(_main._hud.is_build_menu_open(), "clicking an opponent's Builder shouldn't open your own build menu")


func test_clicking_empty_ground_closes_the_build_menu() -> void:
	GameManager.set_mode(BloodTournamentMode.new())
	var blue := GameManager.get_player(GameManager.BLUE_TEAM_ID)
	GameManager.spawn_courtyard_fixture(BUILDER_STATS, blue, CrossArenaMap.get_courtyard_position(GameManager.BLUE_TEAM_ID))
	_main._hud.show_build_menu()
	await wait_physics_frames(1)

	_main._try_left_click_at(_main.get_viewport().get_visible_rect().size / 2) # empty ground near the arena center

	assert_false(_main._hud.is_build_menu_open())


func test_build_menu_button_tooltip_reports_cost_and_squad_size() -> void:
	var hud: Control = _main._hud
	var tooltip: String = hud._unit_tooltip_text(TANK_STATS)

	assert_true(tooltip.contains(str(TANK_STATS.cost)), "tooltip should mention cost")
	assert_true(tooltip.contains(str(TANK_STATS.squad_size)), "tooltip should mention squad size")
	assert_true(tooltip.contains(TANK_STATS.unit_name))


# ---------------------------------------------------------------------
# Ghost placement (PlayerInputController._pending_build_stats)
# ---------------------------------------------------------------------

func test_arming_a_build_shows_the_ghost() -> void:
	GameManager.set_mode(BloodTournamentMode.new())
	assert_false(_main._is_build_placement_armed(), "sanity check: not armed before any click")
	assert_false(_main._placement_ghost_visible())

	_main._on_unit_type_selected(TANK_STATS)

	assert_true(_main._is_build_placement_armed())
	assert_true(_main._placement_ghost_visible())


func test_arming_does_not_buy_anything_until_confirmed() -> void:
	GameManager.set_mode(BloodTournamentMode.new())
	var blue := GameManager.get_player(GameManager.BLUE_TEAM_ID)
	var gold_before := blue.resources

	_main._on_unit_type_selected(TANK_STATS)

	assert_true(blue.roster.is_empty())
	assert_eq(blue.resources, gold_before)


func test_mouse_motion_moves_the_ghost_and_tints_it_by_courtyard_validity() -> void:
	GameManager.set_mode(BloodTournamentMode.new())
	var camera: Camera3D = _main.get_node("Camera3D")
	var inside := CrossArenaMap.get_courtyard_unit_anchor(GameManager.BLUE_TEAM_ID)
	camera._focus_point = Vector3(inside.x, 0, inside.z)
	camera._update_transform()
	_main._on_unit_type_selected(TANK_STATS)

	_main._try_move_mouse_to(camera.unproject_position(inside))

	assert_almost_eq(_main._placement_ghost_position().x, inside.x, 0.5)
	assert_false(_main._placement_ghost_is_tinted_invalid(), "a point inside Blue's own courtyard should look valid")

	_main._try_move_mouse_to(camera.unproject_position(Vector3.ZERO)) # the arena center -- well outside any courtyard

	assert_true(_main._placement_ghost_is_tinted_invalid(), "the arena center is outside Blue's courtyard")


## Confirming outside the buying team's own courtyard is a silent no-op
## -- stays armed, no gold spent -- rather than a cancel, matching "can't
## place somewhere invalid" RTS convention.
func test_confirming_outside_the_courtyard_does_not_buy_and_stays_armed() -> void:
	GameManager.set_mode(BloodTournamentMode.new())
	var blue := GameManager.get_player(GameManager.BLUE_TEAM_ID)
	var camera: Camera3D = _main.get_node("Camera3D")
	var gold_before := blue.resources
	_main._on_unit_type_selected(TANK_STATS)

	_main._try_left_click_at(camera.unproject_position(Vector3.ZERO)) # the arena center, outside any courtyard

	assert_true(blue.roster.is_empty(), "no purchase should happen for an invalid spot")
	assert_eq(blue.resources, gold_before)
	assert_true(_main._is_build_placement_armed(), "an invalid click shouldn't cancel placement, just fail to confirm it")


func test_right_click_cancels_placement_without_buying() -> void:
	GameManager.set_mode(BloodTournamentMode.new())
	var blue := GameManager.get_player(GameManager.BLUE_TEAM_ID)
	var gold_before := blue.resources
	_main._on_unit_type_selected(TANK_STATS)
	assert_true(_main._is_build_placement_armed())

	_main._try_right_press_at(Vector2.ZERO)

	assert_false(_main._is_build_placement_armed())
	assert_false(_main._placement_ghost_visible())
	assert_true(blue.roster.is_empty())
	assert_eq(blue.resources, gold_before)


func test_escape_cancels_placement_without_buying() -> void:
	GameManager.set_mode(BloodTournamentMode.new())
	var blue := GameManager.get_player(GameManager.BLUE_TEAM_ID)
	var gold_before := blue.resources
	_main._on_unit_type_selected(TANK_STATS)
	assert_true(_main._is_build_placement_armed())

	_main._try_press_key(KEY_ESCAPE)

	assert_false(_main._is_build_placement_armed())
	assert_false(_main._placement_ghost_visible())
	assert_true(blue.roster.is_empty())
	assert_eq(blue.resources, gold_before)


# ---------------------------------------------------------------------
# Drag-to-reorder (PlayerInputController._resolve_courtyard_drag())
# ---------------------------------------------------------------------

func test_dragging_a_courtyard_squad_reorders_the_roster_to_match_its_physical_arrangement() -> void:
	GameManager.set_mode(BloodTournamentMode.new())
	var blue := GameManager.get_player(GameManager.BLUE_TEAM_ID)
	var camera: Camera3D = _main.get_node("Camera3D")
	var center := CrossArenaMap.get_courtyard_unit_anchor(GameManager.BLUE_TEAM_ID)
	var inward := CrossArenaMap.get_courtyard_inward_direction(GameManager.BLUE_TEAM_ID)
	var back_point := center - Vector3(inward.x, 0, inward.y) * 2.0
	var front_point := center + Vector3(inward.x, 0, inward.y) * 2.0
	camera._focus_point = Vector3(center.x, 0, center.z)
	camera._update_transform()

	# Buy Tank at the back, Fighter at the front -- roster starts in
	# purchase order regardless of physical position (buying never
	# reorders on its own).
	_main._on_unit_type_selected(TANK_STATS)
	_main._try_left_click_at(camera.unproject_position(back_point))
	_main._on_unit_type_selected(FIGHTER_STATS)
	_main._try_left_click_at(camera.unproject_position(front_point))
	assert_eq(blue.roster, [TANK_STATS, FIGHTER_STATS], "sanity check: purchase order before any drag")
	await wait_physics_frames(1) # let the physics server register the new collision shapes before raycasting

	# Drag Tank (physically behind Fighter) and drop it right back where
	# it already was -- any committed drag should reorder the roster to
	# match the courtyard's actual front-to-back arrangement, so Fighter
	# (already further forward) should now sort first.
	_main._try_start_unit_drag(camera.unproject_position(blue.courtyard_units[0][0].global_position))
	assert_eq(_main._drag_source_squad_index, 0, "sanity check: the drag should have armed on Tank's slot")

	# A real drag has to actually move the cursor past the click-vs-drag
	# threshold before a drop commits (handle_mouse_motion()) -- otherwise
	# this is indistinguishable from a plain click that shouldn't reposition
	# anything (usability report, 2026-08-11: clicking a courtyard unit to
	# inspect it was shifting it).
	_main._try_move_mouse_to(camera.unproject_position(back_point), true)
	_main._try_left_click_at(camera.unproject_position(back_point))

	assert_eq(blue.roster, [FIGHTER_STATS, TANK_STATS], "roster order should now match the physical front-to-back arrangement")
	assert_eq(blue.courtyard_units.size(), 2, "reorder should permute, not duplicate or drop, courtyard_units")


func test_dropping_a_dragged_squad_outside_the_courtyard_reverts_its_position_and_does_not_reorder() -> void:
	GameManager.set_mode(BloodTournamentMode.new())
	var blue := GameManager.get_player(GameManager.BLUE_TEAM_ID)
	var camera: Camera3D = _main.get_node("Camera3D")
	var center := CrossArenaMap.get_courtyard_unit_anchor(GameManager.BLUE_TEAM_ID)
	var inward := CrossArenaMap.get_courtyard_inward_direction(GameManager.BLUE_TEAM_ID)
	var back_point := center - Vector3(inward.x, 0, inward.y) * 2.0
	var front_point := center + Vector3(inward.x, 0, inward.y) * 2.0
	camera._focus_point = Vector3(center.x, 0, center.z)
	camera._update_transform()

	_main._on_unit_type_selected(TANK_STATS)
	_main._try_left_click_at(camera.unproject_position(back_point))
	_main._on_unit_type_selected(FIGHTER_STATS)
	_main._try_left_click_at(camera.unproject_position(front_point))
	await wait_physics_frames(1) # let the physics server register the new collision shapes before raycasting
	var fighter_squad: Array = blue.courtyard_units[1]
	var centroid_before := _centroid(fighter_squad)

	_main._try_start_unit_drag(camera.unproject_position(fighter_squad[0].global_position))
	assert_eq(_main._drag_source_squad_index, 1, "sanity check: the drag should have armed on Fighter's slot")

	# See the sibling reorder test's own comment -- a real drag has to
	# cross the click-vs-drag distance threshold before a drop commits.
	_main._try_move_mouse_to(camera.unproject_position(Vector3.ZERO), true)
	_main._try_left_click_at(camera.unproject_position(Vector3.ZERO)) # arena center, outside any courtyard

	var centroid_after := _centroid(fighter_squad)
	assert_almost_eq(centroid_after.x, centroid_before.x, 1.0, "an invalid drop should revert the squad to about its pre-drag position")
	assert_almost_eq(centroid_after.z, centroid_before.z, 1.0)
	assert_eq(blue.roster, [TANK_STATS, FIGHTER_STATS], "an invalid drop must not reorder the roster")


func _centroid(squad: Array) -> Vector3:
	var total := Vector3.ZERO
	for unit in squad:
		total += unit.global_position
	return total / squad.size()


func test_the_builder_cannot_be_dragged() -> void:
	GameManager.set_mode(BloodTournamentMode.new())
	var blue := GameManager.get_player(GameManager.BLUE_TEAM_ID)
	var builder := GameManager.spawn_courtyard_fixture(BUILDER_STATS, blue, CrossArenaMap.get_courtyard_position(GameManager.BLUE_TEAM_ID))
	var camera: Camera3D = _main.get_node("Camera3D")
	camera._focus_point = Vector3(builder.global_position.x, 0, builder.global_position.z)
	camera._update_transform()

	_main._try_start_unit_drag(camera.unproject_position(builder.global_position))

	assert_null(_main._dragging_unit, "the Builder is a permanent fixture, never a draggable roster slot")
	assert_eq(_main._drag_source_squad_index, -1)


## sync_courtyard_to_roster() spawns every newly-reconciled slot at the
## exact same default anchor -- reorder_roster_by_courtyard_depth()'s
## sort must tie-break by current index so slots nobody has dragged yet
## never visibly reshuffle just from an unstable sort.
func test_untouched_squads_at_the_same_default_anchor_keep_their_purchase_order() -> void:
	var blue := GameManager.get_player(GameManager.BLUE_TEAM_ID)
	blue.roster = [TANK_STATS, FIGHTER_STATS, TANK_STATS]
	GameManager.sync_courtyard_to_roster(blue)

	GameManager.reorder_roster_by_courtyard_depth(blue)

	assert_eq(blue.roster, [TANK_STATS, FIGHTER_STATS, TANK_STATS], "identical-anchor slots must not reshuffle from an unstable sort")
