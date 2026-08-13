## Per-tick checksum broadcast + comparison -- the cheap, standard
## lockstep desync detector (D1 multiplayer plan, Phase C -- see
## BattleFoundry-Roadmap.md): if two peers ever compute a different
## checksum for the same tick, something has already diverged, and this
## is what catches it immediately instead of letting it silently compound
## into an unwinnable, invisible desync several seconds later. A
## diagnostic only -- an actual resync mechanism (request a fresh
## snapshot from the host, etc.) is explicitly Phase E's job, not this
## one's; this phase just logs loudly.
##
## Local-only (no active NetworkSession): broadcast_and_check() still
## computes and stores the local checksum every tick (cheap, and useful
## for a future replay-diffing tool) but never has anything to compare
## against, so it's a pure no-op cost-wise beyond that.
##
## Scoped to exactly 2 peers (Phase C's own target) -- see
## _compare_if_ready()'s own doc comment for what a 3+-peer Phase D would
## need to change.
extends Node

var _local_checksums: Dictionary = {} # tick: int -> checksum: int
var _remote_checksums: Dictionary = {} # tick: int -> {peer_id: int -> checksum: int}


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS


func broadcast_and_check(tick: int) -> void:
	var checksum := _compute_checksum()
	_local_checksums[tick] = checksum
	if NetworkSession.is_active():
		for peer_id in NetworkSession.peer_ids:
			_receive_checksum.rpc_id(peer_id, tick, checksum)
	_compare_if_ready(tick)


## Every unit's net_id/position/health/life_state, in GameManager.get_all_units()'s
## own fixed (spawn/append) order -- the exact same snapshot shape
## DeterminismCheck.gd's throwaway trace harness already proved
## deterministic across separate process runs (see the Roadmap's D1
## Phase A2 writeup). hash() on the joined string is a plain 32-bit
## GDScript hash, not cryptographic -- collisions are astronomically
## unlikely for this purpose (catching a real divergence, not defending
## against an adversary) and irrelevant if they did happen, since a
## checksum MATCH is never treated as proof, only a MISMATCH is acted on.
func _compute_checksum() -> int:
	var parts: PackedStringArray = []
	for unit in GameManager.get_all_units():
		var pos := unit.global_position
		parts.append("%d:%.6f,%.6f,%.6f|%.4f|%d" % [unit.net_id, pos.x, pos.y, pos.z, unit.current_health, unit.life_state])
	return hash(",".join(parts))


@rpc("any_peer", "call_remote", "unreliable")
func _receive_checksum(tick: int, checksum: int) -> void:
	var sender_id := multiplayer.get_remote_sender_id()
	if not _remote_checksums.has(tick):
		_remote_checksums[tick] = {}
	_remote_checksums[tick][sender_id] = checksum
	_compare_if_ready(tick)


## Compares and clears tick `tick` the moment both the local checksum AND
## (for a 2-peer session) the one other peer's checksum are both in hand
## -- correct for exactly 2 total peers (this phase's own scope). A 3+-peer
## Phase D would need to wait for ALL of NetworkSession.peer_ids before
## clearing, not just the first remote checksum to arrive, or a second
## peer's later-arriving checksum for the same tick would find nothing
## left to compare against.
func _compare_if_ready(tick: int) -> void:
	if not _local_checksums.has(tick) or not _remote_checksums.has(tick):
		return
	var local_checksum: int = _local_checksums[tick]
	for peer_id in _remote_checksums[tick]:
		var remote_checksum: int = _remote_checksums[tick][peer_id]
		if remote_checksum != local_checksum:
			push_error("DESYNC at tick %d vs peer %d: local=%d remote=%d" % [tick, peer_id, local_checksum, remote_checksum])
	_local_checksums.erase(tick)
	_remote_checksums.erase(tick)
