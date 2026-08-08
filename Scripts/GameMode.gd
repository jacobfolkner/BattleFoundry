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


## True only when a battle could actually be started right now, given
## GameManager's current rosters -- default: both BLUE_TEAM_ID/RED_TEAM_ID
## have a unit (the original two-team prototype check, unchanged for
## ClassicEliminationMode, which doesn't override this). BloodTournamentMode
## overrides it to "at least 2 of GameManager.all_team_ids() have a unit,"
## since an N-team free-for-all shouldn't require every single one of the
## 8 registered slots to be filled before anyone can fight.
func can_start_battle() -> bool:
	return not GameManager.team_is_empty(GameManager.BLUE_TEAM_ID) and not GameManager.team_is_empty(GameManager.RED_TEAM_ID)


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


## Called once by GameManager.set_mode(), the instant this mode actually
## becomes current_mode -- BloodTournamentMode uses this to grant starting
## gold, since it needs to exist before the first round's PLACEMENT phase
## even happens (on_battle_started() would be too late: that only fires
## once Start Battle is pressed, after placement already needed the gold
## to be spendable). Deliberately not folded into _init() -- a GameMode
## can be constructed without ever being activated (see
## BloodTournamentMode's own tests), and a constructor mutating global
## Player state as a side effect of merely being built, rather than
## actually taking over the match, would be a trap for whatever builds one
## next.
func on_activated() -> void:
	pass


## Called once when a battle ends, win or draw -- e.g. BloodTournamentMode
## uses this to record the round's result and decide whether the match
## continues.
func on_battle_ended(_winning_team_id: int, _is_draw: bool) -> void:
	pass


## False (default) means Player.resources/UnitStats.cost are never
## consulted -- Main._try_place_unit()'s placement and
## GameManager.sell_unit()/buy_upgrade() all no-op their gold side of
## things, so a plain single-battle match stays exactly as free-to-place
## as it always was. BloodTournamentMode overrides this to true; a mode
## that wants gold is expected to also grant starting/round income itself
## (see BloodTournamentMode.on_activated()/on_battle_ended(), which walk
## GameManager.all_team_ids()) -- GameMode has no generic way to do that
## itself, since not every mode necessarily wants every registered team
## to receive gold.
func uses_economy() -> bool:
	return false
