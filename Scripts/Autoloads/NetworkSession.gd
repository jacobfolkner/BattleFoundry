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


func _ready() -> void:
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)


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


func _on_peer_connected(id: int) -> void:
	if not peer_ids.has(id):
		peer_ids.append(id)


func _on_peer_disconnected(id: int) -> void:
	peer_ids.erase(id)
