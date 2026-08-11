## Tests for Scripts/Autoloads/Hotkeys.gd -- roadmap Phase 3's "rebindable
## hotkeys" item (registration/rebind()) and Phase 10's settings-screen
## support added alongside UI/SettingsMenu.gd (display_name(),
## find_conflicting_action(), reset_to_defaults()).
extends GutTest


func after_each() -> void:
	# Several tests below rebind more than one action (conflict-detection
	# needs two real actions to collide) -- reset_to_defaults() restores
	# every one of them at once, so no other test file (which all assume
	# Hotkeys.DEFAULT_BINDINGS' own defaults, e.g. X = order_stop) is
	# affected by run order, the same cross-test-pollution risk already on
	# file for every other persistent-autoload-owned piece of state in
	# this project.
	Hotkeys.reset_to_defaults()


func test_every_default_binding_is_registered_as_a_real_inputmap_action() -> void:
	for action_name in Hotkeys.DEFAULT_BINDINGS:
		assert_true(InputMap.has_action(action_name), "%s should be registered by Hotkeys._ready()" % action_name)


func test_a_default_bound_key_event_matches_its_action() -> void:
	var event := InputEventKey.new()
	event.keycode = KEY_X
	event.pressed = true
	assert_true(event.is_action_pressed("order_stop"),
		"the default X keycode should match the order_stop action Hotkeys registers")


func test_rebind_replaces_the_actions_bound_key_rather_than_adding_a_second_one() -> void:
	Hotkeys.rebind("order_stop", KEY_Y)

	var old_key_event := InputEventKey.new()
	old_key_event.keycode = KEY_X
	old_key_event.pressed = true
	assert_false(old_key_event.is_action_pressed("order_stop"),
		"the old X binding should no longer trigger order_stop after rebinding")

	var new_key_event := InputEventKey.new()
	new_key_event.keycode = KEY_Y
	new_key_event.pressed = true
	assert_true(new_key_event.is_action_pressed("order_stop"),
		"the new Y binding should trigger order_stop after rebinding")


func test_every_default_binding_has_a_display_name() -> void:
	for action_name in Hotkeys.DEFAULT_BINDINGS:
		assert_ne(Hotkeys.display_name(action_name), "", "%s should have a player-facing label" % action_name)


func test_find_conflicting_action_reports_nothing_for_an_unclaimed_key() -> void:
	assert_eq(Hotkeys.find_conflicting_action("order_stop", KEY_Z), "")


func test_find_conflicting_action_reports_the_other_action_holding_that_key() -> void:
	assert_eq(Hotkeys.find_conflicting_action("order_stop", KEY_H), "order_hold")


func test_find_conflicting_action_excludes_the_action_being_rebound_itself() -> void:
	# order_stop already holds KEY_X by default -- rebinding it to the key
	# it already has shouldn't read as a conflict with itself.
	assert_eq(Hotkeys.find_conflicting_action("order_stop", KEY_X), "")


func test_reset_to_defaults_restores_every_action_after_rebinding_several() -> void:
	Hotkeys.rebind("order_stop", KEY_X)
	Hotkeys.rebind("order_hold", KEY_Y)

	Hotkeys.reset_to_defaults()

	for action_name in Hotkeys.DEFAULT_BINDINGS:
		var events := InputMap.action_get_events(action_name)
		assert_eq(events.size(), 1)
		assert_eq((events[0] as InputEventKey).keycode, Hotkeys.DEFAULT_BINDINGS[action_name],
			"%s should be back to its default keycode" % action_name)
