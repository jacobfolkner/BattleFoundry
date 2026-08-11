## Headless perf benchmark -- roadmap Phase 10's "headless perf benchmark
## at 200/500 units in CI" item. Boots the real Main scene (same as
## tools/Screenshot.gd), spawns `units` total units split evenly across
## Blue/Red in classic mode, starts a real battle, then measures wall-clock
## time per physics frame over `frames` frames of actual combat (pathing,
## avoidance, targeting, attacks -- not just idle units standing still).
## Prints a plain report to stdout; not a pass/fail gate (perf varies by
## machine), just a repeatable number a human (or a future CI step) can
## compare run to run.
##
## Usage (see tools/benchmark.sh):
##   tools/benchmark.sh --units=200
##   tools/benchmark.sh --units=500 --frames=600
extends Node3D

const TANK_STATS: UnitStats = preload("res://Resources/Units/TankStats.tres")
const FIGHTER_STATS: UnitStats = preload("res://Resources/Units/FighterStats.tres")

const DEFAULT_UNITS := 200
const DEFAULT_FRAMES := 300
## How far apart adjacent units in the spawn grid start, in meters --
## loose enough that avoidance has real (but not degenerate/fully-
## overlapping) work to do sorting them out into combat by default.
## Override with --spacing to test a more spread-out battle (e.g. 8
## teams starting at different cross-map arms, not one dense clump) --
## GameManager.find_nearest_enemy()'s spatial-grid optimization's actual
## payoff is scenario-dependent: a tightly clustered fight (the default)
## doesn't reduce candidates much per query since most units are already
## "nearby" regardless; spreading units out shows the real win.
const DEFAULT_SPACING := 1.6


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	var args := _parse_args()
	var unit_count := int(args.get("units", DEFAULT_UNITS))
	var frame_count := int(args.get("frames", DEFAULT_FRAMES))
	var spacing := float(args.get("spacing", DEFAULT_SPACING))

	var main: Node3D = load("res://Scenes/Main.tscn").instantiate()
	add_child(main)
	await get_tree().physics_frame

	var blue := GameManager.get_player(GameManager.BLUE_TEAM_ID)
	var red := GameManager.get_player(GameManager.RED_TEAM_ID)
	var half := unit_count / 2
	_spawn_grid(TANK_STATS, blue, half, -1.0, spacing)
	_spawn_grid(FIGHTER_STATS, red, unit_count - half, 1.0, spacing)

	GameManager.start_battle()
	await get_tree().physics_frame # let the first real combat frame run before timing starts

	var worst_frame_usec := 0
	var start_usec := Time.get_ticks_usec()
	for i in frame_count:
		var frame_start_usec := Time.get_ticks_usec()
		await get_tree().physics_frame
		var frame_usec := Time.get_ticks_usec() - frame_start_usec
		worst_frame_usec = maxi(worst_frame_usec, frame_usec)
	var total_usec := Time.get_ticks_usec() - start_usec

	var avg_ms := (total_usec / float(frame_count)) / 1000.0
	print("BENCHMARK: %d units (%d Tank/Blue, %d Fighter/Red), %d physics frames" % [unit_count, half, unit_count - half, frame_count])
	print("  total: %.2fs" % (total_usec / 1_000_000.0))
	print("  avg frame: %.3fms (%.1f FPS-equivalent)" % [avg_ms, 1000.0 / avg_ms if avg_ms > 0.0 else 0.0])
	print("  worst frame: %.3fms" % (worst_frame_usec / 1000.0))
	get_tree().quit()


## A square-ish grid centered at x_sign*12 (well inside GameManager.ARENA_HALF_EXTENT's
## 20m bound, leaving room for the grid's own footprint) -- the two
## teams' grids start apart, not overlapping, but close enough that
## real combat (not just idle standing) happens well within `frames`.
## `spacing` isn't clamped to fit inside the arena bound -- a large
## --spacing at a high --units will spill past ARENA_HALF_EXTENT and get
## squashed back in by Unit's own per-frame arena clamp, which just
## produces a denser-than-requested spread rather than an error; fine for
## this tool's own comparative purpose (this run vs. that run), not meant
## to guarantee an exact footprint.
func _spawn_grid(stats: UnitStats, player: Player, count: int, x_sign: float, spacing: float) -> void:
	var columns := ceili(sqrt(count))
	for i in count:
		var col := i % columns
		var row := i / columns
		var position := Vector3(x_sign * 12.0 + col * spacing, 0, (row - columns * 0.5) * spacing)
		GameManager.spawn_unit(stats, player, position)


## Same "--key=value" -> {"key": "value"} parsing as tools/Screenshot.gd.
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
