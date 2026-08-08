## Best-of-N rounds: same per-round win condition as
## ClassicEliminationMode (a team losing every unit loses that round),
## but the match itself doesn't end until one team has won enough rounds.
## The "crude" mode the roadmap asks for as the first real proof of the
## GameMode layer -- deliberately just rounds + scoring, nothing else:
## no shop phase (Phase 5 economy doesn't exist yet), no hero select
## (Phase 4 doesn't exist yet). Arena reset between rounds is the
## caller's job (see round_ended's doc comment) -- this class only
## tracks the score and decides when the match itself is over, it
## doesn't touch GameManager.reset_battle() itself, to keep GameMode
## implementations from needing lifecycle authority over GameManager.
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

var rounds_to_win: int
var round_number: int = 0
var wins_by_team: Dictionary = {} ## team_id -> rounds won so far


func _init(p_rounds_to_win: int = 2) -> void:
	rounds_to_win = p_rounds_to_win


## Same elimination rule as ClassicEliminationMode -- Blood Tournament
## doesn't change *when* a round ends, only what happens after.
func check_victory() -> Dictionary:
	if GameManager.team_is_empty(GameManager.BLUE_TEAM_ID):
		return {"result": VictoryResult.TEAM_WON, "winning_team_id": GameManager.RED_TEAM_ID}
	if GameManager.team_is_empty(GameManager.RED_TEAM_ID):
		return {"result": VictoryResult.TEAM_WON, "winning_team_id": GameManager.BLUE_TEAM_ID}
	return {"result": VictoryResult.NONE}


func on_battle_ended(winning_team_id: int, is_draw: bool) -> void:
	round_number += 1
	if not is_draw:
		wins_by_team[winning_team_id] = wins_by_team.get(winning_team_id, 0) + 1

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
