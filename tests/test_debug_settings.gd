extends GutTest

func after_each() -> void:
	DebugSettings.set_enabled(DebugSettings.FLAG_PATHFINDING, false)


func test_flag_defaults_to_disabled() -> void:
	assert_false(DebugSettings.is_enabled(DebugSettings.FLAG_PATHFINDING))


func test_set_enabled_roundtrips() -> void:
	DebugSettings.set_enabled(DebugSettings.FLAG_PATHFINDING, true)
	assert_true(DebugSettings.is_enabled(DebugSettings.FLAG_PATHFINDING))


func test_set_enabled_emits_signal_only_on_change() -> void:
	var emit_count := [0] # array, not int -- GDScript lambdas capture locals by value
	var listener := func(_name, _enabled): emit_count[0] += 1
	DebugSettings.flag_changed.connect(listener)

	DebugSettings.set_enabled(DebugSettings.FLAG_PATHFINDING, true)
	DebugSettings.set_enabled(DebugSettings.FLAG_PATHFINDING, true) # no-op, same value

	DebugSettings.flag_changed.disconnect(listener)
	assert_eq(emit_count[0], 1)


func test_unknown_flag_defaults_to_disabled() -> void:
	assert_false(DebugSettings.is_enabled("does_not_exist"))
