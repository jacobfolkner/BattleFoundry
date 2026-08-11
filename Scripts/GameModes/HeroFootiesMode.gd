## Wave-spawner + throne-HP game mode (roadmap Phase 6, "Hero Footies" --
## this project's second named target game after Blood Tournament, proving
## the engine's mode layer generalizes past it).
##
## Each side has one throne (Resources/Units/ThroneStats.tres -- a
## stationary, high-HP, never-attacks "building" expressed as an ordinary
## Unit rather than a new node type, so the entire combat/damage/death
## pipeline applies to it for free) at opposite ends of the plain square
## arena. The match is won by whichever team destroys the other's throne --
## wiping the enemy's manually placed army does NOT end the match by
## itself, only a throne dying does (see check_victory()).
##
## Placement stays exactly like ClassicEliminationMode's free-for-all
## (uses_economy() stays false): a player places any archetype, heroes
## included, anywhere on the arena, then commands their own units manually
## once BATTLE starts (is_auto_battle() also stays false -- unlike Blood
## Tournament, there IS a player at the controls here). Only the
## automatically-spawned Footman waves below march/fight on their own, via
## an explicit ATTACK_MOVE order issued at spawn time in _spawn_wave() --
## deliberately NOT routed through GameManager.spawn_unit()'s own
## auto-order hook, since that only fires under GameMode.is_auto_battle(),
## which this mode leaves false specifically so the human's own hero/army
## isn't auto-piloted too.
##
## Uses GameMode.tick() (called every physics frame from
## Main._physics_process(), regardless of which mode is active) for the
## wave timer, rather than a separate Node-based controller the way
## BloodTournamentController exists for Blood Tournament -- unlike that
## mode's orchestration, nothing here needs HUD/AIController access Main.gd
## would otherwise have to bridge in; spawning a wave is just
## GameManager.spawn_squad() plus an order, both already reachable from any
## GameMode the same way ClassicEliminationMode already reaches
## GameManager.team_is_empty().
class_name HeroFootiesMode
extends GameMode

const THRONE_STATS: UnitStats = preload("res://Resources/Units/ThroneStats.tres")
const WAVE_STATS: UnitStats = preload("res://Resources/Units/FootmanStats.tres")

## Inward from each edge along the arena's own Z axis -- keeps both
## thrones comfortably inside GameManager.ARENA_HALF_EXTENT (so
## Unit._clamp_to_arena() never has to fight the spawn position) while
## still sitting near the map's two opposite ends, one lane down the
## middle, same as the reference genre's own base placement.
const _THRONE_INSET := 3.0
var blue_throne_position: Vector3 = Vector3(0, 0, -(GameManager.ARENA_HALF_EXTENT - _THRONE_INSET))
var red_throne_position: Vector3 = Vector3(0, 0, GameManager.ARENA_HALF_EXTENT - _THRONE_INSET)

## Seconds between automatic wave spawns per side -- nowhere near a tuned
## balance number, just long enough to read as a real pulse rather than a
## constant stream. A var, not a const, purely so a test can shrink it
## instead of waiting out real time (same reasoning GameManager.STALEMATE_TIMEOUT
## already uses).
var wave_interval := 20.0

var blue_throne: Unit = null
var red_throne: Unit = null
var _wave_timer: float = 0.0


## Spawns both thrones once BATTLE actually starts -- not on_activated()
## the way Blood Tournament's starting gold is granted there, since
## nothing during PLACEMENT reads throne existence at all (unlike gold,
## which has to already be spendable before the first PLACEMENT phase).
## on_battle_started() is comfortably after GameManager.units_container is
## set (Main._ready()), which spawn_unit() requires.
func on_battle_started() -> void:
	blue_throne = GameManager.spawn_unit(THRONE_STATS, GameManager.get_player(GameManager.BLUE_TEAM_ID), blue_throne_position)
	red_throne = GameManager.spawn_unit(THRONE_STATS, GameManager.get_player(GameManager.RED_TEAM_ID), red_throne_position)
	_wave_timer = wave_interval # first wave arrives after one interval, not instantly -- gives both players a moment to reposition their own units first


func on_battle_ended(_winning_team_id: int, _is_draw: bool) -> void:
	blue_throne = null
	red_throne = null


## Whichever throne is destroyed loses -- checked directly against the
## throne references, not GameManager.team_is_empty() (which only tracks
## ordinary Units, same as ClassicEliminationMode's own check) -- a
## placed hero or wave unit dying should never end the match on its own,
## only a throne dying should. Both thrones going down on the exact same
## damage tick reads as a draw, the same convention every other GameMode
## in this project already uses for a simultaneous wipe.
func check_victory() -> Dictionary:
	var blue_alive := is_instance_valid(blue_throne) and blue_throne.life_state == Unit.LifeState.ALIVE
	var red_alive := is_instance_valid(red_throne) and red_throne.life_state == Unit.LifeState.ALIVE
	if not blue_alive and not red_alive:
		return {"result": VictoryResult.DRAW}
	if not blue_alive:
		return {"result": VictoryResult.TEAM_WON, "winning_team_id": GameManager.RED_TEAM_ID}
	if not red_alive:
		return {"result": VictoryResult.TEAM_WON, "winning_team_id": GameManager.BLUE_TEAM_ID}
	return {"result": VictoryResult.NONE}


## The wave-spawner: every wave_interval seconds during BATTLE, each side
## gets a fresh Footman squad from its own throne, sent marching straight
## at the enemy throne. ATTACK_MOVE (not plain MOVE) so a wave still fights
## anything -- the enemy's own placed army included -- it meets along the
## way, not just once it reaches the throne itself.
func tick(delta: float) -> void:
	if not GameManager.is_battle_active():
		return
	_wave_timer -= delta
	if _wave_timer > 0.0:
		return
	_wave_timer = wave_interval
	_spawn_wave(GameManager.BLUE_TEAM_ID, blue_throne_position, red_throne_position)
	_spawn_wave(GameManager.RED_TEAM_ID, red_throne_position, blue_throne_position)


func _spawn_wave(team_id: int, from_position: Vector3, to_position: Vector3) -> void:
	var player := GameManager.get_player(team_id)
	var squad := GameManager.spawn_squad(WAVE_STATS, player, from_position)
	for unit in squad:
		unit.order_attack_move(to_position)
