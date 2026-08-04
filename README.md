# BattleFoundry

A modular RTS engine, inspired by Warcraft III custom games, built to share
core systems (units, combat, teams) across multiple future game modes.

The first playable prototype is a simplified recreation of the Warcraft III
custom map **Blood Tournament**: place units for two teams, press Start
Battle, and watch them fight automatically until one side wins.

## Status: Sprint 2 — Battle Readability

- Two teams (Blue / Red)
- Three unit archetypes: Tank, Fighter, Archer
- Click-to-place unit placement phase
- Fully automatic combat (nearest-enemy targeting, move-into-range, attack)
- Health bars above every unit, live-updated as damage is taken
- Win detection when one team is eliminated, with a visible winner banner

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

## Project Structure

```
Scenes/     Scene files (.tscn) — Main arena, Unit
Scripts/    Gameplay logic (.gd) — Team, UnitStats, Unit, HealthBar, GameManager, Main
Resources/  Data-driven unit archetypes (.tres) — Tank/Fighter/Archer stats
Assets/     Reserved for future imported art (empty — primitives only today)
UI/         HUD scene/script
```

### Architecture notes

- **UnitStats** (`Scripts/UnitStats.gd`) is a `Resource`, so new unit
  archetypes are authored as `.tres` data files, not code.
- **Unit** (`Scripts/Unit.gd`) owns per-unit state and combat behavior.
  It builds its own primitive mesh from `UnitStats` at spawn time and is
  colored by team, so archetypes are told apart by shape/size, not color.
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

Movement is a direct straight-line walk toward the current target
(no steering or pathfinding); this is intentional for readability and is
the first thing a future "movement system" milestone would replace.

## Next Recommended Milestone

Candidates once this sprint is validated in-editor:

- **Placement polish**: unit count limits, a "reset arena" button, and
  visual placement preview before committing a click.
- **Combat readability**: simple hit-flash feedback (still no
  animations/particles, just a color pulse), and a "New Battle" button
  to reset the arena after a winner is announced.
- **Engine modularity**: extract combat (targeting/attack) into a
  reusable `CombatComponent` separate from movement, so a future melee
  vs. ranged distinction or a second game mode can swap pieces
  independently.
