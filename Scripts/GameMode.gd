## Base class for a game mode: owns win-condition logic and whatever
## match-level state a specific mode needs (round count, scoring, a
## throne's HP, ...). GameManager delegates to whichever GameMode is
## active (see GameManager.current_mode) instead of hardcoding a single
## win condition itself -- GameManager stays a mode-agnostic entity
## registry + lifecycle; what "winning" means is entirely up to the mode.
##
## The default, ClassicEliminationMode (Scripts/ClassicEliminationMode.gd),
## reproduces exactly the "team roster empty -> the other team wins"
## behavior this project always had, so a caller that never sets a mode
## sees no change at all.
class_name GameMode
extends RefCounted

enum VictoryResult { NONE, TEAM_WON, DRAW }


## True only when a battle could actually be started right now, given
## GameManager's current rosters -- default: both BLUE_TEAM_ID/RED_TEAM_ID
## have a unit (the original two-team prototype check, unchanged for
## ClassicEliminationMode, which doesn't override this). BloodTournamentMode
## overrides it to "at least 2 of GameManager.all_team_ids() have a unit,"
## since an N-team free-for-all shouldn't require every single one of the
## 8 registered slots to be filled before anyone can fight.
func can_start_battle() -> bool:
	return not GameManager.team_is_empty(GameManager.BLUE_TEAM_ID) and not GameManager.team_is_empty(GameManager.RED_TEAM_ID)


## Called by GameManager every time a unit dies during BATTLE, after
## roster bookkeeping (so team_is_empty() reflects the death that just
## happened). Returns {"result": VictoryResult.NONE} to keep the battle
## going, or {"result": TEAM_WON, "winning_team_id": int} /
## {"result": DRAW} to end it.
func check_victory() -> Dictionary:
	return {"result": VictoryResult.NONE}


## Called once when PLACEMENT -> BATTLE succeeds (GameManager.start_battle()).
func on_battle_started() -> void:
	pass


## Called once by GameManager.set_mode(), the instant this mode actually
## becomes current_mode -- BloodTournamentMode uses this to grant starting
## gold, since it needs to exist before the first round's PLACEMENT phase
## even happens (on_battle_started() would be too late: that only fires
## once Start Battle is pressed, after placement already needed the gold
## to be spendable). Deliberately not folded into _init() -- a GameMode
## can be constructed without ever being activated (see
## BloodTournamentMode's own tests), and a constructor mutating global
## Player state as a side effect of merely being built, rather than
## actually taking over the match, would be a trap for whatever builds one
## next.
func on_activated() -> void:
	pass


## Called once when a battle ends, win or draw -- e.g. BloodTournamentMode
## uses this to record the round's result and decide whether the match
## continues.
func on_battle_ended(_winning_team_id: int, _is_draw: bool) -> void:
	pass


## False (default) means Player.resources/UnitStats.cost are never
## consulted -- Main._try_place_unit()'s placement and
## GameManager.sell_unit()/buy_upgrade() all no-op their gold side of
## things, so a plain single-battle match stays exactly as free-to-place
## as it always was. BloodTournamentMode overrides this to true; a mode
## that wants gold is expected to also grant starting/round income itself
## (see BloodTournamentMode.on_activated()/on_battle_ended(), which walk
## GameManager.all_team_ids()) -- GameMode has no generic way to do that
## itself, since not every mode necessarily wants every registered team
## to receive gold.
func uses_economy() -> bool:
	return false


## Called by GameManager every time a unit dies during BATTLE with a
## still-valid killer -- a hook for a mode-specific kill reward (gold,
## XP, whatever). Unit.gain_xp() (hero leveling) always happens
## regardless of mode, since it's a Unit-level mechanic, not a
## GameMode one; this is for match-level rewards like
## BloodTournamentMode's gold bounty.
func on_unit_killed(_killer: Unit) -> void:
	pass


## False (default) means Main.gd keeps the plain flat 40x40 square arena
## live (GameManager.ARENA_HALF_EXTENT) -- every existing test and
## ClassicEliminationMode assume this shape, and nothing about it changes
## for a caller that never sets a cross-map mode. BloodTournamentMode
## overrides this to true for its 8-team cross-shaped map. Kept as its
## own GameMode query, independent of uses_economy(), since a future mode
## might want gold without the cross map (or vice versa).
##
## Deliberately separate from get_arena_map() below, not derived from it
## (e.g. `return get_arena_map() is CrossArenaMap`) -- this is read every
## physics frame per unit by Unit._clamp_to_arena()/_clamp_to_cross_arena(),
## and constructing a throwaway ArenaMap there just to type-check it would
## be a needless per-unit-per-frame allocation. The two must agree (see
## each concrete GameMode's own pair of overrides) but serve genuinely
## different callers: this one is a cheap shape-only bool a hot path
## reads constantly, get_arena_map() is the actual scene-building
## instance Main.gd only ever needs once per mode swap.
func uses_cross_map() -> bool:
	return false


## Which ArenaMap (Scripts/ArenaMap.gd) this mode wants built -- replaces
## what used to be a bool-driven if/elif in Main.gd with a real OOP
## extension point: a new mode wanting a new map shape overrides this to
## return a new ArenaMap subclass instance, and Main.gd (see
## Main._build_arenas()/_sync_arena_shape()) needs no per-shape
## branching to support it. Default: the plain square arena, matching
## uses_cross_map()'s own default -- every existing test/ClassicEliminationMode
## caller sees no change. A fresh instance every call (cheap, RefCounted,
## GDScript-idiomatic -- same as GameMode.check_victory() returning a
## fresh Dictionary every call) -- Main.gd only uses the returned
## instance's *type* to decide which of its own pre-built maps to
## activate, never the instance itself (see ArenaMap.gd's own doc
## comment for why building happens once, up front, not per mode swap).
func get_arena_map() -> ArenaMap:
	return SquareArenaMap.new()


## False (default) means BATTLE stays full manual RTS control -- every
## existing mode/test assumes this. BloodTournamentMode overrides this to
## true: units fight entirely on their own (Unit._maybe_auto_cast_abilities(),
## an auto-move ATTACK_MOVE-toward-center order issued at spawn -- see
## GameManager.spawn_unit()) and Main.gd's order/ability-cast input
## (right-click, S/H, Q/W/E) becomes a no-op during BATTLE. Selection
## itself is untouched -- inspecting a unit's health/cooldowns/status via
## the existing hotbar/buff-row UI still works, only *commanding* is
## blocked. Independent of uses_economy()/uses_cross_map(), same reasoning
## as those: a future mode might want one without the others.
func is_auto_battle() -> bool:
	return false


## Called every physics frame, unconditionally, from Main._physics_process()
## regardless of which mode is active (see BloodTournamentController.tick(),
## called right alongside this) -- a hook for continuous match logic that
## doesn't fit any of the discrete lifecycle callbacks above (on_battle_started/
## on_battle_ended/on_unit_killed all fire once, at a specific transition).
## HeroFootiesMode uses this for its wave-spawner timer. Default no-op, so
## every existing mode (ClassicEliminationMode, BloodTournamentMode, which
## does its own equivalent orchestration through the separate
## BloodTournamentController instead) costs nothing extra. Not gated on
## GameManager.is_battle_active() here -- a mode that only wants to act
## mid-battle checks that itself, same as it already would for any other
## state it cares about.
func tick(_delta: float) -> void:
	pass
