## A crude Blood Tournament opponent: spends a Player's gold on new roster
## slots (and, with whatever blood points it has, a shop upgrade) during
## PLACEMENT, using the same public GameManager API a human clicking
## around the HUD would. This is deliberately not a real utility AI (no
## board evaluation, no countering the human's composition, no
## repositioning/selling survivors) -- it proves an opponent that can be
## fought solo is possible without inventing a whole decision-making
## framework the roadmap never asked for. Only ever called by Main.gd for
## a Player whose is_human is false, while GameManager.current_mode.uses_economy()
## is true (see Main._run_ai_turn_if_needed()) -- this class itself
## doesn't check either, same trust-the-caller split
## GameManager.buy_upgrade()/sell_unit() already use for ownership.
##
## Buys into player.roster (data) rather than spawning live Units
## directly -- Main._begin_staggered_deployment() is what actually
## deploys a roster once BATTLE starts, the same as a human's purchases.
## One known gap from that: _maybe_buy_an_upgrade() targets a living
## owned unit, and nothing is alive yet at the point this runs (PLACEMENT,
## right after a round transition) -- it'll harmlessly no-op every time
## until AI purchasing gets its own mid-battle trigger, same open item
## noted for the human upgrade flow in BattleFoundry-Roadmap.md §1.
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
## blood points it has on one random affordable upgrade for one of its
## own living units (see the class doc comment for why that part
## currently no-ops). _MAX_NEW_UNITS_PER_TURN caps purchased slots, not
## raw battlefield unit count -- each slot deploys as a
## GameManager.spawn_squad()-sized squad once battle starts.
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
	var own_living_units := GameManager.get_all_units().filter(
		func(unit: Unit) -> bool: return unit.player == player and unit.life_state == Unit.LifeState.ALIVE
	)
	if own_living_units.is_empty():
		return

	var affordable_upgrades := _UPGRADE_POOL.filter(func(upgrade: UnitUpgrade) -> bool: return player.can_afford_blood_points(upgrade.cost))
	if affordable_upgrades.is_empty():
		return

	var upgrade: UnitUpgrade = affordable_upgrades[randi() % affordable_upgrades.size()]
	var target: Unit = own_living_units[randi() % own_living_units.size()]
	GameManager.buy_upgrade(target, upgrade)
