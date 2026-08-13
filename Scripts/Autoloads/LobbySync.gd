## Relays the host's lobby configuration to a connected client exactly
## once, when the host clicks "Start Match" (UI/MainMenu.gd) -- the
## host-authoritative model this session's D1 Phase D settled on: the
## host alone configures all 8 slots/factions, the client only watches
## and starts once it receives this. Same established @rpc convention as
## CommandQueue.gd/DesyncCheck.gd (per-peer rpc_id() from a
## NetworkSession.peer_ids loop, autoload rather than a scene node so the
## RPC path stays stable regardless of which scene is currently loaded --
## this fires while MainMenu.tscn is still active, before Main.tscn
## exists).
extends Node

## config: Dictionary -- see UI/MainMenu.gd's _build_host_config() for
## the exact shape (RPC-safe primitives only: ints/arrays/dictionaries,
## no raw Resources, same reasoning Command.to_dict() already established
## for unit_stats/upgrade).
signal host_config_received(config: Dictionary)


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS


func broadcast_host_config(config: Dictionary) -> void:
	if not NetworkSession.is_active():
		return
	for peer_id in NetworkSession.peer_ids:
		_receive_host_config.rpc_id(peer_id, config)


@rpc("any_peer", "call_remote", "reliable")
func _receive_host_config(config: Dictionary) -> void:
	host_config_received.emit(config)
