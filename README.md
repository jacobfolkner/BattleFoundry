# BattleFoundry

A modular RTS engine, inspired by Warcraft III custom games, built to share
core systems (units, combat, teams) across multiple future game modes.

The first playable prototype is a simplified recreation of the Warcraft III
custom map **Blood Tournament**: place units for two teams, press Start
Battle, and watch them fight automatically until one side wins.

Out of scope for now (see project brief): abilities, heroes, buildings,
economy, animations, particles, networking, fog of war, save/load, a map
editor, and audio.

## Requirements

- [Godot 4.7](https://godotengine.org/) (GDScript, Forward+ renderer).

## Running

Open this folder as a project in Godot and press **Run** (F5). The main
scene is `Scenes/Main.tscn`.

1. Pick a unit type (Tank / Fighter / Archer) and a team (Blue / Red) in
   the top-left panels.
2. Click inside the arena to place units. Repeat for both teams.
3. Press **Start Battle**. Units automatically seek the nearest enemy,
   close distance, and attack until one team is eliminated.
4. The winning team is announced in a centered banner.

**Selection:** click any unit at any time to select it — a yellow disc
marks it, and a panel in the top-right corner shows its basic stats.
Clicking a unit takes priority over placing a new one.

**Camera:** scroll to zoom, right-click-drag to orbit around the arena.

**Debug menu:** press backtick (**`` ` ``**) to open a panel (bottom-right)
of debug-feature toggles and a color legend, both off by default:

- **Pathfinding** — attack-range ring, a line + highlight to the selected
  unit's target, and desired-vs-actual steering vectors, in the arena
- **Detailed Stats** — expands the top-right stats panel with distance,
  attack range/cooldown, position, and steering deviation

To add a new toggle: add an entry to `Scripts/DebugSettings.gd`'s `_flags`
and gate whatever it controls with `is_enabled(...)` — `UI/DebugMenu.gd`
picks up the new checkbox automatically, no UI code to write. See that
file's header comment for the full contract.

## Project Structure

```
Scenes/     Scene files (.tscn) — Main arena, Unit
Scripts/    Gameplay logic (.gd) — Team, UnitStats, Unit, HealthBar,
            GameManager, Main, DebugInspector, DebugSettings, OrbitCamera
Resources/  Data-driven unit archetypes (.tres) — Tank/Fighter/Archer stats
Assets/     Reserved for future imported art (empty — primitives only today)
UI/         HUD, DebugPanel, DebugMenu scenes/scripts
tools/      Dev scripts — tools/fetch_gut.sh
tests/      GUT test suite
```

Architecture rationale (why a system is built the way it is, tradeoffs,
gotchas) lives in that system's own doc-comments, not here — e.g. read
`Scripts/GameManager.gd`'s header for the battle-lifecycle design, or
`Scripts/Unit.gd`'s for avoidance/collision. The code is the source of
truth; this file just orients you to where things live.

## Testing

Automated tests use [GUT](https://github.com/bitwes/Gut) (`addons/gut/`,
fetched by `tools/fetch_gut.sh` rather than vendored) and run fully
headless — no X server, Xvfb, or WSLg required.

### One-time setup (fresh clone, any machine including WSL)

1. Install [Godot 4.7](https://godotengine.org/) and put the `godot`
   binary on `PATH`.
2. Fetch GUT (gitignored; safe no-op if already present):

   ```sh
   ./tools/fetch_gut.sh
   ```

3. Run an import pass once (`.godot/` is gitignored, so a fresh clone has
   no import metadata yet — GUT's class_names won't resolve without this):

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

`.github/workflows/ci.yml` fetches GUT (cached, keyed on
`tools/fetch_gut.sh`'s contents), then runs the import check and GUT
suite on every push to `main` and every pull request.
