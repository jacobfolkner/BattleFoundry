## The default mode: first team to lose every unit loses the battle,
## no rounds, no scoring -- exactly this project's original behavior,
## just expressed as a GameMode instead of hardcoded in GameManager.
class_name ClassicEliminationMode
extends GameMode

func check_victory() -> Dictionary:
	if GameManager.team_is_empty(GameManager.BLUE_TEAM_ID):
		return {"result": VictoryResult.TEAM_WON, "winning_team_id": GameManager.RED_TEAM_ID}
	if GameManager.team_is_empty(GameManager.RED_TEAM_ID):
		return {"result": VictoryResult.TEAM_WON, "winning_team_id": GameManager.BLUE_TEAM_ID}
	return {"result": VictoryResult.NONE}
