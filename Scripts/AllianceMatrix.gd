## Answers "is team A hostile to team B?" instead of Team.get_opponent()'s
## binary flip -- the actual question combat code needs, and the one that
## scales to FFA, allied victory, and a neutral faction without every
## caller special-casing "unless it's neutral."
##
## Two distinct, non-neutral teams are hostile by default (free-for-all)
## -- ally() opts a pair OUT of that, it doesn't opt one in. The neutral
## team is never hostile to anyone, in either direction, regardless of
## what's been allied/unallied -- a neutral shop or creep camp shouldn't
## become attackable just because two player teams stopped allying.
class_name AllianceMatrix
extends RefCounted

## team_id for units with no player owner -- shops, creeps, doodads.
const NEUTRAL_TEAM_ID := -1

var _allied_pairs: Dictionary = {} # {"min:max" pair key: true} for explicitly allied team pairs


func is_hostile(team_a: int, team_b: int) -> bool:
	if team_a == team_b:
		return false
	if team_a == NEUTRAL_TEAM_ID or team_b == NEUTRAL_TEAM_ID:
		return false
	return not _allied_pairs.has(_pair_key(team_a, team_b))


func ally(team_a: int, team_b: int) -> void:
	_allied_pairs[_pair_key(team_a, team_b)] = true


func unally(team_a: int, team_b: int) -> void:
	_allied_pairs.erase(_pair_key(team_a, team_b))


func are_allied(team_a: int, team_b: int) -> bool:
	return team_a == team_b or _allied_pairs.has(_pair_key(team_a, team_b))


func _pair_key(team_a: int, team_b: int) -> String:
	return "%d:%d" % [mini(team_a, team_b), maxi(team_a, team_b)]
