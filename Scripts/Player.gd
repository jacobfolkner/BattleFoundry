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
## Gold -- only meaningful while GameManager.current_mode.uses_economy() is
## true (see GameMode.gd/BloodTournamentMode.gd); stays 0 and unused for
## a plain single-battle match, same as before this field had real
## behavior behind it. BloodTournamentMode grants a starting amount and
## round-end income directly via add_gold(); spend()/can_afford() are what
## Main.gd's placement/sell/upgrade flows check against.
var resources: int = 0


func _init(p_id: int, p_slot: int, p_team_id: int, p_display_name: String, p_color: Color, p_is_human: bool = true) -> void:
	id = p_id
	slot = p_slot
	team_id = p_team_id
	display_name = p_display_name
	color = p_color
	is_human = p_is_human


func can_afford(amount: int) -> bool:
	return resources >= amount


## No affordability check here -- callers must call can_afford() first (see
## GameManager.sell_unit()/buy_upgrade() and Main._try_place_unit()); keeps
## this a plain ledger operation instead of a second place that decides
## what "affordable" means.
func spend(amount: int) -> void:
	resources -= amount


## Also how round income and starting gold are granted (see
## BloodTournamentMode) -- there's no meaningful difference between
## "earning" and "being refunded" gold, so one method covers both.
func add_gold(amount: int) -> void:
	resources += amount
