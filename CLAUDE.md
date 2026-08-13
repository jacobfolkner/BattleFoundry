# BattleFoundry — instructions for Claude Code

## Keep README.md lean

README.md is read constantly but edited by every parallel branch, which
makes it the highest-conflict file in this repo if it accumulates
per-PR content. Keep it to: what the project is, how to run it, how to
test it, and project structure/where things live. That's it.

Do **not** add to README.md:
- A "Status: Sprint N" section or running feature/changelog log. Git
  history is the changelog; a status block that every PR edits is a
  guaranteed conflict on the same lines every time.
- "Why we built it this way" rationale essays for a specific system.
  That belongs in the system's own doc-comment header (e.g.
  `Scripts/Autoloads/GameManager.gd`'s top comment, `Scripts/Combat/Unit.gd`'s), which is
  already the source of truth other agents/devs will read when touching
  that file. Duplicating it into README means keeping two places in
  sync for no reader benefit, and it's most of what caused past merge
  conflicts here.
- A "Next milestone" / backlog / roadmap section. That's a planning
  concern, not documentation — track it in issues or a project board,
  not a file every feature branch has to touch.

If a PR adds a genuinely load-bearing fact that isn't obvious from the
code (a non-obvious gotcha, a required setup step, a control scheme) —
that's fine to add, briefly, in the relevant existing section. When in
doubt, put the detail in the code's own comments and leave README
alone.

## Testing

```sh
./tools/fetch_gut.sh                                                  # one-time, gitignored addon
godot --headless --editor --quit                                      # one-time import pass
godot --headless -s addons/gut/gut_cmdln.gd -gdir=res://tests -gexit  # run the suite
```

Runs fully headless, no display needed — GUT tests exercise game logic
and physics, not rendering. Fresh clone (or after touching `addons/gut`)
needs the first two steps once; CI does this automatically.

## Visual/manual validation

Use `tools/screenshot.sh` for this — don't write a new throwaway
GDScript driver scene under `tools/` to boot the game and grab a
screenshot; that pattern already exists, is scriptable (place units,
start a battle, select a unit, toggle debug-menu flags, all via one
command), and deleting-and-recreating it every session wastes a turn.
See the README's "Screenshots" section or `tools/Screenshot.gd`'s
header comment for the option list. Defaults to a fast renderer that
renders noticeably darker than real gameplay (`--renderer=vulkan` for
accurate lighting, ~30s instead of ~5-10s) — mention this if screenshot
output looks unexpectedly dark, it's a known renderer mismatch, not a
lighting bug in the game itself.

## Godot gotchas worth remembering

- **`NavigationAgent3D`'s built-in avoidance (RVO) is not deterministic
  across separate process runs**, confirmed empirically while scoping D1
  multiplayer (see `BattleFoundry-Roadmap.md`): two `godot --headless`
  invocations, identical seed/inputs/code, diverged by ~0.01-0.02m
  within the first physics tick, compounding to ~50% of units differing
  within 300 ticks. Root cause (inferred, not proven further): avoidance
  runs off-thread and delivers results one frame later via the
  `velocity_computed` signal — worker-thread completion order isn't
  guaranteed identical run to run. `Unit._build_avoidance()` now sets
  `avoidance_enabled = false` project-wide and `Unit.gd` computes
  separation itself, synchronously, same-tick, in a fixed iteration
  order (`Unit._compute_avoidance_velocity()`) — don't re-enable
  `avoidance_enabled` without re-deriving this.
- **`NavigationAgent3D` pathfinding for an agent well above the
  navmesh's Y plane** (a flying unit resting at `flight_height`, for
  example): no path is found, and `get_next_path_position()` silently
  falls back to returning the agent's *own* position — reads as the
  agent being permanently frozen, no error anywhere. Flying units in
  this project skip navmesh queries entirely and seek their destination
  directly instead (they're meant to fly over ground obstacles anyway
  — see `Unit._physics_process()`'s `stats.is_flying` branch).
- **`NavigationAgent3D.target_desired_distance` defaults to 1.0m** —
  looser than this project's own tolerances (`attack_range` as low as
  0.9m, `Unit._ARRIVAL_EPSILON` of 0.3m). Left at the default, the agent
  considers itself "close enough" well before either of those and
  `get_next_path_position()` stops making further progress — reads as
  units freezing just short of a nearby target. `Unit._build_avoidance()`
  sets it to 0.1.
- **A `PanelContainer` positioned via anchors on a parentless `Control`**
  (a `Control` whose only ancestor before the `CanvasLayer` is itself)
  never resolves a real size or position — it silently renders nothing
  despite `visible == true`, with no errors. Fix: `reset_size()` after
  building content, then position it from `get_viewport_rect().size`
  directly rather than anchors. See `UI/DebugMenu.gd` /
  `UI/DebugPanel.gd`.
- **Godot's Compatibility renderer (`--rendering-driver opengl3`) vs.
  this project's configured Forward+**: Compatibility renders
  noticeably darker/flatter lighting for the same scene. Xvfb here has
  no real GPU, so Forward+ (Vulkan) only works via a software
  implementation (llvmpipe) — functional but ~30s per invocation
  (mostly fixed engine/shader-compile startup cost, not much affected
  by `--wait` once above ~8 frames), vs. ~5-10s for Compatibility. See
  `tools/screenshot.sh`'s `--renderer` flag.
- **A script field named `_input` collides with `Node`'s own built-in
  `_input(event)` virtual method** — reaching into it from outside via a
  plain/generic-typed reference (e.g. a `Node3D`-typed local calling
  `.some_method()` through it) resolves dynamically to the built-in
  method instead of the field, producing a misleading `Function "..." not
  found in base Callable` rather than a type error. `Main.gd`'s own
  `_input: PlayerInputController` field hits this; every existing call
  site avoids it by going through `Main`'s own thin delegate methods
  (`_handle_key()`, etc.) instead of `_main._input.foo()` directly. Avoid
  naming a field `_input` (or anything else that shadows a `Node`
  virtual — `_process`, `_ready`, `_draw`, ...) if it needs to be reached
  from outside the class.
- **Moving a `.gd` file breaks every reference to it that isn't through
  its `class_name`.** Every `.gd` script here has a matching `.gd.uid`
  sidecar, but this project's `.tres`/`.tscn` `ext_resource` lines use a
  plain `path=` attribute with no `uid=` — confirmed by moving a script
  and reimporting, which threw cascading `File not found` errors until
  every literal `res://Scripts/OldPath.gd` string (`.tres`/`.tscn` files,
  `project.godot`'s `[autoload]` block, and any doc-comment prose citing
  the old path) was rewritten by hand. A type reference via `class_name`
  (e.g. `var x: SomeClass`) needs none of this and just keeps working —
  but only if the moved script actually declares a `class_name` in the
  first place; `Scripts/Core/OrbitCamera.gd` didn't for a long time, and
  a first attempt to reference it by type (`as OrbitCamera`) failed with
  `Could not find type "OrbitCamera" in the current scope"` until one was
  added, followed by the usual reimport pass.
