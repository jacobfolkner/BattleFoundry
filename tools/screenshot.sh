#!/usr/bin/env bash
# Ad-hoc screenshot generator for manual/visual validation. Not run in
# CI -- see tools/Screenshot.gd for the full scene-setup option list.
#
# Usage:
#   tools/screenshot.sh [--renderer=opengl3|vulkan] [options]
#
# --renderer (this script's own flag, stripped before being passed to
# the scene -- Godot's --rendering-driver has to come before "--"):
#   opengl3 (default) -- fast (~5-10s). Runs Godot's Compatibility
#                         renderer, which doesn't match this project's
#                         configured Forward+ renderer: lighting/shadows
#                         come out much darker than real gameplay. Fine
#                         for checking shapes/positions/UI, not lighting.
#   vulkan             -- matches real gameplay (Forward+, same as the
#                         editor) for correct lighting, running on a
#                         software Vulkan implementation (llvmpipe) under
#                         Xvfb -- ~30s per screenshot (mostly fixed
#                         engine/shader-compile startup cost; --wait
#                         barely affects it once above ~8 frames, the
#                         minimum for the scene to actually finish its
#                         first real render).
#
# Examples:
#   tools/screenshot.sh
#   tools/screenshot.sh --renderer=vulkan
#   tools/screenshot.sh --out=battle.png --place="Tank:BLUE:-2,0,0;Fighter:RED:2,0,0" --battle --wait=90
#
# Always saves to screenshots/<name> (gitignored); prints the absolute
# path of the saved file on success.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"

RENDERER="opengl3"
SCENE_ARGS=()
for arg in "$@"; do
	if [[ "${arg}" == --renderer=* ]]; then
		RENDERER="${arg#--renderer=}"
	else
		SCENE_ARGS+=("${arg}")
	fi
done

xvfb-run -a godot --rendering-driver "${RENDERER}" --resolution 1280x800 res://tools/Screenshot.tscn -- "${SCENE_ARGS[@]}"
