## Schedules every player/AI-originated Command (Scripts/Core/Command.gd)
## for a future physics tick instead of applying it immediately -- part of
## the D1 multiplayer plan (BattleFoundry-Roadmap.md). Main._physics_process()
## drains and applies each tick's own batch, right before ticking the
## current GameMode, so the whole pipeline (enqueue now, apply on a later
## tick, tick the mode) already matches the shape a real networked peer's
## commands will need to slot into later -- nothing about this autoload
## itself changes once Phase C adds a second, remote command source.
##
## DEFAULT_INPUT_DELAY_TICKS is 1, not a real network-latency buffer --
## there's no peer to buffer against yet. It's just enough to make
## "enqueue now, apply next tick" an unambiguous pipeline instead of a
## same-frame ordering question. Phase C tunes this up once real latency
## exists to hide.
##
## Within one tick's batch, commands apply in enqueue (append) order --
## deterministic today since there's exactly one input source on this
## machine. Merging multiple peers' batches into one deterministic order
## is an explicit, not-yet-solved Phase C problem.
extends Node

const DEFAULT_INPUT_DELAY_TICKS := 1

var _scheduled: Dictionary = {} # tick: int -> Array[Command]


func enqueue(command: Command, delay_ticks: int = DEFAULT_INPUT_DELAY_TICKS) -> void:
	var apply_tick := Engine.get_physics_frames() + delay_ticks
	if not _scheduled.has(apply_tick):
		_scheduled[apply_tick] = []
	_scheduled[apply_tick].append(command)


## Called once per physics frame, before the current tick's GameMode.tick()
## -- drains and applies whatever was scheduled to land THIS tick, if
## anything (most ticks have nothing scheduled). Returns whether anything
## was actually applied, so Main.gd knows whether an economy-relevant HUD
## refresh is worth doing this frame.
func apply_scheduled_commands_for_this_tick() -> bool:
	var tick := Engine.get_physics_frames()
	if not _scheduled.has(tick):
		return false
	var commands: Array = _scheduled[tick]
	_scheduled.erase(tick)
	for command in commands:
		GameManager.apply_command(command)
	return not commands.is_empty()
