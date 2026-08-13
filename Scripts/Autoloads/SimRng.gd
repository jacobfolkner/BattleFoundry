## Single deterministic RNG stream for every gameplay-relevant random roll
## (crit/evasion, AI economy decisions, faction random-pick) -- replaces
## GDScript's global randf()/randi(), which draws from an unseeded,
## per-process stream that can't be reproduced or synced across a future
## networked match (see BattleFoundry-Roadmap.md's D1 multiplayer plan,
## Phase A).
##
## Purely local-single-player behavior is unchanged today: with no
## explicit seed_match() call, `_rng` auto-randomizes from OS entropy at
## boot exactly like the global RNG did, so nothing about single-machine
## play depends on this file existing yet. seed_match() only matters once
## a lockstep match actually needs every peer to draw the identical
## sequence -- not wired into any match-start flow yet, this is purely
## the shared-stream plumbing Phase A's determinism harness needs.
##
## Cosmetic-only randomness (OrbitCamera's shake jitter, the fixed-seed
## audio-synthesis noise burst that only ever runs once at boot) does NOT
## go through this -- only rolls that affect actual simulation outcome
## belong here, so a future lockstep replay never has to account for
## purely-visual randomness consuming ticks from the shared stream.
extends Node

var _rng := RandomNumberGenerator.new()


## Call once, at match start, with every peer's Player passing the same
## value -- everything drawn from this point on replays identically given
## the same command sequence. Never call mid-match (would desync a
## replay/networked peer that's already consumed draws from the stream).
func seed_match(match_seed: int) -> void:
	_rng.seed = match_seed


func randf() -> float:
	return _rng.randf()


func randi() -> int:
	return _rng.randi()
