## Data-driven definition of a unit archetype (Tank, Fighter, Archer, ...).
##
## Stored as a Resource (.tres) so new unit types can be added or tuned
## from the editor without touching code. See Resources/TankStats.tres,
## FighterStats.tres, and ArcherStats.tres for the concrete archetypes
## used by the prototype.
class_name UnitStats
extends Resource

@export var unit_name: String = "Unit"
@export var icon: Texture2D ## Shown on the build-menu/roster-row buttons (HUD.gd). Null is fine, just renders with no icon.
## Which named Faction (see Scripts/Players/Faction.gd) this archetype belongs to --
## purely cosmetic/organizational (HUD build-menu grouping, ground-ring
## accent color). Null (e.g. Builder/Throne/Goblin fixtures) means no
## grouping/accent at all, not an error.
@export var faction: Faction = null

@export_group("Economy")
## Gold cost to place this archetype -- only enforced while
## GameManager.current_mode.uses_economy() is true (see Main._try_place_unit()).
## Irrelevant, and never checked, for a plain single-battle match.
@export var cost: int = 0
## How many actual battlefield Units one purchased "slot" of this
## archetype deploys -- see GameManager.spawn_squad(), the shared entry
## point every purchase/roster-respawn call site uses instead of
## spawn_unit() directly. `cost` above is charged once per *slot*, not
## per squad member -- buying one Fighter slot for its listed cost still
## fields the whole squad. Deliberately inverse to power: a cheap/weak
## archetype should field more bodies than an expensive/tanky one (see
## the concrete archetypes' own .tres files for actual tuning). 1
## (default) means "no squad concept for this archetype" -- exactly
## today's one-purchase-one-unit behavior, so anything that doesn't
## explicitly set this is unaffected.
@export var squad_size: int = 1

@export_group("Combat")
@export var max_health: float = 100.0
@export var damage: float = 10.0
## Reach beyond this unit's own collision_radius, to the target's
## center -- not raw center-to-center distance. See
## Unit._distance_to_target_edge(). Keeps this a per-unit constant
## independent of the target's size, and leaves room for multiple
## attackers to stand in range of one target without their own bodies
## overlapping (a real problem when a unit's radius is a large fraction
## of its attack_range, as Giant's is).
@export var attack_range: float = 2.0
## How far (from this unit's own current position) GameManager.find_nearest_enemy()
## will even consider an enemy for autonomous default-AI targeting
## (Unit._update_target(), used whenever current_order == null, plus the
## ATTACK_MOVE/PATROL/FOLLOW/HOLD orders' own "fight anything encountered"
## fallback). Deliberately distinct from attack_range -- this is reach for
## *noticing* an enemy exists at all, not reach for actually hitting one.
## Comfortably above every archetype's attack_range so units still
## naturally engage anything nearby, but well short of the 40x40 arena's
## own diagonal, so an idle unit no longer walks clear across the map to
## fight something on the other side of it (a real rough edge this
## project shipped with from the start, see BattleFoundry-Roadmap.md).
@export var acquisition_range: float = 12.0
@export var attack_interval: float = 1.0 ## Seconds between attacks.
## Seconds of delay between a swing committing (attack_interval's
## cooldown allowing it) and the hit actually landing -- see
## Unit._attack()/_release_attack_at(). 0.0 (default, every archetype
## until this field is explicitly set on a resource) lands the hit the
## same frame the swing commits, i.e. exactly the pre-windup behavior;
## a locked-in target from swing-commit time is used at release, not
## whatever target_enemy is by then, so a re-target mid-swing can't
## redirect an already-committed hit.
@export var attack_windup: float = 0.0
## Splash/cleave: 0.0 (default, every archetype until this is explicitly
## set) means a plain single-target attack, exactly the pre-splash
## behavior. Above 0.0, every OTHER hostile unit within this radius of
## the primary target (not the attacker) also takes splash damage -- see
## Unit.resolve_hit()/_apply_splash_damage(). Deliberately a separate,
## simpler mechanic from Ability.aoe_radius: this is an *auto-attack*
## property (armor/attack-armor-table mitigation still applies per
## splashed target, on_hit_ability does NOT re-trigger for them), not an
## ability cast.
@export var splash_radius: float = 0.0
## Damage multiplier for a splashed unit sitting exactly at the edge of
## splash_radius -- linearly interpolated between 1.0 (full damage) at
## the primary target's own position and this value at splash_radius
## distance from it. Only read when splash_radius > 0.0.
@export var splash_falloff: float = 0.5
## Degrees per second this unit can rotate to face target_enemy before a
## swing can commit -- see Unit._attack()/_face_toward(). 0.0 (default,
## every existing archetype) means facing is never checked at all before
## attacking, exactly the pre-turn-rate behavior (a unit could always
## fire immediately regardless of which way it was pointing). Above 0.0,
## _attack() won't let a new swing commit until the unit has rotated to
## face target_enemy within a small tolerance -- while still turning,
## neither the swing nor its attack_interval cooldown advances that
## frame.
@export var turn_rate: float = 0.0
## Chance [0.0, 1.0] to avoid an incoming ATTACK entirely -- see
## Unit.take_damage(). 0.0 (default, every existing archetype) never
## evades, exactly the pre-evasion behavior; 1.0 always evades. Only
## ATTACK damage can be evaded, matching WC3's own evasion convention
## (SPELL/PURE always land).
@export_range(0.0, 1.0) var evasion: float = 0.0
## Chance [0.0, 1.0] for this unit's own attack to deal crit_multiplier x
## damage instead of its normal amount -- rolled once per swing in
## Unit.resolve_hit(), before armor/the attack-armor table (WC3's own
## ordering: crit multiplies the raw hit, mitigation happens after). If
## this swing also splashes (UnitStats.splash_radius), the same crit (or
## lack of one) applies to the splash damage too -- one roll per attack,
## not a separate roll per target hit. 0.0 (default, every existing
## archetype) never crits, exactly the pre-crit behavior.
@export_range(0.0, 1.0) var crit_chance: float = 0.0
## Only read when crit_chance > 0.0.
@export var crit_multiplier: float = 2.0
## Whether this unit can target a flying enemy at all. False by default
## (the classic "ground can't hit air" RTS convention) so a new
## archetype has to opt in rather than opt out -- see
## GameManager.find_nearest_enemy(). Irrelevant for a flying unit
## attacking a ground one; that's always allowed.
@export var can_attack_flying: bool = false
## Flat damage reduction applied to incoming ATTACK/SPELL damage (not
## PURE -- see DamageInstance). Seeds StatBlock.base_armor; buffs/debuffs
## modify the runtime copy, never this archetype value.
@export var armor: float = 0.0

## WC3-style attack-type x armor-type multiplier grid (see
## Scripts/Combat/AttackArmorTable.gd), layered on top of the flat armor
## reduction above -- only for ATTACK damage (Unit.take_damage()); SPELL
## damage still only ever sees the flat armor reduction, matching WC3's
## own "the type table doesn't apply to spells" convention. NORMAL x
## MEDIUM (both defaults below) is a 1.0 multiplier, so any archetype
## that never sets these two fields explicitly sees zero change in
## damage taken/dealt from before this table existed.
enum AttackType { NORMAL, PIERCING, SIEGE, HERO }
enum ArmorType { UNARMORED, LIGHT, MEDIUM, HEAVY, FORTIFIED, HERO }
@export var attack_type: AttackType = AttackType.NORMAL
@export var armor_type: ArmorType = ArmorType.MEDIUM

@export_group("Abilities")
## Index 0/1/2 map to the Q/E/R hotkeys in Main.gd. NO_TARGET/UNIT_TARGET
## abilities here are player-triggered via Unit.cast_ability(); a PASSIVE
## one here is instead applied once, automatically, at spawn (see
## Unit._apply_passive_abilities()) -- it still lives in this same array,
## it just never responds to a hotkey since cast_ability() rejects
## PASSIVE. ON_HIT abilities don't go here at all -- see on_hit_ability
## below. An empty array is the common case: most archetypes have no
## abilities at all.
@export var abilities: Array[Ability] = []
## Only meaningful when is_hero is true. ability_draft_choices[i], if
## non-empty, is the set of candidate Abilities the player picks ONE of
## for slot i (see Player.hero_ability_picks/Unit.resolved_abilities) --
## abilities[i] itself stays the DEFAULT (candidates[0]) applied
## automatically if the player never makes an explicit pick before this
## hero reaches ability_unlock_levels[i]. Empty (default, every
## non-drafting archetype) means slot i has no choice at all, identical
## to the plain fixed-unlock behavior abilities/ability_unlock_levels
## always had before this field existed.
@export var ability_draft_choices: Array[AbilityChoiceSet] = []
## Fires automatically from Unit.resolve_hit() every time this archetype
## lands an attack -- e.g. Giant's knockback (Resources/GiantSlamAbility.tres).
## null (default, most archetypes) means no on-hit effect at all.
@export var on_hit_ability: Ability = null
## Ticked continuously by Unit._tick_aura() -- must be an Ability with
## cast_type == Ability.CastType.AURA (see Ability.apply_aura()). null
## (default, most archetypes) means this unit projects no aura at all.
@export var aura_ability: Ability = null

@export_group("Projectile")
## 0 (default) means this attack deals damage the instant the cooldown
## allows, exactly like every archetype before this system existed.
## Above 0, Unit._attack() spawns a Projectile (Scripts/Combat/Projectile.gd)
## instead, which delivers the hit -- damage and any knockback -- only
## once it actually arrives, via Unit.resolve_hit().
@export var projectile_speed: float = 0.0
## Only read when projectile_speed > 0. True (default): the projectile
## tracks its target's current position every frame (WC3 arrows/most
## ranged autoattacks). False: aims once at the target's position at the
## moment it's fired and travels a straight line from there, so it can
## miss if the target moves out of the way before it arrives.
@export var projectile_homing: bool = true

@export_group("Movement")
@export var move_speed: float = 3.0 ## Meters per second.

@export_group("Flight")
## Flying units rest at flight_height instead of the ground plane, and
## combat range checks become horizontal-only for everyone as a result
## -- see Unit.horizontal_distance_to(). False (default) means this
## unit behaves exactly as before: ground-locked at y=0.
@export var is_flying: bool = false
@export var flight_height: float = 0.0

@export_group("Collision")
## Radius of the unit's physical footprint (a CapsuleShape3D in Unit.gd).
## Larger values make a unit harder to path around and more effective at
## physically blocking others -- this is how "tanks block movement" is
## expressed, entirely through data rather than unit-specific code.
@export var collision_radius: float = 0.5

@export_group("Hero")
## True for a Hero archetype -- enables Unit.gain_xp()/level growth and the
## ability_unlock_levels gate below. False (default, every non-hero
## archetype) means Unit.level/xp are simply never touched by anything.
@export var is_hero: bool = false
## Parallel to `abilities` -- ability_unlock_levels[i] is the minimum
## Unit.level required to cast abilities[i] (see Unit.cast_ability()).
## Only consulted when is_hero is true; a missing/0 entry means "always
## available," so leaving this empty (every non-hero archetype) is never a
## behavior change from before Heroes existed.
@export var ability_unlock_levels: Array[int] = []

## True only for the Blood Tournament "Builder" fixture (see
## Resources/Units/BuilderStats.tres) -- the one archetype a player never
## buys/sells and can never right-click-sell by accident
## (PlayerInputController.try_sell_unit_at() checks this before treating a
## courtyard click as a sale). False (default, every purchasable
## archetype) is never a behavior change.
@export var is_builder: bool = false

@export_group("Death Escalation")
## Goblin-boss-round mechanic (see BattleFoundry-Roadmap.md's goblin boss
## round item): if set, killing this unit doesn't end it -- GameManager._on_unit_died()
## spawns one fresh unit of this archetype at the same position instead
## of a normal corpse/decay, owned by the same Player (so team/hostility
## carries over unchanged). Mutually exclusive with split_into_on_death/
## split_into_self_on_death below -- a unit revives bigger, splits
## smaller, or splits into itself on death, never more than one; revive
## wins if more than one is somehow set. null (default, every normal
## archetype) means a completely ordinary death, unaffected.
@export var revive_as_on_death: UnitStats = null
## Goblin-boss-round mechanic: if set (and revive_as_on_death is null),
## killing this unit spawns split_count fresh units of this archetype,
## fanned out around the same position, instead of a normal corpse/decay.
## null (default) means a completely ordinary, final death.
@export var split_into_on_death: UnitStats = null
## Goblin-boss-round mechanic: if true (and both fields above are null/false),
## killing this unit spawns split_count fresh units of THIS SAME archetype
## instead of a normal corpse/decay -- a self-referencing escalation.
## Exists as its own bool rather than split_into_on_death pointing at its
## own resource because Godot's text resource format (.tres) doesn't
## support an ext_resource entry referencing the very file being parsed
## (a genuine parse error, confirmed -- not just a style choice).
## GoblinSplitStats.tres ("Goblin Runt", this project's smallest goblin
## tier) sets this true, so the escalation chain never actually
## terminates -- deliberate: the goblin boss round is designed to always
## end in the competing team's own units wiping (see
## BloodTournamentMode.check_victory()'s own doc comment), not in the
## goblin side running out of reinforcements.
@export var split_into_self_on_death: bool = false
@export var split_count: int = 2

@export_group("Appearance")
## Which primitive mesh represents this unit. Team color is applied
## separately at spawn time, so archetypes are told apart by shape/size.
@export_enum("Box", "Capsule", "Cone") var mesh_shape: String = "Box"
## Interpreted per-shape in Unit.gd:
## Box -> full size (x, y, z). Capsule -> radius (x), height (y).
## Cone -> base radius (x), height (y).
@export var mesh_size: Vector3 = Vector3(1.0, 1.0, 1.0)
