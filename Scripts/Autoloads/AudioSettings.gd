## Master volume/mute -- closes Sfx.gd's own documented gap ("no volume/mute
## settings UI"). Just the single default "Master" bus (project has no
## custom bus layout -- every sound in Sfx.gd plays on it already), so
## there's nothing per-channel to expose yet. Same ConfigFile-in-user://
## persistence pattern as Hotkeys.gd: real player preference, meant to
## survive a relaunch, not baked into the project.
extends Node

const _SAVE_PATH := "user://audio_settings.cfg"
const _SAVE_SECTION := "audio"
const _MASTER_BUS := 0

const DEFAULT_VOLUME := 1.0
const DEFAULT_MUTED := false

var volume: float = DEFAULT_VOLUME:
	set(value):
		volume = clampf(value, 0.0, 1.0)
		AudioServer.set_bus_volume_db(_MASTER_BUS, linear_to_db(volume) if volume > 0.0 else -80.0)
var muted: bool = DEFAULT_MUTED:
	set(value):
		muted = value
		AudioServer.set_bus_mute(_MASTER_BUS, muted)


func _ready() -> void:
	_load()


func set_volume(new_volume: float) -> void:
	volume = new_volume
	_save()


func set_muted(new_muted: bool) -> void:
	muted = new_muted
	_save()


func _save() -> void:
	var config := ConfigFile.new()
	config.set_value(_SAVE_SECTION, "volume", volume)
	config.set_value(_SAVE_SECTION, "muted", muted)
	config.save(_SAVE_PATH)


## A missing/unreadable save file (first launch, or a fresh test run's
## user:// directory) just leaves the class defaults in place, silently --
## same tolerance as Hotkeys._load_saved_bindings().
func _load() -> void:
	var config := ConfigFile.new()
	if config.load(_SAVE_PATH) != OK:
		volume = DEFAULT_VOLUME
		muted = DEFAULT_MUTED
		return
	volume = config.get_value(_SAVE_SECTION, "volume", DEFAULT_VOLUME)
	muted = config.get_value(_SAVE_SECTION, "muted", DEFAULT_MUTED)
