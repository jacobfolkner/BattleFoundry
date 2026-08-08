## One competitive slot in a match -- team membership plus (eventually)
## human/AI control, color, and resources.
##
## Units reference a Player instead of a raw team enum, so "which side is
## this on," "what color is it," and "can it attack that" all resolve
## through one object instead of a binary Team.Type check duplicated
## across GameManager, Unit, and HUD. Multiple Players can share the same
## team_id (a future N-players-per-team mode) -- see AllianceMatrix for
## how team_id, not player identity, decides who's hostile to whom.
class_name Player
extends RefCounted

var id: int
var slot: int
var team_id: int
var display_name: String
var color: Color
var is_human: bool
## Placeholder for a future gold/lumber economy -- present now so
## GameManager/HUD code that will eventually read it doesn't need
## another Player field bolted on later.
var resources: int = 0


func _init(p_id: int, p_slot: int, p_team_id: int, p_display_name: String, p_color: Color, p_is_human: bool = true) -> void:
	id = p_id
	slot = p_slot
	team_id = p_team_id
	display_name = p_display_name
	color = p_color
	is_human = p_is_human
