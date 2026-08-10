## Tests for Scripts/SettingsMenu.gd (roadmap Phase 10's "settings/
## keybind remapping UI" item) -- the screen that finally calls into
## Scripts/Hotkeys.gd's already-tested rebind()/find_conflicting_action()/
## reset_to_defaults(). Drives begin_rebind()/_handle_rebind_key()
## directly rather than routing a synthetic InputEvent through the whole
## SceneTree, matching this project's established style for anything a
## key press ultimately triggers (see Main._try_place_unit()/etc.).
extends GutTest

var _menu: Control


func before_each() -> void:
	_menu = load("res://Scenes/SettingsMenu.tscn").instantiate()
	add_child_autofree(_menu)
	await wait_physics_frames(1)


func after_each() -> void:
	Hotkeys.reset_to_defaults() # several tests below rebind a real, project-wide InputMap action


func _key_event(keycode: Key) -> InputEventKey:
	var event := InputEventKey.new()
	event.keycode = keycode
	event.pressed = true
	return event


func test_builds_one_row_per_default_binding_showing_its_current_key() -> void:
	assert_eq(_menu._key_labels.size(), Hotkeys.DEFAULT_BINDINGS.size())
	var stop_label: Label = _menu._key_labels["order_stop"]
	assert_eq(stop_label.text, OS.get_keycode_string(KEY_S))


func test_begin_rebind_shows_a_listening_prompt_for_that_row_only() -> void:
	_menu.begin_rebind("order_stop")

	var stop_label: Label = _menu._key_labels["order_stop"]
	var hold_label: Label = _menu._key_labels["order_hold"]
	assert_eq(stop_label.text, "Press any key…")
	assert_eq(hold_label.text, OS.get_keycode_string(KEY_H), "an unrelated row shouldn't enter listening mode")


func test_pressing_an_unclaimed_key_applies_the_rebind() -> void:
	_menu.begin_rebind("order_stop")

	_menu._handle_rebind_key(_key_event(KEY_Z))

	assert_eq(InputMap.action_get_events("order_stop")[0].keycode, KEY_Z)
	var stop_label: Label = _menu._key_labels["order_stop"]
	assert_eq(stop_label.text, OS.get_keycode_string(KEY_Z))
	assert_eq(_menu._status_label.text, "")


func test_pressing_a_key_already_claimed_by_another_action_is_refused() -> void:
	_menu.begin_rebind("order_stop")

	_menu._handle_rebind_key(_key_event(KEY_H)) # order_hold's default key

	assert_eq(InputMap.action_get_events("order_stop")[0].keycode, KEY_S, "order_stop should keep its old binding")
	assert_ne(_menu._status_label.text, "", "should show a warning explaining the conflict")
	var stop_label: Label = _menu._key_labels["order_stop"]
	assert_eq(stop_label.text, OS.get_keycode_string(KEY_S), "should fall back out of listening mode")


func test_pressing_escape_cancels_a_pending_rebind_without_changing_anything() -> void:
	_menu.begin_rebind("order_stop")

	_menu._handle_rebind_key(_key_event(KEY_ESCAPE))

	assert_eq(InputMap.action_get_events("order_stop")[0].keycode, KEY_S)
	var stop_label: Label = _menu._key_labels["order_stop"]
	assert_eq(stop_label.text, OS.get_keycode_string(KEY_S))


func test_reset_button_restores_every_binding() -> void:
	Hotkeys.rebind("order_stop", KEY_Z)

	_menu._on_reset_pressed()

	assert_eq(InputMap.action_get_events("order_stop")[0].keycode, KEY_S)
	var stop_label: Label = _menu._key_labels["order_stop"]
	assert_eq(stop_label.text, OS.get_keycode_string(KEY_S))


## Doesn't exercise _on_back_pressed() itself (it calls
## change_scene_to_file(), which would tear down this test's own scene
## tree) -- just confirms the button is wired to it.
func test_back_button_is_wired_to_the_back_handler() -> void:
	assert_true(_menu._back_button.pressed.is_connected(_menu._on_back_pressed))
