## Tests for Scripts/Hotkeys.gd -- roadmap Phase 3's "rebindable
## hotkeys" item. Confirms the InputMap actions this project relies on
## (Scripts/PlayerInputController.gd, Scripts/OrbitCamera.gd) actually
## get registered at boot, and that rebind() really does replace a
## key's binding rather than just adding a second one alongside it.
extends GutTest

var _original_order_stop_events: Array[InputEvent] = []


func before_each() -> void:
	# rebind() tests mutate a real, project-wide InputMap action --
	# restore it afterward so no other test file (which all assume the
	# default S = order_stop binding) is affected by run order.
	_original_order_stop_events = InputMap.action_get_events("order_stop")


func after_each() -> void:
	InputMap.action_erase_events("order_stop")
	for event in _original_order_stop_events:
		InputMap.action_add_event("order_stop", event)


func test_every_default_binding_is_registered_as_a_real_inputmap_action() -> void:
	for action_name in Hotkeys.DEFAULT_BINDINGS:
		assert_true(InputMap.has_action(action_name), "%s should be registered by Hotkeys._ready()" % action_name)


func test_a_default_bound_key_event_matches_its_action() -> void:
	var event := InputEventKey.new()
	event.keycode = KEY_S
	event.pressed = true
	assert_true(event.is_action_pressed("order_stop"),
		"the default S keycode should match the order_stop action Hotkeys registers")


func test_rebind_replaces_the_actions_bound_key_rather_than_adding_a_second_one() -> void:
	Hotkeys.rebind("order_stop", KEY_X)

	var old_key_event := InputEventKey.new()
	old_key_event.keycode = KEY_S
	old_key_event.pressed = true
	assert_false(old_key_event.is_action_pressed("order_stop"),
		"the old S binding should no longer trigger order_stop after rebinding")

	var new_key_event := InputEventKey.new()
	new_key_event.keycode = KEY_X
	new_key_event.pressed = true
	assert_true(new_key_event.is_action_pressed("order_stop"),
		"the new X binding should trigger order_stop after rebinding")
