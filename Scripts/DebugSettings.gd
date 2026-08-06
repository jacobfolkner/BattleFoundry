## Named boolean debug-feature toggles, kept generic so adding a new one
## is a single dictionary entry -- no UI code to touch. UI/DebugMenu.gd
## renders one checkbox per registered flag with zero per-flag logic of
## its own, the same "generic renderer" pattern as UI/DebugPanel.gd.
##
## To add a new toggle: add a FLAG_* constant and a matching entry in
## _flags below, then gate whatever it controls with is_enabled(FLAG_*).
extends Node

signal flag_changed(flag_name: String, enabled: bool)

const FLAG_PATHFINDING := "pathfinding"
const FLAG_DETAILED_STATS := "detailed_stats"

var _flags: Dictionary = {
	FLAG_PATHFINDING: false,
	FLAG_DETAILED_STATS: false,
}


func is_enabled(flag_name: String) -> bool:
	return _flags.get(flag_name, false)


func set_enabled(flag_name: String, enabled: bool) -> void:
	if _flags.get(flag_name) == enabled:
		return
	_flags[flag_name] = enabled
	flag_changed.emit(flag_name, enabled)


func get_flag_names() -> Array:
	return _flags.keys()
