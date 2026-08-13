## Registry of every concrete Faction .tres -- kept in its own file,
## deliberately NOT as a const on Faction.gd itself. See Faction.gd's own
## doc comment for why: a script preloading .tres resources that are
## instances of that same script creates a circular load that silently
## degrades them to plain Resource. This file has no such self-reference,
## so it loads cleanly.
class_name FactionRegistry
extends RefCounted

## Every concrete faction, in lobby/shop display order -- the canonical
## list the lobby's faction picker (UI/MainMenu.gd) and random_pick()
## (Main._apply_menu_selection()) both read instead of every call site
## hardcoding the 3 .tres paths itself.
const ALL: Array[Faction] = [
	preload("res://Resources/Factions/HumanFaction.tres"),
	preload("res://Resources/Factions/OrcFaction.tres"),
	preload("res://Resources/Factions/BeastFaction.tres"),
]


static func random_pick() -> Faction:
	return ALL[SimRng.randi() % ALL.size()]
