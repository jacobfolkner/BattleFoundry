# BattleFoundry

A modular RTS engine, inspired by Warcraft III custom games, built to share
core systems (units, combat, teams) across multiple future game modes.

The first playable prototype is a simplified recreation of the Warcraft III
custom map **Blood Tournament**: place units for two teams, press Start
Battle, and watch them fight automatically until one side wins.

## Status: Sprint 5 — Engine Observability

- Two teams (Blue / Red)
- Three unit archetypes: Tank, Fighter, Archer
- Click-to-place unit placement phase
- Fully automatic combat (nearest-enemy targeting, move-into-range, attack)
- Units have physical presence: they can no longer overlap, push against
  each other, and naturally form battle lines instead of stacking
- Units are hard-constrained to the ground plane: dense spawning or
  collision resolution can no longer launch or vertically stack them
- Health bars above every unit, live-updated as damage is taken
- Win detection when one team is eliminated, with a visible winner banner
- Click any unit (placement or mid-battle) to select it and open a live
  debug panel showing its state; a marker under it and a line to its
  current target make the selection visible in the arena itself

Out of scope for this milestone (see project brief): abilities, heroes,
buildings, economy, animations, particles, networking, fog of war,
pathfinding, save/load, a map editor, and audio.

## Requirements

- [Godot 4.7](https://godotengine.org/) (GDScript, Forward+ renderer).
  Originally targeted 4.4; verified running on 4.7.1.

## Running

Open this folder as a project in Godot and press **Run** (F5). The main
scene is `Scenes/Main.tscn`.

1. Pick a unit type (Tank / Fighter / Archer) and a team (Blue / Red) in
   the top-left panels.
2. Click inside the arena to place units. Repeat for both teams.
3. Press **Start Battle** (below the team buttons). Units automatically
   seek the nearest enemy, close distance, and attack until one team is
   eliminated. Each unit's health bar shrinks and shifts from green to
   red as it takes damage, and disappears with the unit when it dies.
4. The winning team is announced in a centered banner.

Click directly on any unit at any time (placement, mid-battle, or after
a win) to select it: a flat disc appears under it, a line is drawn to
its current target if it has one, and a panel in the top-right corner
shows its live stats. Clicking a unit takes priority over placing a new
one, so clicking on top of an existing unit during placement selects it
instead of stacking another unit there.

## Project Structure

```
Scenes/     Scene files (.tscn) — Main arena, Unit
Scripts/    Gameplay logic (.gd) — Team, UnitStats, Unit, HealthBar, GameManager,
            Main, DebugInspector
Resources/  Data-driven unit archetypes (.tres) — Tank/Fighter/Archer stats
Assets/     Reserved for future imported art (empty — primitives only today)
UI/         HUD, DebugPanel scenes/scripts
```

### Architecture notes

- **UnitStats** (`Scripts/UnitStats.gd`) is a `Resource`, so new unit
  archetypes are authored as `.tres` data files, not code.
- **Unit** (`Scripts/Unit.gd`) owns per-unit state and combat behavior.
  It builds its own primitive mesh from `UnitStats` at spawn time and is
  colored by team, so archetypes are told apart by shape/size, not color.
  It's a `CharacterBody3D`, so it also builds a `CapsuleShape3D` sized by
  `UnitStats.collision_radius` and moves via `move_and_slide()` — see
  "Collision approach" below.
- **HealthBar** (`Scripts/HealthBar.gd`) is a standalone display
  component: two billboarded primitive quads (background + fill), driven
  entirely by `set_fraction()`. It knows nothing about combat or
  `UnitStats`, so any future entity (not just Unit) can reuse it. `Unit`
  creates one per spawn, positioned above its mesh, and updates it in
  `take_damage()`; because it's a child of Unit, it's freed automatically
  when the unit dies.
- **GameManager** (`Scripts/GameManager.gd`) is an autoload singleton and
  the only global piece of state. It tracks battle phase, registers
  units per team, and resolves win conditions. Units and UI talk to it
  rather than to each other, which keeps both reusable by future game
  modes.
- **HUD** (`UI/HUD.gd`) only emits signals — it never reaches into
  GameManager directly — for the same reason. Its controls are laid out
  with `VBoxContainer`/`CenterContainer` flow rather than manual anchors;
  see the code comments on `_build_start_button` and `_build_winner_label`
  for why manual `position`/`size` on a not-yet-parented Control is a
  trap in Godot 4.7 (it resolves against a zero-size parent rect).
- **DebugInspector** (`Scripts/DebugInspector.gd`) and **DebugPanel**
  (`UI/DebugPanel.gd`) are a separate observation layer, not part of
  gameplay — see "Observability" below.

Movement is a direct straight-line walk toward the current target (no
steering or pathfinding, and target selection is unchanged); this is
intentional for readability and is the first thing a future "movement
system" milestone would replace.

### Collision approach

Each `Unit` is a `CharacterBody3D` carrying a single `CapsuleShape3D`
(built at runtime from `UnitStats.collision_radius`, the same
data-driven pattern as its visual mesh). Every physics frame it sets
`velocity` from the existing AI logic (unchanged) and calls
`move_and_slide()` — Godot's physics server does the actual overlap
resolution and sliding against every other unit's capsule. There is no
custom "find nearby units and push them apart" code anywhere in this
codebase.

Why this is the scalable choice, not just the convenient one:

- **Broad-phase collision is the engine's job, not the AI's.** The
  physics server spatially partitions bodies so it only tests capsules
  that are actually near each other. A hand-rolled overlap check in
  GDScript (`for each unit, for each other unit, check distance`) is
  O(n²) *in script* with no partitioning — that's the "custom overlap
  code" the sprint brief explicitly said to avoid, and it's the part
  that would fall over first at hundreds of units.
- **`CharacterBody3D` is kinematic, not a full rigid body.** It gets
  depenetration and sliding without the cost of mass/inertia/constraint
  solving that a `RigidBody3D` would carry for every unit — we don't
  need units to be knocked around or stacked, just to not overlap.
- **A dedicated "Units" physics layer** (`collision_layer`/
  `collision_mask = 2`, named in `project.godot`) keeps the collision
  query scoped to unit-vs-unit only, so adding future non-unit colliders
  (terrain props, a building later) won't add unrelated pairs to check.
- **Tank blocking and battle-line formation are emergent, not
  scripted.** `collision_radius` is just data — Tank's is larger, so it
  occupies more space and is harder to path around; nothing in `Unit.gd`
  checks "am I a Tank." Lines form because units already stop at
  `attack_range` and now can't stack on the way there, so a cluster
  converging on the same enemy spreads out shoulder-to-shoulder instead
  of piling into one point.
- `move_and_slide()` is called every physics frame regardless of battle
  state (with `velocity = Vector3.ZERO` outside of BATTLE), so it also
  passively separates units placed too close together during the
  placement phase, for free.

**Grounding fix (Sprint 4):** `MOTION_MODE_FLOATING` resolves overlap
along whichever axis has the least penetration, and for units spawned
at or very near the same point that axis is ambiguous — their capsules
are coincident vertically too, so the physics server would occasionally
push one straight up instead of sideways, with nothing to bring it back
down (no gravity) and nothing stopping a second unit sliding underneath
it at true ground level. `Unit._physics_process()` now ends with
`global_position.y = 0.0` immediately after `move_and_slide()`, every
frame, for every unit — a hard invariant rather than a plausibility. It
doesn't touch horizontal resolution at all, so battle lines and tank
blocking are unaffected. The tradeoff: this assumes the game has no
vertical gameplay (jumping, ramps, flight); if one is ever added, this
line is exactly what would need to become conditional or be replaced by
per-body axis locking.

### Observability

Sprint 5 adds a way to inspect a unit's live state without changing any
gameplay code. It's built as a separate layer that only ever *reads*
from Unit and GameManager, never writes to either:

- **`Unit.get_debug_info() -> Dictionary`** is the entire contract. It's
  a pure addition to `Unit.gd` — no existing method was touched to add
  it — and it returns pre-formatted display strings ("Name", "Team",
  "Health", "AI State", "Target", "Distance to Target", "Attack Range",
  "Attack Cooldown", "Position"). "AI State" (`_describe_state()`) is
  derived by re-reading the same public fields `_physics_process()`
  already branches on (`current_health`, `GameManager.battle_state`,
  `target_enemy`, distance vs. `attack_range`) — it's a second read of
  that state for display purposes, not a second source of truth, and it
  can't feed back into the AI because nothing ever calls it except the
  debug layer.
- **`DebugInspector`** (autoload) owns *selection*: which unit is
  picked, a physics raycast (`try_select_at()`, masked to the "Units"
  layer from Sprint 3) to find it from a screen click, and two small
  cosmetic 3D indicators (a disc under the selected unit, a line to its
  target) that it positions every frame by reading `global_position`
  and `target_enemy` — the same public fields anything else in the
  codebase could already read. `Main.gd` gives it first refusal on every
  click (`DebugInspector.try_select_at(...)`) before falling through to
  placement; that's the one integration point, and it's a single method
  call, not a dependency in either direction beyond it.
- **`DebugPanel`** (`UI/DebugPanel.gd`) never touches `Unit` or
  `GameManager` at all. It listens to `DebugInspector.selection_changed`
  and, every frame there's a valid selection, calls
  `get_debug_info()` and renders each key/value pair generically —
  `for key in info: ... "%s: %s"`. There's no per-field UI element and
  no formatting logic keyed to specific field names.

**Why future systems don't need to touch the panel:** anything —
a future building, a projectile, a second game mode's entity — that
adds its own `get_debug_info() -> Dictionary` method and gets selected
(by whatever means makes sense for it) is displayed correctly the
moment `DebugPanel` receives it, because the panel's rendering loop has
no knowledge of what a "Unit" is. The coupling is one shared method
name and return shape, not a shared base class or a growing switch
statement in the panel.

**Why gameplay stays untouched:** every requirement this sprint could
be met by *reading* existing state, so nothing needed write access.
The riskiest-looking change, `Main.gd`'s click routing, only reorders
*which* handler a click reaches first — the placement code path itself
(`_try_place_unit`) is byte-for-byte unchanged.

## Testing

Automated tests use [GUT](https://github.com/bitwes/Gut) (`addons/gut/`,
fetched by `tools/fetch_gut.sh` rather than vendored — see below) and run
fully headless — no X server, Xvfb, or WSLg required, since these tests
exercise game logic and physics (`move_and_slide`, combat, win detection)
rather than rendering. `tests/test_battle_flow.gd` boots the real
`Main.tscn`, spawns units through `GameManager.spawn_unit()` (the same
entry point Main.gd's click-to-place uses), starts the battle, and
asserts a winner is resolved through the actual simulation — no mocking.

### One-time setup (fresh clone, any machine including WSL)

1. Install [Godot 4.7](https://godotengine.org/) and put the `godot`
   binary on `PATH`.
2. Fetch GUT. `addons/gut/` is gitignored (it's ~260 static third-party
   files that never change once fetched, so vendoring it in git just
   bloats every diff) — this script downloads the pinned version,
   verifies its checksum, and is a safe no-op if already present:

   ```sh
   ./tools/fetch_gut.sh
   ```

3. Run an import pass once. `.godot/` (Godot's import cache) is
   gitignored, so a fresh clone has no import metadata yet — GUT's
   class_names won't resolve without this step, and the error is
   `Some GUT class_names have not been imported.`:

   ```sh
   godot --headless --editor --quit
   ```

### Running the suite

```sh
godot --headless -s addons/gut/gut_cmdln.gd -gdir=res://tests -gexit
```

Exits 0 on success. Re-run the import step above if `addons/gut` is ever
updated (bump the version in `tools/fetch_gut.sh` first) or a new addon
is added.

### CI

`.github/workflows/ci.yml` fetches GUT (cached by
`actions/cache`, keyed on `tools/fetch_gut.sh`'s contents so a version
bump invalidates it automatically), then runs the import check and GUT
suite on every push to `main` and every pull request.

## Next Recommended Milestone

Candidates once this sprint is validated in-editor:

- **Smarter targeting**: `GameManager.find_nearest_enemy()` is still an
  O(n) linear scan per unit per physics frame (explicitly left alone
  this sprint) — worth revisiting once unit counts grow, independently
  of the collision work done here.
- **Placement polish**: unit count limits, a "reset arena" button, and
  visual placement preview before committing a click.
- **Combat readability**: simple hit-flash feedback (still no
  animations/particles, just a color pulse), and a "New Battle" button
  to reset the arena after a winner is announced.
- **Engine modularity**: extract combat (targeting/attack) into a
  reusable `CombatComponent` separate from movement, so a future melee
  vs. ranged distinction or a second game mode can swap pieces
  independently.
