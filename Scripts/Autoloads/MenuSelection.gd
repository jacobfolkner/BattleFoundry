## Tiny hand-off between UI/MainMenu.gd and Main.gd: the two toggles the
## menu offers before starting a match. An autoload (see project.godot)
## rather than fields on GameManager, since GameManager's own doc comment
## already scopes itself to Battle Lifecycle/Player Registry/Unit
## Registry -- "what did the menu screen ask for" is a different, purely
## UI-transition concern that doesn't belong bolted onto it.
extends Node

var start_with_tournament: bool = false
## Mutually exclusive with start_with_tournament in UI/MainMenu.gd itself
## (both toggles claim GameManager.current_mode, same guard Main.gd's own
## in-match HUD handlers already enforce) -- see Main._apply_menu_selection().
var start_with_hero_footies: bool = false
## Which of the 8 registered teams the player picked as "You" in
## UI/MainMenu.gd's per-slot lobby. Defaults to GameManager.BLUE_TEAM_ID,
## matching the original hardcoded behavior for any caller that never
## touches this (most GUT tests). A plain `const` read, not GameManager's
## runtime state, so this is safe as a field initializer regardless of
## autoload init order.
var human_team_id: int = GameManager.BLUE_TEAM_ID
## Which of the OTHER 7 registered teams the player explicitly marked
## "Bot" in the lobby -- any number, not a blanket on/off toggle or a
## fixed count (confirmed design: "add bots to as many slots as I want").
## A slot in neither this array nor human_team_id is "Empty" -- never
## funded, never AI-controlled, simply doesn't play (see
## Main._apply_menu_selection()). Empty array (default) means "no bots
## explicitly chosen," which Main._apply_menu_selection() treats as
## "every registered team plays," matching the original pre-lobby
## behavior of a plain "Blood Tournament: On" with no opponent setup.
var bot_team_ids: Array[int] = []
## Per-team race picks (UI/MainMenu.gd's per-slot faction picker, one per
## lobby row -- every slot gets one, not just the human's) -- team_id ->
## Faction. A team_id absent from this dictionary means "Random" (the
## default for every slot), consumed by Main._apply_menu_selection() the
## same consume-and-clear way every other field here is (see
## apply_selection_to_menu_state()'s own doc comment on why that's safe).
var chosen_factions: Dictionary = {}
## Explicit override for which teams play this match, bypassing the
## human_team_id/bot_team_ids-derived computation in
## Main._apply_menu_selection() entirely -- that derivation requires
## bot_team_ids to be non-empty to restrict the active set at all (an
## empty bot_team_ids means "every registered team plays," the original
## pre-lobby default), which has no way to express "exactly these two
## teams, both human, no bots" -- exactly what a LAN multiplayer 1v1
## needs (UI/MainMenu.gd's Host/Join flow). Empty array (default) means
## "no override, use the existing bot_team_ids-derived logic" -- every
## single-player/local caller is unaffected.
var active_team_ids: Array[int] = []
