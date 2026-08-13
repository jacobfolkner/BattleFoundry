## LAN/direct-IP transport for the D1 multiplayer plan (BattleFoundry-Roadmap.md)
## -- `ENetMultiplayerPeer` only, wired directly to `multiplayer.multiplayer_peer`
## so CommandQueue can use plain `@rpc`-annotated calls for its own
## per-tick relay. Deliberately does NOT use Godot's `MultiplayerSynchronizer`
## or spawn-authority tooling -- those assume one authoritative broadcaster
## and everyone else replicating state, where this project's whole model
## is "every peer simulates locally from the same replayed inputs." This
## autoload only owns the connection itself; CommandQueue owns everything
## about what gets said over it.
extends Node

enum Role { NONE, HOST, CLIENT }

var role: Role = Role.NONE
## Every OTHER connected peer's multiplayer id -- never includes this
## peer's own id (`multiplayer.get_unique_id()`). A host with 1 client
## sees exactly that client's id here; a client sees exactly the host's
## id (always 1, ENet's fixed server id).
var peer_ids: Array[int] = []

## peer_id -> most recent round-trip time in ms, for UI/HUD.gd's ping
## label. Built at the application level (a plain timestamped
## ping/unreliable-RPC/pong loop) rather than reaching into
## ENetPacketPeer's own statistics API -- that API is real
## (get_statistic(PEER_ROUND_TRIP_TIME)) but untested in this codebase,
## and everything else here is already built at the RPC layer instead of
## engine internals, so this stays consistent with that.
var ping_by_peer: Dictionary = {}
const _PING_INTERVAL_SECONDS := 1.0
var _ping_elapsed: float = 0.0
## peer_id -> Time.get_ticks_msec() of the last ping sent to it, not yet
## answered -- lets _receive_pong() ignore a stray/late pong that doesn't
## match the most recent ping (e.g. a reply to a ping from before a brief
## disconnect/reconnect).
var _ping_sent_at: Dictionary = {}


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)


func _process(delta: float) -> void:
	if not is_active():
		return
	_ping_elapsed += delta
	if _ping_elapsed < _PING_INTERVAL_SECONDS:
		return
	_ping_elapsed = 0.0
	var now := Time.get_ticks_msec()
	for peer_id in peer_ids:
		_ping_sent_at[peer_id] = now
		_receive_ping.rpc_id(peer_id, now)


@rpc("any_peer", "call_remote", "unreliable")
func _receive_ping(sent_at: int) -> void:
	_receive_pong.rpc_id(multiplayer.get_remote_sender_id(), sent_at)


@rpc("any_peer", "call_remote", "unreliable")
func _receive_pong(sent_at: int) -> void:
	var sender_id := multiplayer.get_remote_sender_id()
	if _ping_sent_at.get(sender_id, -1) == sent_at:
		ping_by_peer[sender_id] = Time.get_ticks_msec() - sent_at


func is_active() -> bool:
	return role != Role.NONE


func host(port: int, max_peers: int = 8) -> Error:
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_server(port, max_peers)
	if err != OK:
		return err
	multiplayer.multiplayer_peer = peer
	role = Role.HOST
	return OK


func join(address: String, port: int) -> Error:
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_client(address, port)
	if err != OK:
		return err
	multiplayer.multiplayer_peer = peer
	role = Role.CLIENT
	return OK


func disconnect_session() -> void:
	if multiplayer.multiplayer_peer != null:
		multiplayer.multiplayer_peer.close()
	multiplayer.multiplayer_peer = null
	role = Role.NONE
	peer_ids.clear()
	ping_by_peer.clear()
	_ping_sent_at.clear()


func _on_peer_connected(id: int) -> void:
	if not peer_ids.has(id):
		peer_ids.append(id)


func _on_peer_disconnected(id: int) -> void:
	peer_ids.erase(id)
