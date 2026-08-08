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
## the match (a team reaches rounds_to_win). Only used when total_rounds
## is 0 (unset) -- see total_rounds' own doc comment.
signal match_ended(winning_team_id: int)
## Emitted alongside round_ended, only once, on the round that reaches
## total_rounds (only used when total_rounds > 0 -- see its own doc
## comment). Deciding an actual champion from the 12 rounds' standings is
## the not-yet-built bracket-style final tournament's job (Stage D, see
## BattleFoundry-Roadmap.md §1); this class's responsibility stops at "all
## the rounds are done."
signal all_rounds_finished

## Real gold, granted once at match start and again as round income, spent
## through Main._try_place_unit()/GameManager.sell_unit(). Walks
## GameManager.all_team_ids() rather than two hardcoded team_ids, for the
## 8-team cross map.
const STARTING_GOLD := 300
## Every registered team gets exactly this much every round, win, lose,
## or draw -- deliberately flat/equal for everyone (no win bonus).
## Winning a round shouldn't buy more army than losing one; that's what
## blood points (see KILL_BLOOD_POINTS below) reward instead, and
## unlike gold, those really are only earned by playing well.
const PARTICIPATION_INCOME := 100
## Blood points, not gold -- awarded live (see on_unit_killed()) per
## kill, spent only on GameManager.buy_upgrade(). A separate currency
## from gold specifically so it can't be earned just by surviving/losing
## a round the way gold can.
const KILL_BLOOD_POINTS := 20

var rounds_to_win: int
var round_number: int = 0
var wins_by_team: Dictionary = {} ## team_id -> rounds won so far

## 0 (default): no fixed length -- the original first-to-rounds_to_win-wins
## behavior every existing best-of-N/2-team test already relies on.
## > 0 (Main._on_tournament_toggled() sets 12, the genre-accurate full
## match): is_match_over()/all_rounds_finished replace the win-threshold
## check/match_ended -- every one of the 12 rounds is always played
## through regardless of standings (boss rounds included, see
## is_boss_round()), rather than the match potentially ending early the
## instant one team reaches rounds_to_win.
var total_rounds: int = 0

## -1 (default): not currently in a goblin boss round's team-turn, every
## method below behaves normally (N-team PvP). Set by GoblinBossRound for
## the duration of exactly one team's solo turn against the goblin --
## while set, can_start_battle()/check_victory()/on_battle_ended() all
## treat that one team's own wipe as the end of just its turn (a DRAW,
## "no PvP winner"), not the whole match, and skip the normal round
## scoring GoblinBossRound.boss_round_finished/finish_boss_round() handles
## once for the round as a whole instead. See GoblinBossRound's own class
## doc comment for the full sequencing this supports.
var current_boss_team_id: int = -1

## False (default): not currently in a final-tournament bracket matchup.
## Set by FinalTournamentBracket for the duration of exactly one 1v1
## matchup -- while true, on_battle_ended() skips its normal round
## scoring (income/round_number/round_ended), since a bracket matchup
## isn't "the next round" of the 12-round match. check_victory() needs no
## bracket-specific branch: its existing N-team logic already reduces
## correctly to a 1v1 decision when only the two paired teams have
## anything deployed. See FinalTournamentBracket's own class doc comment
## for the full sequencing this supports.
var in_bracket_match: bool = false

## Which of the 8 registered teams are actually playing this match --
## confirmed design: 2 to 8 teams, chosen at setup, "fill all slots with
## bots or just some of them." Plain Array (not Array[int]) deliberately
## -- see GoblinBossRound._pending_team_ids' own doc comment for why a
## computed team-id list in this codebase keeps hitting a typed-array
## assignment quirk not worth chasing further. Empty (default) means
## "every registered team" -- get_active_team_ids() is what every caller
## actually reads, so every existing test/caller that never sets this
## explicitly keeps seeing all 8, unchanged. Main._apply_menu_selection()
## is the one real caller that sets a smaller list.
var active_team_ids: Array = []


## Only teams actually playing get starting/round gold (on_activated()/
## on_battle_ended()/finish_boss_round() below) -- an inactive slot
## should never accumulate free gold nobody can ever spend on it.
## Deliberately NOT consulted by can_start_battle()/check_victory()/the
## goblin-boss-round/bracket-tournament participant filters elsewhere --
## those already work correctly off Player.roster.is_empty(), which an
## inactive team's roster always is (nobody ever funds it to buy
## anything), so this needs to be the single source of truth for gold
## only, not duplicated everywhere "who's really playing" already gets
## asked a different way.
func get_active_team_ids() -> Array:
	return active_team_ids if not active_team_ids.is_empty() else GameManager.all_team_ids()


func _init(p_rounds_to_win: int = 2, p_total_rounds: int = 0) -> void:
	rounds_to_win = p_rounds_to_win
	total_rounds = p_total_rounds


func uses_economy() -> bool:
	return true


func uses_cross_map() -> bool:
	return true


func is_auto_battle() -> bool:
	return true


func on_unit_killed(killer: Unit) -> void:
	killer.player.add_blood_points(KILL_BLOOD_POINTS)


## At least 2 of the 8 registered teams need a roster slot bought -- an
## 8-way free-for-all shouldn't require every single spawn slot on the
## cross map to be filled before anyone can fight. Checks Player.roster,
## not live units: under the staggered-deployment model (see
## Main._begin_staggered_deployment()) nothing is actually spawned during
## PLACEMENT anymore, so GameManager.team_is_empty() would always read
## "empty" here and this could never return true.
##
## During a boss-round team-turn (current_boss_team_id set), this always
## returns true instead -- GoblinBossRound._next_team_turn() is the sole
## authority on when to call GameManager.start_battle() for that turn,
## already having confirmed the team it's about to deploy has a roster;
## the normal ">= 2 teams" rule doesn't apply since exactly one
## competitive team ever fields anything during a boss round.
func can_start_battle() -> bool:
	if current_boss_team_id != -1:
		return true
	var teams_with_units := 0
	for team_id in GameManager.all_team_ids():
		if not GameManager.get_player(team_id).roster.is_empty():
			teams_with_units += 1
	return teams_with_units >= 2


## See GameMode.on_activated()'s doc comment for why starting gold is
## granted here and not from _init() or on_battle_started().
func on_activated() -> void:
	for team_id in get_active_team_ids():
		GameManager.get_player(team_id).add_gold(STARTING_GOLD)


## N-team elimination: whichever of the 8 registered teams still have a
## unit are "remaining." Exactly one left -> that team wins the round;
## zero left (the last two remaining teams' units happened to wipe each
## other out on the same death) -> draw. This also correctly subsumes the
## old 2-team-only version of this check (only 2 of the 8 ever fielding a
## unit reduces to exactly the same behavior), so a plain Blue-vs-Red
## Blood Tournament match still works identically.
##
## During a boss-round team-turn, this ignores the normal N-team logic
## entirely and only watches current_boss_team_id's own roster -- every
## other competitive team fields nothing during a boss round anyway, so
## the normal count would misread "only one team remains" as a PvP win
## the instant the fighting team's very first unit died. Attrition, not a
## win: the goblin encounter is designed to always end in the team's own
## units wiping (see GoblinBossRound's class doc comment), so this only
## ever reports DRAW ("no PvP winner") or NONE, never TEAM_WON.
func check_victory() -> Dictionary:
	if current_boss_team_id != -1:
		if GameManager.team_is_empty(current_boss_team_id):
			return {"result": VictoryResult.DRAW}
		return {"result": VictoryResult.NONE}

	var remaining: Array[int] = []
	for team_id in GameManager.all_team_ids():
		if not GameManager.team_is_empty(team_id):
			remaining.append(team_id)

	if remaining.size() == 1:
		return {"result": VictoryResult.TEAM_WON, "winning_team_id": remaining[0]}
	if remaining.is_empty():
		return {"result": VictoryResult.DRAW}
	return {"result": VictoryResult.NONE}


## No-ops during a boss-round team-turn: GameManager.battle_ended still
## fires as normal (GoblinBossRound listens to that directly to advance
## to the next team), but the round-scoring below -- income, round_number,
## round_ended -- only happens once, for the boss round as a whole, via
## finish_boss_round() below, not once per team-turn.
func on_battle_ended(winning_team_id: int, is_draw: bool) -> void:
	if current_boss_team_id != -1 or in_bracket_match:
		return

	round_number += 1
	if not is_draw:
		wins_by_team[winning_team_id] = wins_by_team.get(winning_team_id, 0) + 1

	for team_id in get_active_team_ids():
		GameManager.get_player(team_id).add_gold(PARTICIPATION_INCOME)

	round_ended.emit(round_number, winning_team_id, is_draw)

	if total_rounds > 0:
		if round_number >= total_rounds:
			all_rounds_finished.emit()
	elif not is_draw and wins_by_team[winning_team_id] >= rounds_to_win:
		match_ended.emit(winning_team_id)


## True when the *next* round (round_number hasn't incremented for it
## yet) should be a goblin boss round instead of normal PvP -- every 3rd
## round (3, 6, 9, 12...). Checked by Main.gd at the moment "Start
## Battle" is pressed, to decide whether to hand off to GoblinBossRound
## instead of calling GameManager.start_battle() directly.
func is_boss_round() -> bool:
	return (round_number + 1) % 3 == 0


## Called once by GoblinBossRound, after every team with a roster has
## taken its turn -- mirrors on_battle_ended()'s round scoring (income +
## round_number + round_ended) for the boss round as a whole. No team
## "wins" a boss round -- it's PvE, not PvP -- so wins_by_team is
## untouched and match_ended never fires from here, only from a normal
## PvP round's on_battle_ended().
func finish_boss_round() -> void:
	round_number += 1
	for team_id in get_active_team_ids():
		GameManager.get_player(team_id).add_gold(PARTICIPATION_INCOME)
	round_ended.emit(round_number, -1, true)
	if total_rounds > 0 and round_number >= total_rounds:
		all_rounds_finished.emit()


func is_match_over() -> bool:
	if total_rounds > 0:
		return round_number >= total_rounds
	for wins in wins_by_team.values():
		if wins >= rounds_to_win:
			return true
	return false


func get_wins(team_id: int) -> int:
	return wins_by_team.get(team_id, 0)
