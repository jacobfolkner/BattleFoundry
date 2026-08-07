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
  `Scripts/GameManager.gd`'s top comment, `Scripts/Unit.gd`'s), which is
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

- **`NavigationAgent3D` avoidance without a navmesh**: `target_position`
  must be set every physics frame (even though nothing paths to it) or
  `velocity_computed` always reports zero. Undocumented on the property
  itself — only mentioned in the navigation tutorial.
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
