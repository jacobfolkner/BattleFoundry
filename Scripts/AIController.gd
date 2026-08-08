## A crude Blood Tournament opponent: spends a Player's gold on new roster
## slots and, with whatever blood points it has, an account-wide shop
## upgrade, during PLACEMENT, using the same public GameManager API a
## human clicking around the HUD would. This is deliberately not a real
## utility AI (no board evaluation, no countering the human's composition,
## no repositioning/selling survivors) -- it proves an opponent that can
## be fought solo is possible without inventing a whole decision-making
## framework the roadmap never asked for. Only ever called by Main.gd for
## a Player whose is_human is false, while GameManager.current_mode.uses_economy()
## is true (see Main._run_ai_turn_if_needed()) -- this class itself
## doesn't check either, same trust-the-caller split
## GameManager.buy_upgrade()/sell_unit() already use for ownership.
##
## Buys into player.roster/roster_upgrades (data) rather than spawning
## live Units or applying Effects directly -- Main._begin_staggered_deployment()/
## _deploy_next_pending_slot() is what actually deploys a roster and
## applies its upgrades once BATTLE starts, the same as a human's
## purchases.
class_name AIController
extends RefCounted

const _UNIT_POOL: Array[UnitStats] = [
	preload("res://Resources/Units/TankStats.tres"),
	preload("res://Resources/Units/FighterStats.tres"),
	preload("res://Resources/Units/ArcherStats.tres"),
	preload("res://Resources/Units/BatRiderStats.tres"),
	preload("res://Resources/Units/GiantStats.tres"),
]
const _UPGRADE_POOL: Array[UnitUpgrade] = [
	preload("res://Resources/Upgrades/IronArmorUpgrade.tres"),
	preload("res://Resources/Upgrades/WhetstoneUpgrade.tres"),
]
## Safety cap on a single turn's roster additions -- not a balance
## number, just a guard against an unbounded loop if a future archetype
## ever had cost <= 0.
const _MAX_NEW_UNITS_PER_TURN := 8


## Spends `player`'s gold on a random affordable archetype, repeatedly,
## appending each to the roster, until nothing left in _UNIT_POOL fits
## the remaining budget (or the safety cap is hit), then spends whatever
## blood points it has on one random affordable account-wide upgrade
## (see GameManager.buy_roster_upgrade()). _MAX_NEW_UNITS_PER_TURN caps
## purchased slots, not raw battlefield unit count -- each slot deploys
## as a GameManager.spawn_squad()-sized squad once battle starts.
func take_turn(player: Player) -> void:
	var added := 0
	var affordable := _affordable_units(player)
	while not affordable.is_empty() and added < _MAX_NEW_UNITS_PER_TURN:
		var stats: UnitStats = affordable[randi() % affordable.size()]
		player.roster.append(stats)
		player.spend(stats.cost)
		added += 1
		affordable = _affordable_units(player)

	_maybe_buy_an_upgrade(player)


func _affordable_units(player: Player) -> Array[UnitStats]:
	return _UNIT_POOL.filter(func(stats: UnitStats) -> bool: return player.can_afford(stats.cost))


func _maybe_buy_an_upgrade(player: Player) -> void:
	var affordable_upgrades := _UPGRADE_POOL.filter(func(upgrade: UnitUpgrade) -> bool: return player.can_afford_blood_points(upgrade.cost))
	if affordable_upgrades.is_empty():
		return

	var upgrade: UnitUpgrade = affordable_upgrades[randi() % affordable_upgrades.size()]
	GameManager.buy_roster_upgrade(player, upgrade)
