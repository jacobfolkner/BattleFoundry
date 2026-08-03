## Identifies which side a unit belongs to.
##
## A standalone class (rather than nesting the enum inside Unit) so that
## any script -- UI, GameManager, Unit, future game modes -- can reference
## Team.Type without depending on each other.
class_name Team

enum Type { BLUE, RED }


## Returns the opposing team.
static func get_opponent(team: Type) -> Type:
	return Type.RED if team == Type.BLUE else Type.BLUE


## Human-readable name, used for HUD text.
static func get_display_name(team: Type) -> String:
	return "Blue" if team == Type.BLUE else "Red"
