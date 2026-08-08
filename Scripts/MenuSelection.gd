## Tiny hand-off between UI/MainMenu.gd and Main.gd: the two toggles the
## menu offers before starting a match. An autoload (see project.godot)
## rather than fields on GameManager, since GameManager's own doc comment
## already scopes itself to Battle Lifecycle/Player Registry/Unit
## Registry -- "what did the menu screen ask for" is a different, purely
## UI-transition concern that doesn't belong bolted onto it.
extends Node

var start_with_tournament: bool = false
var start_with_ai_opponent: bool = false
