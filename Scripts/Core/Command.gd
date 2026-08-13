## A single player-or-AI-originated action, wrapped for tick-scheduled
## execution via CommandQueue instead of applying immediately -- part of
## the D1 multiplayer plan (BattleFoundry-Roadmap.md), the layer every
## future networked peer's input funnels through, same shape whether the
## source is a local human, a local AI turn, or (eventually) a remote
## peer's own input replayed here.
##
## One flat class with a handful of generic fields, interpreted per
## `type`, rather than a subclass per command -- mirrors Unit.Order's own
## existing precedent (one class, a few generic fields, covers 6 order
## types) for the same reason: a dozen near-empty subclasses would be
## more ceremony than the actual variation in shape justifies. Not every
## field is meaningful for every `type` -- see each Type's own doc
## comment below for which ones it reads.
##
## References units/players by net_id/team_id, never a live Unit/Player
## object -- the whole point of wrapping a command is that it has to
## survive a tick-delay (and eventually a real network hop) before it
## executes, by which point a raw object reference could be stale or,
## once real networking exists, wouldn't serialize at all.
## GameManager.apply_command() is what resolves these back to live
## objects at the moment a command actually runs.
class_name Command
extends RefCounted

enum Type {
	UNIT_ORDER, ## unit_net_id, order_type, target_position, target_net_id (FOLLOW/ATTACK_MOVE-with-a-clicked-unit), queue
	CAST_ABILITY, ## unit_net_id, ability_index, target_net_id (-1 for auto-target/no-target/passive)
	BUY_ROSTER_SLOT, ## team_id, unit_stats, target_position (Vector3.ZERO treated as "no position" -- see has_target_position)
	SELL_UNIT, ## unit_net_id
	BUY_ROSTER_UPGRADE, ## team_id, upgrade
	BUY_ARCHETYPE_UPGRADE, ## team_id, upgrade, squad_id
	PICK_HERO_ABILITY, ## team_id, unit_stats, slot_index, chosen_index
	EXCHANGE_CURRENCY, ## team_id, exchange_gold_for_blood (true: gold->blood, false: blood->gold)
	START_BATTLE, ## no payload beyond team_id (who pressed it, for auditability -- GameManager.start_battle() itself isn't team-scoped)
	READY_UP, ## team_id -- marks that team ready for the current PLACEMENT phase (Blood Tournament only, see GameManager.mark_team_ready())
}

var type: Type
var team_id: int = -1
var unit_net_id: int = -1
var target_net_id: int = -1
var order_type: Unit.OrderType
var target_position: Vector3 = Vector3.ZERO
## BUY_ROSTER_SLOT only -- distinguishes the human's click-to-place path
## (a real position) from the AI's positionless buy_roster_slot() +
## sync_courtyard_to_roster() path (no position at all -- the default
## courtyard anchor decides where it lands). target_position alone can't
## tell these apart since Vector3.ZERO is itself a valid click position.
var has_target_position: bool = false
var queue: bool = false
var ability_index: int = -1
var unit_stats: UnitStats
var upgrade: Resource ## UnitUpgrade or ArchetypeUpgrade, depending on type
var squad_id: int = -1
var slot_index: int = -1
var chosen_index: int = -1
var exchange_gold_for_blood: bool = true


## Dictionary encoding for CommandQueue's RPC relay (Phase C) -- Godot's
## multiplayer RPC Variant encoding doesn't safely carry an arbitrary
## RefCounted/Object over the wire, so a Command has to cross the network
## as plain data. `unit_stats`/`upgrade` (both preloaded, checked-in
## .tres Resources, identical on every peer) go over as their
## resource_path string and get reloaded on the other side via load() --
## the loaded instance won't be the SAME object as the sender's own, but
## it's the same underlying resource, which is all apply_command() ever
## needs from it.
func to_dict() -> Dictionary:
	return {
		"type": type,
		"team_id": team_id,
		"unit_net_id": unit_net_id,
		"target_net_id": target_net_id,
		"order_type": order_type,
		"target_position": target_position,
		"has_target_position": has_target_position,
		"queue": queue,
		"ability_index": ability_index,
		"unit_stats_path": unit_stats.resource_path if unit_stats != null else "",
		"upgrade_path": upgrade.resource_path if upgrade != null else "",
		"squad_id": squad_id,
		"slot_index": slot_index,
		"chosen_index": chosen_index,
		"exchange_gold_for_blood": exchange_gold_for_blood,
	}


static func from_dict(data: Dictionary) -> Command:
	var command := Command.new()
	command.type = data["type"] as Type
	command.team_id = data["team_id"]
	command.unit_net_id = data["unit_net_id"]
	command.target_net_id = data["target_net_id"]
	command.order_type = data["order_type"] as Unit.OrderType
	command.target_position = data["target_position"]
	command.has_target_position = data["has_target_position"]
	command.queue = data["queue"]
	command.ability_index = data["ability_index"]
	if data["unit_stats_path"] != "":
		command.unit_stats = load(data["unit_stats_path"])
	if data["upgrade_path"] != "":
		command.upgrade = load(data["upgrade_path"])
	command.squad_id = data["squad_id"]
	command.slot_index = data["slot_index"]
	command.chosen_index = data["chosen_index"]
	command.exchange_gold_for_blood = data["exchange_gold_for_blood"]
	return command
