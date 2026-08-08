## Best-of-N rounds, now genuinely N-team (up to GameManager.TEAM_COUNT,
## the 8-team cross map): the round ends the instant only one of the
## registered teams still has a unit, and the match itself doesn't end
## until one team has won enough rounds. Started as the roadmap's
## "crude, prove the GameMode layer" mode (rounds + scoring, nothing
## else); persistence/economy/upgrades/heroes/AI have all landed on top
## of it since. Arena reset between rounds is the caller's job (see
## round_ended's doc comment) -- this class only tracks the score and
## decides when the match itself is over, it doesn't touch
## GameManager.reset_battle() itself, to keep GameMode implementations
## from needing lifecycle authority over GameManager.
class_name BloodTournamentMode
extends GameMode

## Emitted from on_battle_ended(), every round (including the deciding
## one) -- callers (Main.gd) are expected to call GameManager.reset_battle()
## in response if is_match_over() is still false afterward, to set up the
## next round's PLACEMENT phase. Not done automatically here since
## GameMode has no reference back to GameManager's lifecycle methods by
## design (see class doc comment) -- only query methods like team_is_empty().
signal round_ended(round_number: int, winning_team_id: int, is_draw: bool)
## Emitted alongside round_ended, only on the round that actually decides
## the match (a team reaches rounds_to_win).
signal match_ended(winning_team_id: int)

## Slice 2 of the roadmap's persistence+economy work (slice 1 was
## GameManager.reset_battle(true)'s survivor carryover): real gold, granted
## once at match start and again as round income, spent through
## Main._try_place_unit()/GameManager.sell_unit()/buy_upgrade(). Walks
## GameManager.all_team_ids() rather than two hardcoded team_ids, for the
## 8-team cross map.
const STARTING_GOLD := 300
## Both teams get this every round, win or lose or draw -- a losing team
## that got nothing would spiral (fewer survivors AND no gold to rebuild
## with), so this is a deliberate catch-up-friendly design, not an
## oversight.
const PARTICIPATION_INCOME := 100
## Added on top of PARTICIPATION_INCOME, winning team only, skipped on a draw.
const WIN_BONUS := 50

var rounds_to_win: int
var round_number: int = 0
var wins_by_team: Dictionary = {} ## team_id -> rounds won so far


func _init(p_rounds_to_win: int = 2) -> void:
	rounds_to_win = p_rounds_to_win


func uses_economy() -> bool:
	return true


## At least 2 of the 8 registered teams need a unit -- an 8-way
## free-for-all shouldn't require every single spawn slot on the cross
## map to be filled before anyone can fight.
func can_start_battle() -> bool:
	var teams_with_units := 0
	for team_id in GameManager.all_team_ids():
		if not GameManager.team_is_empty(team_id):
			teams_with_units += 1
	return teams_with_units >= 2


## See GameMode.on_activated()'s doc comment for why starting gold is
## granted here and not from _init() or on_battle_started().
func on_activated() -> void:
	for team_id in GameManager.all_team_ids():
		GameManager.get_player(team_id).add_gold(STARTING_GOLD)


## N-team elimination: whichever of the 8 registered teams still have a
## unit are "remaining." Exactly one left -> that team wins the round;
## zero left (the last two remaining teams' units happened to wipe each
## other out on the same death) -> draw. This also correctly subsumes the
## old 2-team-only version of this check (only 2 of the 8 ever fielding a
## unit reduces to exactly the same behavior), so a plain Blue-vs-Red
## Blood Tournament match still works identically.
func check_victory() -> Dictionary:
	var remaining: Array[int] = []
	for team_id in GameManager.all_team_ids():
		if not GameManager.team_is_empty(team_id):
			remaining.append(team_id)

	if remaining.size() == 1:
		return {"result": VictoryResult.TEAM_WON, "winning_team_id": remaining[0]}
	if remaining.is_empty():
		return {"result": VictoryResult.DRAW}
	return {"result": VictoryResult.NONE}


func on_battle_ended(winning_team_id: int, is_draw: bool) -> void:
	round_number += 1
	if not is_draw:
		wins_by_team[winning_team_id] = wins_by_team.get(winning_team_id, 0) + 1

	for team_id in GameManager.all_team_ids():
		GameManager.get_player(team_id).add_gold(PARTICIPATION_INCOME)
	if not is_draw:
		GameManager.get_player(winning_team_id).add_gold(WIN_BONUS)

	round_ended.emit(round_number, winning_team_id, is_draw)

	if not is_draw and wins_by_team[winning_team_id] >= rounds_to_win:
		match_ended.emit(winning_team_id)


func is_match_over() -> bool:
	for wins in wins_by_team.values():
		if wins >= rounds_to_win:
			return true
	return false


func get_wins(team_id: int) -> int:
	return wins_by_team.get(team_id, 0)
