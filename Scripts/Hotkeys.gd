## Registers this project's hotkeys as real Godot InputMap actions at
## boot, instead of every input-handling script comparing an
## InputEventKey's .keycode against a raw literal directly -- roadmap
## Phase 3's "rebindable hotkeys" item. rebind() below is the actual
## mechanism a future remapping screen would call into (Phase 10's
## still-open "settings/keybind remapping" item, a distinct and larger
## piece of work: persistence, a settings UI, conflict detection) --
## this autoload only proves the underlying framework works, it doesn't
## expose rebinding to the player yet.
##
## Deliberately does NOT cover every key this project reads: Shift
## (box-select/queue modifier), Ctrl (control-group-assign modifier),
## Escape (cancel), and the 1-9 digit keys (control groups, where the
## digit itself IS the group number -- remapping "group 3" onto a
## non-digit key would be actively confusing) all stay direct keycode/
## modifier checks in PlayerInputController.gd, same as before. Only
## keys that map to a genuinely nameable player action are registered
## here.
extends Node

## action_name -> the InputEventKey default this project ships with.
## Matches PlayerInputController.gd's/OrbitCamera.gd's existing key
## layout exactly -- see each one's own doc comment for why a specific
## key was picked (e.g. arrow keys over WASD for camera pan, to avoid
## colliding with W = ability slot 1).
const DEFAULT_BINDINGS := {
	"order_stop": KEY_S,
	"order_hold": KEY_H,
	"ability_slot_0": KEY_Q,
	"ability_slot_1": KEY_W,
	"ability_slot_2": KEY_E,
	"buy_upgrade_0": KEY_U,
	"buy_upgrade_1": KEY_I,
	"camera_pan_up": KEY_UP,
	"camera_pan_down": KEY_DOWN,
	"camera_pan_left": KEY_LEFT,
	"camera_pan_right": KEY_RIGHT,
	"jump_to_hero": KEY_SPACE,
}

## Player-facing label for each action, shown by Scripts/SettingsMenu.gd
## (Phase 10's remap screen) -- the snake_case action_name strings above
## are InputMap-internal, not fit to show a player directly.
const ACTION_DISPLAY_NAMES := {
	"order_stop": "Stop",
	"order_hold": "Hold Position",
	"ability_slot_0": "Ability Slot 1",
	"ability_slot_1": "Ability Slot 2",
	"ability_slot_2": "Ability Slot 3",
	"buy_upgrade_0": "Buy Upgrade 1",
	"buy_upgrade_1": "Buy Upgrade 2",
	"camera_pan_up": "Camera Pan Up",
	"camera_pan_down": "Camera Pan Down",
	"camera_pan_left": "Camera Pan Left",
	"camera_pan_right": "Camera Pan Right",
	"jump_to_hero": "Jump to Hero",
}


func _ready() -> void:
	for action_name in DEFAULT_BINDINGS:
		_ensure_action_exists(action_name, DEFAULT_BINDINGS[action_name])


func _ensure_action_exists(action_name: String, default_keycode: Key) -> void:
	if InputMap.has_action(action_name):
		return
	InputMap.add_action(action_name)
	var event := InputEventKey.new()
	event.keycode = default_keycode
	InputMap.action_add_event(action_name, event)


## Replaces every event bound to `action_name` with a single
## InputEventKey for `new_keycode` -- the actual "rebind" operation.
## Registers the action first (via its own DEFAULT_BINDINGS entry, if
## it has one) if it doesn't exist yet -- defensive only; _ready()
## should already have covered every action this project defines.
func rebind(action_name: String, new_keycode: Key) -> void:
	if not InputMap.has_action(action_name):
		InputMap.add_action(action_name)
	InputMap.action_erase_events(action_name)
	var event := InputEventKey.new()
	event.keycode = new_keycode
	InputMap.action_add_event(action_name, event)


func display_name(action_name: String) -> String:
	return ACTION_DISPLAY_NAMES.get(action_name, action_name)


## Returns the OTHER action already bound to `keycode` among this
## project's own rebindable actions (DEFAULT_BINDINGS.keys() -- the only
## ones this autoload ever registers), or "" if none claim it.
## `excluding_action` is the action actually being rebound -- rebinding
## it to the key it already holds shouldn't read as a conflict with
## itself. Used by Scripts/SettingsMenu.gd to refuse a rebind that would
## silently make two actions fire off the same key, rather than letting
## InputMap.action_add_event() just add a second claimant with no warning.
func find_conflicting_action(excluding_action: String, keycode: Key) -> String:
	for action_name in DEFAULT_BINDINGS:
		if action_name == excluding_action:
			continue
		for event in InputMap.action_get_events(action_name):
			if event is InputEventKey and (event as InputEventKey).keycode == keycode:
				return action_name
	return ""


## Restores every action this autoload registers back to its
## DEFAULT_BINDINGS keycode -- Scripts/SettingsMenu.gd's "Reset to
## Defaults" button.
func reset_to_defaults() -> void:
	for action_name in DEFAULT_BINDINGS:
		rebind(action_name, DEFAULT_BINDINGS[action_name])
