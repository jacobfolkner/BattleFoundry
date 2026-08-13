## Schedules every player/AI-originated Command (Scripts/Core/Command.gd)
## for a future simulation tick instead of applying it immediately, and
## (once NetworkSession has an active session) relays each tick's own
## batch to every connected peer -- part of the D1 multiplayer plan
## (BattleFoundry-Roadmap.md). Main._physics_process() drains and applies
## each tick's own batch, right before ticking the current GameMode.
##
## Local-only (no peers): behaves exactly as it did before Phase C --
## nothing to wait on, `can_advance_to_tick()` is vacuously always true,
## the relay broadcast is a no-op.
##
## Networked: real lockstep. Every peer, once per LOCAL tick it advances,
## sends exactly ONE message to every other peer -- "here's my batch for
## tick current_tick + delay_ticks" -- even when that batch is empty.
## Sending unconditionally, every tick, is what lets a receiver tell
## "confirmed nothing this tick" apart from "haven't heard yet"; without
## that, an empty tick and a not-yet-arrived tick would be
## indistinguishable and the stall gate below couldn't work at all.
## `_confirmed_tick_by_peer` only needs to track the LATEST tick heard
## from each peer, not fill in gaps -- ENet's default channel (used by
## Godot's own @rpc calls here) is reliable and ordered, so a message for
## tick T arriving means every message for that peer's ticks before T
## already arrived too.
##
## DEFAULT_INPUT_DELAY_TICKS (1) is still a LOCAL convenience value, not
## a real network-latency buffer -- Phase C's own first cut hasn't tuned
## this against real measured latency yet; a real deploy would want this
## large enough that a peer's own broadcast for tick T reliably arrives
## before local simulation reaches tick T, so the stall gate rarely
## actually fires in practice (occasional stalls are correct/expected
## under real jitter, not a bug -- see Main._physics_process()'s own
## comment on the gate).
extends Node

const DEFAULT_INPUT_DELAY_TICKS := 1

var _scheduled: Dictionary = {} # tick: int -> Array[Command]
var _confirmed_tick_by_peer: Dictionary = {} # peer_id: int -> highest tick confirmed
var _last_broadcast_target_tick: int = -1
var _last_broadcast_command_count: int = -1


func _ready() -> void:
	# Keeps receiving/relaying while GameManager's own simulation is
	# paused (see Main._physics_process()'s stall gate) -- the whole
	# point of pausing is to wait for exactly the messages this autoload
	# is responsible for receiving, so it can't itself be paused too.
	process_mode = Node.PROCESS_MODE_ALWAYS


func enqueue(command: Command, delay_ticks: int = DEFAULT_INPUT_DELAY_TICKS) -> void:
	_schedule(command, GameManager.current_tick + delay_ticks)


func _schedule(command: Command, apply_tick: int) -> void:
	if not _scheduled.has(apply_tick):
		_scheduled[apply_tick] = []
	_scheduled[apply_tick].append(command)


## Called once per physics frame, before the current tick's GameMode.tick()
## -- drains and applies whatever was scheduled to land THIS tick, if
## anything (most ticks have nothing scheduled). Returns whether anything
## was actually applied, so Main.gd knows whether an economy-relevant HUD
## refresh is worth doing this frame.
func apply_scheduled_commands_for_this_tick() -> bool:
	var tick := GameManager.current_tick
	if not _scheduled.has(tick):
		return false
	var commands: Array = _scheduled[tick]
	_scheduled.erase(tick)
	# A tick's batch can contain one command enqueued locally plus others
	# that arrived via CommandQueue's RPC relay -- their relative order in
	# this array reflects arrival order, which real network jitter makes
	# no two peers guaranteed to agree on. Sorting by content before
	# applying means every peer with the same SET of commands for this
	# tick applies them in the same ORDER regardless of who happened to
	# hear about which one first -- found to matter empirically (2-
	# instance trace-and-diff harness showed positions meaningfully
	# diverging by tick 100 even after fixing the earlier deadlock/skew
	# bugs, traced to this).
	commands.sort_custom(func(a: Command, b: Command) -> bool:
		if a.team_id != b.team_id:
			return a.team_id < b.team_id
		return a.unit_net_id < b.unit_net_id)
	for command in commands:
		GameManager.apply_command(command)
	return not commands.is_empty()


## Broadcasts THIS peer's own batch for `target_tick` (whatever's been
## locally enqueued into it so far) to every connected peer -- called
## every real physics frame from Main._physics_process() (unconditionally,
## even while stalled -- see Main.gd's own comment on why the broadcast
## can't be gated behind the stall it's meant to resolve).
##
## Skips re-sending when nothing's actually changed since the last call
## (same target_tick, same pending command count) -- while stalled,
## target_tick stays fixed for many consecutive real frames, and resending
## an identical reliable RPC every single one of those frames turned out
## to be a real bug, not just wasteful: the growing backlog of redundant
## reliable-channel traffic measurably delayed the very confirmations that
## would have ended the stall, compounding into a steadily growing
## divergence rather than a bounded startup blip (found via the 2-instance
## trace-and-diff harness -- host would pull further ahead of client every
## frame instead of the two settling into lockstep). Still re-sends
## whenever the pending tick's command count changes (a new local command
## can legitimately get enqueued into an already-broadcast, still-pending
## tick mid-stall, and that has to reach the peer).
func broadcast_local_batch_for_tick(target_tick: int) -> void:
	if not NetworkSession.is_active():
		return
	var commands: Array = _scheduled.get(target_tick, [])
	if target_tick == _last_broadcast_target_tick and commands.size() == _last_broadcast_command_count:
		return
	_last_broadcast_target_tick = target_tick
	_last_broadcast_command_count = commands.size()
	var serialized: Array = commands.map(func(c: Command) -> Dictionary: return c.to_dict())
	for peer_id in NetworkSession.peer_ids:
		_receive_batch.rpc_id(peer_id, target_tick, serialized)


@rpc("any_peer", "call_remote", "reliable")
func _receive_batch(for_tick: int, serialized_commands: Array) -> void:
	var sender_id := multiplayer.get_remote_sender_id()
	for data in serialized_commands:
		_schedule(Command.from_dict(data), for_tick)
	_confirmed_tick_by_peer[sender_id] = for_tick


## True once every connected peer has confirmed `tick` (an empty batch
## still counts as confirmed -- see this file's own doc comment for why
## that distinction matters). Local-only matches (NetworkSession.peer_ids
## empty) are vacuously always true here, so this never changes
## single-machine behavior.
## Ticks before DEFAULT_INPUT_DELAY_TICKS are never actually broadcast by
## anyone (the earliest any peer ever broadcasts for is tick 0 + delay),
## so there's nothing to wait on yet -- without this bootstrap case,
## can_advance_to_tick(0) would never see a confirmation and every
## networked match would stall permanently at tick 0. Empirically (2-
## instance trace-and-diff harness) removing this bootstrap entirely made
## startup skew WORSE, not better -- keep it, and keep
## DEFAULT_INPUT_DELAY_TICKS small (widening it widens this same
## unconfirmed bootstrap window, also empirically worse).
func can_advance_to_tick(tick: int) -> bool:
	if tick < DEFAULT_INPUT_DELAY_TICKS:
		return true
	for peer_id in NetworkSession.peer_ids:
		if _confirmed_tick_by_peer.get(peer_id, -1) < tick:
			return false
	return true


## Set exactly once per real physics frame, by Main._physics_process()
## itself (guaranteed to run first -- see Main.gd's own
## process_physics_priority), capturing whatever can_advance_to_tick()
## verdict Main just acted on for THIS frame. Unit._physics_process()
## reads this instead of re-calling can_advance_to_tick() itself, which
## matters: Main increments GameManager.current_tick near the end of its
## own (unstalled) frame, so a Unit re-deriving the check afterward, in
## the SAME real frame, would be asking about the tick AFTER the one Main
## just successfully processed -- a tick that essentially never has its
## own confirmation in yet, making the re-derived check read as
## permanently stalled even on a frame that just genuinely advanced. Found
## exactly this way: after gating Unit movement on a freshly re-called
## is_stalled(), one side's units froze at their exact spawn position for
## the ENTIRE 150-tick trace while GameManager.current_tick climbed
## normally into the hundreds -- the tick counter was fine, movement was
## reading stale-by-one-tick stall state.
var _stalled_this_frame: bool = true

func set_stalled_this_frame(value: bool) -> void:
	_stalled_this_frame = value


## True while Main._physics_process() is blocked on can_advance_to_tick()
## for the CURRENT tick -- Unit._physics_process() checks this to skip its
## own movement/avoidance/decay stepping on stalled real frames. Without
## this, units kept moving every real physics frame regardless of the
## stall (the previously-documented "KNOWN GAP"), and since one peer can
## spend more real frames stalled than another before reaching the same
## tick number, that peer's units silently accumulate extra ungated
## movement -- proven to be a real, not just theoretical, divergence
## source via the 2-instance trace-and-diff harness: two peers' checksums
## for the SAME tick number disagreed because one side's units had simply
## moved further in real time before that tick was reached.
func is_stalled() -> bool:
	return _stalled_this_frame
