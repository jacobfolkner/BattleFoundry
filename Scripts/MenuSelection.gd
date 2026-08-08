## Tiny hand-off between UI/MainMenu.gd and Main.gd: the two toggles the
## menu offers before starting a match. An autoload (see project.godot)
## rather than fields on GameManager, since GameManager's own doc comment
## already scopes itself to Battle Lifecycle/Player Registry/Unit
## Registry -- "what did the menu screen ask for" is a different, purely
## UI-transition concern that doesn't belong bolted onto it.
extends Node

var start_with_tournament: bool = false
var start_with_ai_opponent: bool = false
## Which of the 8 registered teams the player picked in UI/MainMenu.gd's
## team selector -- Main._apply_menu_selection() makes every OTHER team
## non-human when start_with_ai_opponent is also true (generalizes the
## old single Blue-human/AI-Red assumption to any of the 8 teams).
## Defaults to GameManager.BLUE_TEAM_ID, matching the original hardcoded
## behavior for any caller that never touches this (most GUT tests). A
## plain `const` read, not GameManager's runtime state, so this is safe
## as a field initializer regardless of autoload init order.
var human_team_id: int = GameManager.BLUE_TEAM_ID
## How many of the 8 registered teams actually play this Blood
## Tournament match, from 2 (minimum -- a match needs an opponent) to 8 --
## confirmed design: "fill all slots with bots or just some of them."
## Only meaningful alongside start_with_ai_opponent (the human's own team
## plus this many AI-controlled ones -- see Main._apply_menu_selection());
## harmless to leave at its default otherwise. Defaults to
## GameManager.TEAM_COUNT (8, every registered team fights) -- the
## already-built full 8-team experience stays the default, this field
## only lets the player dial it down.
var team_count: int = GameManager.TEAM_COUNT
