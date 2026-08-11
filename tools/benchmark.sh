#!/usr/bin/env bash
# Headless perf benchmark -- roadmap Phase 10's "headless perf benchmark
# at 200/500 units in CI" item. See tools/Benchmark.gd for what it
# actually measures. Not run in CI yet (this just makes running it
# possible/repeatable) -- fully headless, no Xvfb/renderer needed at all,
# since nothing is ever drawn to a screen.
#
# Usage:
#   tools/benchmark.sh [--units=N] [--frames=N]
#
# Examples:
#   tools/benchmark.sh                        # 200 units, 300 frames (defaults)
#   tools/benchmark.sh --units=500
#   tools/benchmark.sh --units=500 --frames=600
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"

godot --headless res://tools/Benchmark.tscn -- "$@"
