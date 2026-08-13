## THROWAWAY test tool (matches this project's existing precedent of
## deleting ad-hoc verification drivers once they've answered their
## question -- see BattleFoundry-Roadmap.md's flying-and-knockback notes)
## -- proves Phase C's lockstep networking actually works: two
## `godot --headless` processes (one host, one client) connect via ENet
## over loopback, spawn an identical scripted battle, each issues its OWN
## local order (which must cross the real CommandQueue/NetworkSession
## relay to reach the other side), run for N ticks, and each writes its
## own final state trace -- byte-identical traces after both exit is the
## actual proof. Same shape as DeterminismCheck.gd's own single-process
## harness (Phase A/A2), extended to a real 2-process networked test.
##
## Usage:
##   godot --headless res://tools/NetworkPlaytest.tscn -- --host --port=9999 --out=/path/host_trace.txt --ticks=200
##   godot --headless res://tools/NetworkPlaytest.tscn -- --join=127.0.0.1 --port=9999 --out=/path/client_trace.txt --ticks=200
extends Node3D

const TANK_STATS: UnitStats = preload("res://Resources/Units/TankStats.tres")
const FIGHTER_STATS: UnitStats = preload("res://Resources/Units/FighterStats.tres")

var _spawned: Array[Unit] = []


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	var args := _parse_args()
	var port := int(args.get("port", 9999))
	var out_path: String = args.get("out", "/tmp/network_trace.txt")
	var ticks := int(args.get("ticks", 200))
	var is_host := args.has("host")

	SimRng.seed_match(999)

	# Connect BEFORE Main.tscn is even loaded, not after -- Main's own
	# _physics_process() starts advancing GameManager.current_tick from
	# its very first real frame, and can_advance_to_tick() vacuously
	# passes while NetworkSession.peer_ids is still empty (correct for
	# genuine single-machine play, where there's nothing to gate on).
	# Loading Main before the peer connects means each side free-runs its
	# own tick counter solo for however long its own connection handshake
	# happens to take -- found empirically: a 3s launch stagger left the
	# host at tick 191 and the client at tick 15 by the time both finally
	# saw each other, so "tick 15" meant two completely unrelated
	# simulation moments and checksums correctly reported them as
	# diverged. A real lobby wouldn't load the match scene before every
	# expected player is present either, so this fix matches both the
	# test's needs and the actual intended architecture.
	var connect_err: Error
	if is_host:
		connect_err = NetworkSession.host(port)
	else:
		connect_err = NetworkSession.join(args.get("join", "127.0.0.1"), port)
	if connect_err != OK:
		printerr("CONNECT_FAILED: ", connect_err)
		get_tree().quit(1)
		return

	while NetworkSession.peer_ids.is_empty():
		await get_tree().physics_frame

	var main: Node3D = load("res://Scenes/Main.tscn").instantiate()
	add_child(main)
	await get_tree().physics_frame

	var blue := GameManager.get_player(GameManager.BLUE_TEAM_ID)
	var red := GameManager.get_player(GameManager.RED_TEAM_ID)
	# Identical deterministic bootstrap on both processes -- direct
	# spawn_unit() calls, not through the Command layer, same reasoning
	# DeterminismCheck.gd's own harness relies on: both sides run the
	# exact same code from the exact same seed, so this part needs no
	# synchronization at all.
	for i in 5:
		_spawned.append(GameManager.spawn_unit(TANK_STATS, blue, Vector3(-10.0 + i * 1.6, 0, 0)))
	for i in 5:
		_spawned.append(GameManager.spawn_unit(FIGHTER_STATS, red, Vector3(10.0 - i * 1.6, 0, 0)))

	# Routed through the Command layer (like a real player pressing
	# "start battle" would be -- BloodTournamentController.start_battle_pressed()'s
	# own human-triggered branch does the same), NOT called directly on
	# each process independently. GameManager.battle_state gates every
	# unit's own auto-seek-nearest-enemy AI (Unit._physics_process()'s
	# is_battling branch) -- calling start_battle() locally on both sides
	# would flip that gate at two different real-world moments (whenever
	# each process's own coroutine happened to reach this line), meaning
	# 9 of this test's 10 units (everyone except the one explicit move
	# order below) would start their AI-driven movement at different
	# absolute ticks on host vs client. Found exactly this way: tick 0/1
	# traced byte-identical, every tick after diverged, and the two
	# processes' local start_battle() calls were the one piece of match
	# setup that wasn't going through the relay at all. Only the host
	# enqueues it -- one Command, replicated to both sides, applied at
	# the same absolute tick on each, exactly like everything else here.
	if is_host:
		var start_command := Command.new()
		start_command.type = Command.Type.START_BATTLE
		start_command.team_id = blue.team_id
		CommandQueue.enqueue(start_command)

	# One local order each, issued through the SAME CommandQueue.enqueue()
	# path a real click would use -- this is the part that actually has
	# to survive the network relay for this test to mean anything.
	if is_host:
		_issue_move_order(_spawned[0], Vector3(5, 0, 5))
	else:
		_issue_move_order(_spawned[6], Vector3(-5, 0, -5))

	var file := FileAccess.open(out_path, FileAccess.WRITE)
	for i in ticks:
		await get_tree().physics_frame
		file.store_line(_tick_signature(i))
	file.close()

	print("NETWORK_TRACE_WRITTEN: ", out_path)
	get_tree().quit()


func _issue_move_order(unit: Unit, target: Vector3) -> void:
	var command := Command.new()
	command.type = Command.Type.UNIT_ORDER
	command.team_id = unit.player.team_id
	command.unit_net_id = unit.net_id
	command.order_type = Unit.OrderType.MOVE
	command.target_position = target
	CommandQueue.enqueue(command)


## Real tick count (GameManager.current_tick), not the raw frame index --
## the stall gate means these can diverge under real latency, and the
## whole point of this trace is to prove both peers end up applying the
## SAME commands at the SAME tick, not just after the same number of real
## frames.
func _tick_signature(frame: int) -> String:
	var parts: PackedStringArray = ["f%d" % frame, "tick%d" % GameManager.current_tick]
	for unit in _spawned:
		if not is_instance_valid(unit):
			parts.append("DEAD")
			continue
		var pos := unit.global_position
		parts.append("%.6f,%.6f,%.6f|%.4f" % [pos.x, pos.y, pos.z, unit.current_health])
	return " ".join(parts)


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
