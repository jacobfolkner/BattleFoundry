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
##                                Instant classic-mode placement (bypasses
##                                the economy entirely) -- unit:
##                                Tank/Fighter/Archer/BatRider/Giant/Hero.
##                                team: BLUE/RED.
##   --tournament                Activate Blood Tournament mode
##                                (GameManager.set_mode(BloodTournamentMode),
##                                cross map, starting gold) before
##                                --place/--buy/--battle run. Needed for
##                                anything economy/roster-shaped: gold
##                                display, roster row, hero ability draft
##                                panel, staggered deployment.
##   --buy=<unit>:<team>[;<unit>:<team>...]
##                                The real PLACEMENT-time roster purchase
##                                path (spends gold, appends to
##                                Player.roster) instead of instant
##                                placement -- only meaningful with
##                                --tournament first. Use this (not
##                                --place) to see the roster row/hero
##                                draft panel/staggered deployment.
##   --battle                    Call GameManager.start_battle() after
##                                placing/buying. Under --tournament,
##                                needs at least 2 teams with a non-empty
##                                roster (--buy, not --place, populates
##                                that) -- fires the same staggered
##                                deployment a real match uses.
##   --select=<index>            Select the Nth --place'd unit (0-based)
##                                via DebugInspector, opening the stats panel.
##                                Only applies to --place, not --buy
##                                (nothing is a live Unit to select until
##                                staggered deployment actually spawns it).
##   --ghost=<unit>:<x>,<y>,<z>   Arms the build-menu's placement ghost
##                                (Blue's) and moves it to the given world
##                                position, without confirming a purchase
##                                -- for eyeballing PlacementGhost's
##                                translucent/tinted material. Needs
##                                --tournament first.
##   --build_menu                 Opens the build-menu popup (WC3-style
##                                "click the Builder" panel) directly,
##                                without needing a real click -- for
##                                eyeballing its unit-type button icons.
##   --debug=<flag>[,<flag>...]  Enable DebugSettings flags by name
##                                (e.g. pathfinding,detailed_stats).
##   --leaderboard                Opens the leaderboard modal with 3 fake
##                                rows -- needs --tournament first (the
##                                HUD it's built into only exists once
##                                Main.tscn is loaded, which it always is,
##                                but this bypasses a real round entirely).
##   --faction=<Human|Orc|Beast>  Sets Blue's Player.faction and gates the
##                                build menu to it -- bypasses the real
##                                lobby picker (this tool's --tournament
##                                doesn't go through Main._apply_menu_selection()
##                                at all). Needs --tournament first.
##   --wait=<frames>             Physics frames to simulate before
##                                capturing. Default: 30. Staggered
##                                deployment's first roster slot deploys
##                                the instant battle starts (0s timer),
##                                but each slot after that waits another
##                                1s (60 frames) -- bump --wait accordingly
##                                to see more than one --buy'd slot deployed.
##
## Examples (see tools/screenshot.sh for the full command):
##   --place="Giant:BLUE:0,0,0;Fighter:RED:1,0,0" --battle --select=1 --debug=pathfinding --wait=20
##   --tournament --buy="Hero:BLUE;Tank:RED" --wait=10   (PLACEMENT screen: gold, roster row, hero draft panel)
##   --tournament --buy="Hero:BLUE;Tank:RED" --battle --wait=90   (mid-battle, staggered deployment settled)
##   --tournament --ghost="Tank:-4,0,-24"   (PlacementGhost armed and hovering inside Blue's courtyard)
extends Node3D

const UNIT_STATS := {
	"Tank": preload("res://Resources/Units/TankStats.tres"),
	"Fighter": preload("res://Resources/Units/FighterStats.tres"),
	"Archer": preload("res://Resources/Units/ArcherStats.tres"),
	"BatRider": preload("res://Resources/Units/BatRiderStats.tres"),
	"Giant": preload("res://Resources/Units/GiantStats.tres"),
	"Hero": preload("res://Resources/Units/HeroStats.tres"),
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

	if args.has("tournament"):
		# The real activation path (same one HUD's own toggle button
		# drives) -- grants starting gold, syncs the cross map, sets up
		# BloodTournamentMode, not a hand-rolled partial equivalent.
		main._on_tournament_toggled(true)
		await get_tree().physics_frame

	if args.has("build_menu"):
		main._hud.show_build_menu()

	var placed: Array[Unit] = []
	var place_spec: String = args.get("place", "")
	if place_spec != "":
		for spec in place_spec.split(";", false):
			var unit := _place_unit(spec)
			if unit != null:
				placed.append(unit)

	var buy_spec: String = args.get("buy", "")
	if buy_spec != "":
		for spec in buy_spec.split(";", false):
			_buy_for_roster(spec)
		main._refresh_gold_display() # pushes the purchase(s) onto the gold/roster-row/hero-draft-panel display -- nothing polls Player.roster on its own

	if args.has("battle"):
		GameManager.start_battle()

	var ghost_spec: String = args.get("ghost", "")
	if ghost_spec != "":
		_arm_ghost(main, ghost_spec)

	if args.has("debug"):
		for flag_name in String(args["debug"]).split(",", false):
			DebugSettings.set_enabled(flag_name.strip_edges(), true)

	if args.has("leaderboard"):
		_show_fake_leaderboard(main)

	var faction_name: String = args.get("faction", "")
	if faction_name != "":
		_set_blue_faction(main, faction_name)

	if args.has("select"):
		var index := int(args["select"])
		if index >= 0 and index < placed.size():
			DebugInspector.select(placed[index])
			# Also drives SelectionManager's own (green) ring, not just the
			# debug (yellow) one -- only takes if the unit belongs to
			# SelectionManager.local_player, same ownership rule real input goes through.
			SelectionManager.select_single(placed[index])
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
	var player: Player = _player_from_team_name(parts[1])
	var coords := parts[2].split(",")

	if stats == null or player == null or coords.size() != 3:
		push_warning("Skipping malformed --place entry (expected unit:team:x,y,z): " + spec)
		return null

	var position := Vector3(float(coords[0]), float(coords[1]), float(coords[2]))
	return GameManager.spawn_unit(stats, player, position)


## Same effect as GameManager.buy_roster_slot() (spend gold, append to
## Player.roster) via only Player's public API, deliberately NOT calling
## GameManager.sync_courtyard_to_roster() afterward -- this tool's own
## usage examples pair --buy with a PLACEMENT-screen screenshot (gold/
## roster row/hero draft panel), not a courtyard visual, so the roster
## staying data-only here matches what's actually being screenshotted.
func _buy_for_roster(spec: String) -> void:
	var parts := spec.split(":")
	if parts.size() != 2:
		push_warning("Skipping malformed --buy entry (expected unit:team): " + spec)
		return

	var stats: UnitStats = UNIT_STATS.get(parts[0])
	var player: Player = _player_from_team_name(parts[1])
	if stats == null or player == null:
		push_warning("Skipping malformed --buy entry (expected unit:team): " + spec)
		return

	if not player.can_afford(stats.cost):
		push_warning("Skipping --buy=%s: %s can't afford %s (%dg, has %dg) -- pass --tournament first for starting gold" % [spec, parts[1], parts[0], stats.cost, player.resources])
		return
	player.spend(stats.cost)
	player.roster.append(stats)


## Ad-hoc visual check for the leaderboard modal -- fabricated rows, not
## a real Blood Tournament round (triggering one via this tool would need
## a whole match's worth of setup). Bypasses BloodTournamentController
## entirely and calls HUD.show_tournament_score() directly.
## Ad-hoc visual check for race selection's build-menu gating -- bypasses
## the real lobby-picker -> Main._apply_menu_selection() flow (this
## tool's own --tournament just calls _on_tournament_toggled() directly,
## which never assigns a faction) and sets Blue's Player.faction/refreshes
## the build menu directly instead.
func _set_blue_faction(main: Node3D, faction_name: String) -> void:
	for faction in FactionRegistry.ALL:
		if faction.faction_name.to_lower() == faction_name.to_lower():
			GameManager.get_player(GameManager.BLUE_TEAM_ID).faction = faction
			main._hud.refresh_unit_panel_for_faction(faction)
			return
	push_warning("Unknown --faction=%s (expected Human/Orc/Beast)" % faction_name)


func _show_fake_leaderboard(main: Node3D) -> void:
	var hud: Control = main.get_node("HUDLayer/HUD")
	var rows: Array[Dictionary] = [
		{"team_id": 1, "display_name": "Red", "color": Color.RED, "wins": 3, "gold": 420, "kills": 12, "blood_points": 90},
		{"team_id": 0, "display_name": "Blue", "color": Color.BLUE, "wins": 2, "gold": 300, "kills": 7, "blood_points": 55},
		{"team_id": 2, "display_name": "Green", "color": Color.GREEN, "wins": 0, "gold": 300, "kills": 2, "blood_points": 10},
	]
	hud.show_tournament_score(4, rows)


func _arm_ghost(main: Node3D, spec: String) -> void:
	var parts := spec.split(":")
	if parts.size() != 2:
		push_warning("Skipping malformed --ghost entry (expected unit:x,y,z): " + spec)
		return

	var stats: UnitStats = UNIT_STATS.get(parts[0])
	var coords := parts[1].split(",")
	if stats == null or coords.size() != 3:
		push_warning("Skipping malformed --ghost entry (expected unit:x,y,z): " + spec)
		return

	var world_position := Vector3(float(coords[0]), float(coords[1]), float(coords[2]))
	# Courtyards sit far enough from the default camera focus (arena
	# center) that unproject_position()'s precision degrades near the
	# view frustum edge -- refocus onto the ghost point first, same fix
	# tests use for courtyard-area clicks.
	main._camera._focus_point = Vector3(world_position.x, 0.0, world_position.z)
	main._camera._update_transform()
	main._on_unit_type_selected(stats)
	main._try_move_mouse_to(main._camera.unproject_position(world_position))


func _player_from_team_name(team_name: String) -> Player:
	match team_name.to_upper():
		"BLUE": return GameManager.get_player(GameManager.BLUE_TEAM_ID)
		"RED": return GameManager.get_player(GameManager.RED_TEAM_ID)
		_: return null


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
