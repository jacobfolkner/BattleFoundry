## Drives one Blood Tournament boss round: every registered team with a
## non-empty roster fights a fresh Goblin encounter alone, one at a time,
## in GameManager.all_team_ids() order -- not simultaneously, so kills and
## blood points earned are unambiguously attributable to one team at a
## time (confirmed with the user: "each player should fight the mob one
## team at a time... so people can watch how many kills/blood points each
## team gets"). See BattleFoundry-Roadmap.md §1 for the confirmed design
## (sequential turns, attrition -- always wipes, never a clearable win).
##
## Owned and driven entirely by Main.gd, the same split AIController
## already uses -- this class doesn't touch input or UI, just orchestrates
## GameManager/BloodTournamentMode state. Reuses GameManager.start_battle()/
## battle_ended per team-turn rather than inventing a second battle-state
## machine: BloodTournamentMode.current_boss_team_id (set here) is what
## tells GameManager.check_victory()/can_start_battle()/on_battle_ended()
## to treat one team's wipe as the end of just its own turn, not the whole
## match -- see that class's doc comments for exactly how.
class_name GoblinBossRound
extends RefCounted

const GOBLIN_STATS: UnitStats = preload("res://Resources/Units/GoblinStats.tres")
## Opposite ends of the arena -- doesn't matter which competitive team_id
## is actually taking its turn, it's always alone against the goblin.
const _TEAM_SPAWN_ANCHOR := Vector3(-8, 0, 0)
const _GOBLIN_SPAWN_ANCHOR := Vector3(8, 0, 0)

## Emitted once, after every team with a roster has taken its turn --
## Main.gd is expected to call BloodTournamentMode.finish_boss_round()
## in response (round scoring for the boss round as a whole, since
## on_battle_ended() itself no-ops per individual team-turn).
signal boss_round_finished

var _mode: BloodTournamentMode
## Plain Array, deliberately not Array[int] -- Array.filter() always
## returns a plain untyped Array, and assigning that into a typed-array
## variable (even through an explicitly Array[int]-typed return, which
## works for other filter() call sites elsewhere in this codebase, e.g.
## AIController._affordable_units()) still failed here at runtime with
## "Trying to assign an array of type Array to a variable of type
## Array[int]". Not worth chasing exactly why the coercion is
## inconsistent between call sites -- this field is purely internal
## state, nothing outside this class reads it, so dropping the strict
## typing entirely is the pragmatic fix.
var _pending_team_ids: Array = []


func start(mode: BloodTournamentMode) -> void:
	_mode = mode
	_pending_team_ids = GameManager.all_team_ids().filter(
		func(team_id: int) -> bool: return not GameManager.get_player(team_id).roster.is_empty()
	)
	GameManager.battle_ended.connect(_on_battle_ended)
	_next_team_turn()


func _next_team_turn() -> void:
	if _pending_team_ids.is_empty():
		GameManager.battle_ended.disconnect(_on_battle_ended)
		boss_round_finished.emit()
		return

	var team_id: int = _pending_team_ids.pop_front()
	var player := GameManager.get_player(team_id)
	_mode.current_boss_team_id = team_id

	# start_battle() before spawning, not after: GameManager.spawn_unit()
	# only issues the auto-battle convergence order (see its own doc
	# comment) while is_battle_active() is already true, and the team/
	# goblin anchors sit well beyond acquisition_range on their own, so
	# spawning first would leave both sides just standing there forever.
	GameManager.start_battle()

	for stats in player.roster:
		var squad := GameManager.spawn_squad(stats, player, _TEAM_SPAWN_ANCHOR)
		for upgrade in player.roster_upgrades:
			for unit in squad:
				upgrade.ability.cast_unit_target(unit, unit)
	GameManager.spawn_unit(GOBLIN_STATS, GameManager.get_player(GameManager.GOBLIN_TEAM_ID), _GOBLIN_SPAWN_ANCHOR)


## Fires once per team-turn (BloodTournamentMode.check_victory() reports
## DRAW the instant the current boss-round team wipes -- see its own doc
## comment) -- tears down before moving to the next team so a lingering
## goblin/corpse from this turn never bleeds into the next one.
func _on_battle_ended(_winning_team_id: int, _is_draw: bool) -> void:
	_mode.current_boss_team_id = -1
	GameManager.reset_battle()
	_next_team_turn()
