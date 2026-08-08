## Base class for a game mode: owns win-condition logic and whatever
## match-level state a specific mode needs (round count, scoring, a
## throne's HP, ...). GameManager delegates to whichever GameMode is
## active (see GameManager.current_mode) instead of hardcoding a single
## win condition itself -- GameManager stays a mode-agnostic entity
## registry + lifecycle; what "winning" means is entirely up to the mode.
##
## The default, ClassicEliminationMode (Scripts/ClassicEliminationMode.gd),
## reproduces exactly the "team roster empty -> the other team wins"
## behavior this project always had, so a caller that never sets a mode
## sees no change at all.
class_name GameMode
extends RefCounted

enum VictoryResult { NONE, TEAM_WON, DRAW }


## Called by GameManager every time a unit dies during BATTLE, after
## roster bookkeeping (so team_is_empty() reflects the death that just
## happened). Returns {"result": VictoryResult.NONE} to keep the battle
## going, or {"result": TEAM_WON, "winning_team_id": int} /
## {"result": DRAW} to end it.
func check_victory() -> Dictionary:
	return {"result": VictoryResult.NONE}


## Called once when PLACEMENT -> BATTLE succeeds (GameManager.start_battle()).
func on_battle_started() -> void:
	pass


## Called once when a battle ends, win or draw -- e.g. BloodTournamentMode
## uses this to record the round's result and decide whether the match
## continues.
func on_battle_ended(_winning_team_id: int, _is_draw: bool) -> void:
	pass
