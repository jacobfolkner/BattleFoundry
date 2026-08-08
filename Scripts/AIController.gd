## A crude Blood Tournament opponent: spends a Player's gold on new units
## (and, with whatever's left, a shop upgrade) during PLACEMENT, using the
## same public GameManager API a human clicking around the HUD would --
## GameManager.spawn_unit()/buy_upgrade(). This is deliberately not a real
## utility AI (no board evaluation, no countering the human's
## composition, no repositioning/selling survivors) -- it proves an
## opponent that can be fought solo is possible without inventing a whole
## decision-making framework the roadmap never asked for. Only ever
## called by Main.gd for a Player whose is_human is false, while
## GameManager.current_mode.uses_economy() is true (see
## Main._run_ai_turn_if_needed()) -- this class itself doesn't check
## either, same trust-the-caller split GameManager.buy_upgrade()/
## sell_unit() already use for ownership.
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
## Safety cap on a single turn's new-unit spawns -- not a balance number,
## just a guard against an unbounded loop if a future archetype ever had
## cost <= 0.
const _MAX_NEW_UNITS_PER_TURN := 8
## The AI's side of the shared open 40x40 arena -- mirrors the +x
## convention this codebase's own tests already use for "the second
## team," so new units don't drop on top of whatever the human already
## placed on the -x side. Flying units still spawn at y=0 like every
## placement does; Unit._physics_process() floats them up to
## flight_height on its own the next physics step, same as a human's
## click-to-place.
const _SPAWN_X_RANGE := Vector2(6.0, 18.0)
const _SPAWN_Z_RANGE := Vector2(-18.0, 18.0)


## Spends `player`'s gold on a random affordable archetype, repeatedly,
## until nothing left in _UNIT_POOL fits the remaining budget (or the
## safety cap is hit), then spends whatever blood points it has on one
## random affordable upgrade for one of its own living units. Each
## purchase deploys via GameManager.spawn_squad() (honoring
## UnitStats.squad_size), so _MAX_NEW_UNITS_PER_TURN caps purchased
## slots, not raw battlefield unit count.
func take_turn(player: Player) -> void:
	var spawned := 0
	var affordable := _affordable_units(player)
	while not affordable.is_empty() and spawned < _MAX_NEW_UNITS_PER_TURN:
		var stats: UnitStats = affordable[randi() % affordable.size()]
		var position := Vector3(
			randf_range(_SPAWN_X_RANGE.x, _SPAWN_X_RANGE.y),
			0.0,
			randf_range(_SPAWN_Z_RANGE.x, _SPAWN_Z_RANGE.y)
		)
		GameManager.spawn_squad(stats, player, position)
		player.spend(stats.cost)
		spawned += 1
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
