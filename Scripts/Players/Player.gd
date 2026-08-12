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
## The race this player is building from -- gates which archetypes
## HUD._build_unit_panel() shows (HUD.refresh_unit_panel_for_faction())
## and which ones AIController.take_turn() will buy
## (AIController._affordable_units()). Assigned once per match by
## Main._apply_menu_selection(), and ONLY under Blood Tournament (the lobby's
## chosen faction for the human slot, FactionRegistry.random_pick() for
## every other team) -- unconditional assignment regardless of mode was
## tried and reverted: Player is a persistent RefCounted, so it gave
## every classic-mode match/test a random faction whether it asked for
## one or not. Stays null for classic mode/Hero Footies and any test that never goes
## through the menu at all -- both HUD's and AIController's own gates
## treat null as "ungated," the full archetype list, unchanged from
## before this feature existed.
var faction: Faction = null
## Gold -- only meaningful while GameManager.current_mode.uses_economy() is
## true (see GameMode.gd/BloodTournamentMode.gd); stays 0 and unused for
## a plain single-battle match, same as before this field had real
## behavior behind it. BloodTournamentMode grants a starting amount and
## round-end income directly via add_gold(); spend()/can_afford() are what
## Main.gd's placement/sell/upgrade flows check against.
var resources: int = 0
## A second, separate currency from `resources` (gold) -- earned only
## from kills (see BloodTournamentMode.on_unit_killed()), spent only on
## unit upgrades (see GameManager.buy_upgrade()). Gold is deliberately
## flat/equal for every player each round (BloodTournamentMode.PARTICIPATION_INCOME,
## no win bonus); blood points are what actually rewards playing well,
## kept separate so a losing round's flat gold share can't buy the same
## power spike a kill-heavy round earns.
var blood_points: int = 0
## Raw kill count, tracked alongside blood_points (both incremented
## together in BloodTournamentMode.on_unit_killed()) -- blood_points is
## the spendable currency a kill earns, this is just the count itself,
## for display (see BloodTournamentController.scoreboard_text()). Never
## reset between rounds, same "persists for the whole match" lifetime
## roster/roster_upgrades already have.
var kills: int = 0
## Ordered list of purchased archetypes (UnitStats), one entry per
## purchased "slot" -- the durable source of truth for what this player
## owns, persisting across every Blood Tournament round (see
## GameManager.reset_battle()). No permadeath: a slot stays on the roster
## until the player explicitly sells it (GameManager.sell_roster_slot()),
## regardless of whether that round's copy died in battle. Unused (stays
## empty) for a plain single-battle match, same as `resources`.
var roster: Array[UnitStats] = []
## Index-aligned with `roster` -- courtyard_units[i] is the live Array[Unit]
## squad currently standing in this team's lineup courtyard for roster[i]
## (see CrossArenaMap.get_courtyard_position()). Purely a derived,
## ephemeral cache: GameManager.sync_courtyard_to_roster() is what keeps
## it matching `roster`, and GameManager.reset_battle() clears it every
## round (the Units themselves are freed there too) -- `roster` is always
## the thing that actually persists, this is just its live-instance
## reflection whenever any exist.
var courtyard_units: Array = []
## Blood-point-cost upgrades bought during PLACEMENT (see
## GameManager.buy_roster_upgrade()) -- account-wide, not tied to one
## roster slot: applied to every unit in every squad
## sync_courtyard_to_roster() spawns into the courtyard from then on, not
## just whatever was purchased most recently. Persists the same way
## `roster` does -- reset_battle() never clears it, only an explicit sell
## would (no sell exists for this yet, matching the "buy an upgrade" shop
## having no refund path either).
var roster_upgrades: Array[UnitUpgrade] = []
## Blood-point-cost, per-archetype upgrades bought during PLACEMENT (see
## GameManager.buy_archetype_upgrade()) -- unlike roster_upgrades (a flat
## stat buff, applies to every squad), each entry here only affects
## squads of its own ArchetypeUpgrade.archetype, and can change squad
## composition (bonus units), not just stats. Persists the same way
## roster/roster_upgrades do -- reset_battle() never clears it.
var archetype_upgrades: Array[ArchetypeUpgrade] = []
## UnitStats (a hero archetype, e.g. HeroStats.tres) -> {"level": int,
## "xp": float} -- persists a hero's level/XP across Blood Tournament
## rounds the same way `roster` itself persists which archetypes are
## owned. Without this, every round's staggered deployment
## (Unit.restore_hero_progress()) would spawn a brand-new level-1 Unit
## instance from the archetype template regardless of what a hero
## earned in a previous round, since reset_battle() frees every Unit
## node between rounds and roster only remembers *which* archetypes are
## owned, not any individual instance's runtime state. Written by
## Unit.gain_xp() every time a hero's level/XP actually changes, read by
## BloodTournamentController.deploy_next_pending_slot() right after a
## fresh hero Unit spawns. Keyed by the archetype resource itself, not a
## roster index (which would shift under a sell) or a per-instance id
## (which wouldn't survive the instance's own death/free) -- the
## practical implication (spelled out here rather than solved, since
## nothing in the UI stops it and it's a real edge case): if a player
## buys the SAME hero archetype twice, both roster slots share one
## combined progress record rather than leveling independently. Not
## worth a per-slot tracking structure for a case the economy already
## discourages (a hero's cost + squad_size == 1 means buying a second
## copy is a large, deliberate spend) and nothing has asked for.
var hero_progress: Dictionary = {}
## UnitStats (a hero archetype) -> {slot_index: int -> chosen candidate
## index}. Which candidate (see UnitStats.ability_draft_choices) this
## player picked for each of a hero archetype's drafted ability slots --
## set via GameManager.pick_hero_ability(), read by
## Unit._resolve_abilities(). A slot index missing here (including the
## common case: an archetype with no drafted slots at all) means "use
## candidates[0], the default." Same per-archetype-not-per-instance
## simplification hero_progress above already uses, for the same reason:
## buying the same hero archetype twice shares one combined draft rather
## than choosing independently per copy.
var hero_ability_picks: Dictionary = {}


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


func can_afford_blood_points(amount: int) -> bool:
	return blood_points >= amount


func spend_blood_points(amount: int) -> void:
	blood_points -= amount


func add_blood_points(amount: int) -> void:
	blood_points += amount


const EXCHANGE_GOLD_PER_CLICK := 50
const EXCHANGE_BLOOD_PER_CLICK := 25

## Unlike spend()/spend_blood_points(), these two are self-guarding
## (false on failure) -- each click should give unambiguous
## success/fail feedback rather than needing a separate affordability
## check first. Symmetric 2:1 rate both directions, so round-tripping
## nets zero.
func exchange_gold_for_blood_points() -> bool:
	if not can_afford(EXCHANGE_GOLD_PER_CLICK):
		return false
	spend(EXCHANGE_GOLD_PER_CLICK)
	add_blood_points(EXCHANGE_BLOOD_PER_CLICK)
	return true


func exchange_blood_points_for_gold() -> bool:
	if not can_afford_blood_points(EXCHANGE_BLOOD_PER_CLICK):
		return false
	spend_blood_points(EXCHANGE_BLOOD_PER_CLICK)
	add_gold(EXCHANGE_GOLD_PER_CLICK)
	return true
