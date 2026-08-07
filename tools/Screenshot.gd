## Ad-hoc screenshot generator for manual/visual validation -- NOT run in
## CI, invoke via tools/screenshot.sh only. Boots the real Main scene,
## optionally places units / starts a battle / selects a unit for the
## debug inspector / enables debug-menu flags, waits for physics to
## settle, and saves a PNG. Exists so validating a change doesn't mean
## writing a new throwaway driver script from scratch each time (this is
## that throwaway pattern, productized).
##
## Which renderer is used (fast-but-dark vs. slow-but-accurate lighting)
## is screenshot.sh's own --renderer flag, not an option here -- see
## that file. Scene-setup options below are everything after "--":
##
## Options (all optional, passed after "--"):
##   --out=<filename>            Output filename, always saved inside the
##                                gitignored screenshots/ dir. Default: screenshot.png
##   --place=<unit>:<team>:<x>,<y>,<z>[;<unit>:<team>:<x>,<y>,<z>...]
##                                unit: Tank/Fighter/Archer/BatRider/Giant
##                                team: BLUE/RED
##   --battle                    Call GameManager.start_battle() after placing.
##   --select=<index>            Select the Nth --place'd unit (0-based)
##                                via DebugInspector, opening the stats panel.
##   --debug=<flag>[,<flag>...]  Enable DebugSettings flags by name
##                                (e.g. pathfinding,detailed_stats).
##   --wait=<frames>             Physics frames to simulate before
##                                capturing. Default: 30.
##
## Example (see tools/screenshot.sh for the full command):
##   --place="Giant:BLUE:0,0,0;Fighter:RED:1,0,0" --battle --select=1 --debug=pathfinding --wait=20
extends Node3D

const UNIT_STATS := {
	"Tank": preload("res://Resources/TankStats.tres"),
	"Fighter": preload("res://Resources/FighterStats.tres"),
	"Archer": preload("res://Resources/ArcherStats.tres"),
	"BatRider": preload("res://Resources/BatRiderStats.tres"),
	"Giant": preload("res://Resources/GiantStats.tres"),
}

const TEAMS := {
	"BLUE": Team.Type.BLUE,
	"RED": Team.Type.RED,
}

const SCREENSHOT_DIR := "res://screenshots"
const DEFAULT_OUT := "screenshot.png"
const DEFAULT_WAIT_FRAMES := 30


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	var args := _parse_args()

	var main: Node3D = load("res://Scenes/Main.tscn").instantiate()
	add_child(main)
	await get_tree().physics_frame

	var placed: Array[Unit] = []
	var place_spec: String = args.get("place", "")
	if place_spec != "":
		for spec in place_spec.split(";", false):
			var unit := _place_unit(spec)
			if unit != null:
				placed.append(unit)

	if args.has("battle"):
		GameManager.start_battle()

	if args.has("debug"):
		for flag_name in String(args["debug"]).split(",", false):
			DebugSettings.set_enabled(flag_name.strip_edges(), true)

	if args.has("select"):
		var index := int(args["select"])
		if index >= 0 and index < placed.size():
			DebugInspector.select(placed[index])
		else:
			push_warning("--select=%d out of range (%d units placed)" % [index, placed.size()])

	var wait_frames := int(args.get("wait", DEFAULT_WAIT_FRAMES))
	for i in range(wait_frames):
		await get_tree().physics_frame
	await get_tree().process_frame # let UI (debug menu/panel) layout settle

	_save_screenshot(String(args.get("out", DEFAULT_OUT)))
	get_tree().quit()


func _place_unit(spec: String) -> Unit:
	var parts := spec.split(":")
	if parts.size() != 3:
		push_warning("Skipping malformed --place entry (expected unit:team:x,y,z): " + spec)
		return null

	var stats: UnitStats = UNIT_STATS.get(parts[0])
	var team: Variant = TEAMS.get(parts[1].to_upper())
	var coords := parts[2].split(",")

	if stats == null or team == null or coords.size() != 3:
		push_warning("Skipping malformed --place entry (expected unit:team:x,y,z): " + spec)
		return null

	var position := Vector3(float(coords[0]), float(coords[1]), float(coords[2]))
	return GameManager.spawn_unit(stats, team, position)


func _save_screenshot(filename: String) -> void:
	var out_path := SCREENSHOT_DIR.path_join(filename)
	DirAccess.make_dir_recursive_absolute(out_path.get_base_dir())
	var image := get_viewport().get_texture().get_image()
	var err := image.save_png(out_path)
	if err != OK:
		push_error("Failed to save screenshot to %s: error %d" % [out_path, err])
		return
	print("SCREENSHOT_SAVED: ", ProjectSettings.globalize_path(out_path))


## "--key=value" -> {"key": "value"}. A bare "--flag" (no "=") stores
## `true`, for presence-only options like --battle.
func _parse_args() -> Dictionary:
	var args := {}
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--"):
			arg = arg.substr(2)
		var eq := arg.find("=")
		if eq == -1:
			args[arg] = true
		else:
			args[arg.substr(0, eq)] = arg.substr(eq + 1)
	return args
