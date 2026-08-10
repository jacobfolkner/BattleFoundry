## Minimal procedural sound-effect system -- closes roadmap Phase 9's "no
## audio" gap (the single biggest presentation gap on record for this
## project) with the same "prove the mechanic, crude v1 is fine" scope
## every other system here has used. No external audio asset files exist
## anywhere in this repo (nothing under Assets/, no .wav/.ogg checked in),
## and none are added by this file either -- every sound below is
## synthesized once at boot into an AudioStreamWAV buffer (see the
## "Procedural synthesis" section) rather than loaded from a file.
## Swapping in real SFX later only means changing what the
## _build_*_sound() functions return; every call site
## (play_attack_land()/play_death()/play_ability_cast()/play_ui_click())
## stays unchanged.
##
## Positional sounds (attack-land, death, ability-cast) play through a
## small round-robin pool of AudioStreamPlayer3D children of this
## autoload, repositioned to the event's world position on each play --
## deliberately NOT parented to the Unit that triggered them, since a Unit
## can queue_free() (corpse decay finishing) or be mid-die() while its own
## death sound is still playing, and a playing AudioStreamPlayer3D freed
## along with its parent would cut the sound off. UI clicks use one plain,
## non-3D AudioStreamPlayer instead -- HUD/menu buttons aren't part of the
## game world, so positional attenuation doesn't apply to them.
extends Node

const _MIX_RATE := 44100
const _POOL_SIZE := 8

var _attack_land_sound: AudioStreamWAV
var _death_sound: AudioStreamWAV
var _ability_cast_sound: AudioStreamWAV
var _ui_click_sound: AudioStreamWAV

var _positional_pool: Array[AudioStreamPlayer3D] = []
var _next_positional_index := 0
var _ui_player: AudioStreamPlayer


func _ready() -> void:
	_attack_land_sound = _build_attack_land_sound()
	_death_sound = _build_death_sound()
	_ability_cast_sound = _build_ability_cast_sound()
	_ui_click_sound = _build_ui_click_sound()

	for i in _POOL_SIZE:
		var player := AudioStreamPlayer3D.new()
		player.max_distance = 60.0
		add_child(player)
		_positional_pool.append(player)

	_ui_player = AudioStreamPlayer.new()
	add_child(_ui_player)


func play_attack_land(position: Vector3) -> void:
	_play_positional(_attack_land_sound, position, -6.0)


func play_death(position: Vector3) -> void:
	_play_positional(_death_sound, position, -3.0)


func play_ability_cast(position: Vector3) -> void:
	_play_positional(_ability_cast_sound, position, -4.0)


func play_ui_click() -> void:
	_ui_player.stream = _ui_click_sound
	_ui_player.volume_db = -8.0
	_ui_player.play()


## Round-robin, not "find a free one" -- an idle AudioStreamPlayer3D
## reports playing == false the instant its stream naturally ends, so a
## strict free-voice search would work too, but round-robin needs no
## per-frame bookkeeping and just cuts the pool's oldest voice short on a
## burst loud enough to want more than _POOL_SIZE voices at once -- rare
## and harmless at this prototype's unit counts.
func _play_positional(stream: AudioStreamWAV, position: Vector3, volume_db: float) -> void:
	var player := _positional_pool[_next_positional_index]
	_next_positional_index = (_next_positional_index + 1) % _positional_pool.size()
	player.global_position = position
	player.stream = stream
	player.volume_db = volume_db
	player.play()


# ---- Procedural synthesis -------------------------------------------------
# Everything below trades realism for "distinct enough to tell apart and
# not actively annoying," in keeping with this file's own header comment.
# Each _build_*_sound() runs exactly once, at _ready() -- none of this is
# hot-path code.

static func _make_wav(samples: PackedFloat32Array) -> AudioStreamWAV:
	var stream := AudioStreamWAV.new()
	stream.format = AudioStreamWAV.FORMAT_16_BITS
	stream.mix_rate = _MIX_RATE
	stream.stereo = false
	var data := PackedByteArray()
	data.resize(samples.size() * 2)
	for i in samples.size():
		data.encode_s16(i * 2, int(clampf(samples[i], -1.0, 1.0) * 32767.0))
	stream.data = data
	return stream


## Linear attack/release envelope, 0..1 -- ramps up over `attack` seconds,
## ramps back down over the final `release` seconds, full volume in
## between. Kept linear (not exponential) since a longer perceived decay
## just means a bigger `release`, and there's no reverb/tail here to make
## an exponential curve worth the extra math for a one-shot buffer.
static func _envelope(t: float, duration: float, attack: float, release: float) -> float:
	if t < attack:
		return t / attack
	var remaining := duration - t
	if remaining < release:
		return maxf(remaining / release, 0.0)
	return 1.0


static func _tone_sweep(duration: float, freq_start: float, freq_end: float, attack: float, release: float, amplitude: float) -> PackedFloat32Array:
	var sample_count := int(duration * _MIX_RATE)
	var samples := PackedFloat32Array()
	samples.resize(sample_count)
	var phase := 0.0
	for i in sample_count:
		var t := float(i) / _MIX_RATE
		var freq := lerpf(freq_start, freq_end, t / duration)
		phase += freq / _MIX_RATE
		samples[i] = sin(phase * TAU) * amplitude * _envelope(t, duration, attack, release)
	return samples


## A one-pole low-pass over white noise gives a dull "thud"/"thwack"
## instead of white noise's harsh hiss -- cheap enough to skip a real DSP
## filter node for a one-shot precomputed buffer. `seed` is fixed
## (deterministic), not randomized per call: this only ever runs once per
## sound at boot to build a fixed buffer, never as a live gameplay roll.
static func _noise_burst(duration: float, attack: float, release: float, amplitude: float, low_pass: float) -> PackedFloat32Array:
	var sample_count := int(duration * _MIX_RATE)
	var samples := PackedFloat32Array()
	samples.resize(sample_count)
	var rng := RandomNumberGenerator.new()
	rng.seed = 1
	var prev := 0.0
	for i in sample_count:
		var t := float(i) / _MIX_RATE
		prev = lerpf(rng.randf_range(-1.0, 1.0), prev, low_pass)
		samples[i] = prev * amplitude * _envelope(t, duration, attack, release)
	return samples


static func _mix(a: PackedFloat32Array, b: PackedFloat32Array) -> PackedFloat32Array:
	var length := maxi(a.size(), b.size())
	var out := PackedFloat32Array()
	out.resize(length)
	for i in length:
		var va := a[i] if i < a.size() else 0.0
		var vb := b[i] if i < b.size() else 0.0
		out[i] = va + vb
	return out


## Short percussive thud: a fast-decaying low tone sweep plus a filtered
## noise burst, mixed together -- reads as an impact, not a musical note.
## Shared by every landed hit regardless of damage type/weapon (melee and
## projectile impacts both funnel through Unit.take_damage(), see its own
## play_attack_land() call) -- no per-archetype sound variety in this v1.
static func _build_attack_land_sound() -> AudioStreamWAV:
	var tone := _tone_sweep(0.08, 180.0, 70.0, 0.002, 0.07, 0.5)
	var noise := _noise_burst(0.06, 0.001, 0.05, 0.35, 0.4)
	return _make_wav(_mix(tone, noise))


## A longer, lower descending sweep -- deliberately longer and lower than
## attack-land's quick thud, so a death reads as more final than just
## another landed hit.
static func _build_death_sound() -> AudioStreamWAV:
	return _make_wav(_tone_sweep(0.4, 260.0, 60.0, 0.005, 0.3, 0.5))


## A brief rising two-tone chime -- the only sound here that rises in
## pitch, so it reads as "something started" rather than "something
## ended" (attack-land and death both fall).
static func _build_ability_cast_sound() -> AudioStreamWAV:
	var first := _tone_sweep(0.08, 500.0, 700.0, 0.005, 0.03, 0.4)
	var second := _tone_sweep(0.1, 700.0, 950.0, 0.005, 0.05, 0.4)
	var samples := PackedFloat32Array()
	samples.resize(first.size() + second.size())
	for i in first.size():
		samples[i] = first[i]
	for i in second.size():
		samples[first.size() + i] = second[i]
	return _make_wav(samples)


## A short, high, near-instant blip -- distinct from every gameplay sound
## above (all lower-pitched, all longer) so a UI click never reads as
## something happening on the battlefield.
static func _build_ui_click_sound() -> AudioStreamWAV:
	return _make_wav(_tone_sweep(0.04, 1200.0, 1200.0, 0.002, 0.03, 0.3))
