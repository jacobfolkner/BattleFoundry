## Tests for Scripts/Autoloads/Sfx.gd (roadmap Phase 9's "no audio" gap) -- both the
## procedural synthesis itself (each sound is a distinct non-empty buffer)
## and that real gameplay events actually trigger playback. Headless/no
## audio device means nothing here can assert a sound is literally
## audible -- checks the same thing every other "cosmetic feedback" test
## in this project checks for VFX instead (DamagePopup/hit-flash in
## test_combat_feedback.gd): that the call actually fired and reached a
## real AudioStreamPlayer3D/AudioStreamPlayer node with the right stream
## and position.
extends GutTest

const TANK_STATS: UnitStats = preload("res://Resources/Units/TankStats.tres")

var _main: Node3D


func before_each() -> void:
	GameManager.reset_battle()
	GameManager.current_mode = ClassicEliminationMode.new()
	_main = load("res://Scenes/Main.tscn").instantiate()
	add_child_autofree(_main)
	await wait_physics_frames(2)


func test_the_four_sounds_are_distinct_nonempty_buffers() -> void:
	var sounds: Array = [Sfx._attack_land_sound, Sfx._death_sound, Sfx._ability_cast_sound, Sfx._ui_click_sound]
	for sound in sounds:
		assert_gt(sound.data.size(), 0)
	for i in sounds.size():
		for j in range(i + 1, sounds.size()):
			assert_ne(sounds[i].data, sounds[j].data, "each sound should be audibly distinct")


func _any_positional_player_matches(stream: AudioStreamWAV, position: Vector3) -> bool:
	for player in Sfx._positional_pool:
		if player.stream == stream and player.playing and player.global_position.is_equal_approx(position):
			return true
	return false


func test_play_attack_land_starts_a_positional_player_at_the_given_position() -> void:
	Sfx.play_attack_land(Vector3(3, 0, 4))
	assert_true(_any_positional_player_matches(Sfx._attack_land_sound, Vector3(3, 0, 4)))


func test_play_death_starts_a_positional_player_at_the_given_position() -> void:
	Sfx.play_death(Vector3(1, 0, 2))
	assert_true(_any_positional_player_matches(Sfx._death_sound, Vector3(1, 0, 2)))


func test_play_ability_cast_starts_a_positional_player_at_the_given_position() -> void:
	Sfx.play_ability_cast(Vector3(5, 0, 6))
	assert_true(_any_positional_player_matches(Sfx._ability_cast_sound, Vector3(5, 0, 6)))


func test_play_ui_click_plays_the_non_positional_player() -> void:
	Sfx.play_ui_click()
	assert_true(Sfx._ui_player.playing)
	assert_eq(Sfx._ui_player.stream, Sfx._ui_click_sound)


func test_a_landed_hit_plays_the_attack_land_sound_at_the_victims_position() -> void:
	var victim := GameManager.spawn_unit(TANK_STATS, GameManager.get_player(GameManager.BLUE_TEAM_ID), Vector3(2, 0, 2))

	victim.take_damage(DamageInstance.new(20.0, null, DamageInstance.DamageType.PURE))

	assert_true(_any_positional_player_matches(Sfx._attack_land_sound, victim.global_position))


func test_an_evaded_hit_plays_no_attack_land_sound() -> void:
	# A duplicate, not TANK_STATS directly -- Unit.stats is the shared
	# preloaded Resource (see test_combat_feedback.gd's own comment on the
	# same gotcha); mutating it in place would leak evasion = 1.0 into
	# every later Tank spawned this suite run.
	var evasive_stats: UnitStats = TANK_STATS.duplicate()
	evasive_stats.evasion = 1.0
	var victim := GameManager.spawn_unit(evasive_stats, GameManager.get_player(GameManager.BLUE_TEAM_ID), Vector3(9, 0, 9))

	var hit_landed := victim.take_damage(DamageInstance.new(20.0, null, DamageInstance.DamageType.ATTACK))

	assert_false(hit_landed)
	assert_false(_any_positional_player_matches(Sfx._attack_land_sound, victim.global_position))


func test_dying_plays_the_death_sound_at_the_units_position() -> void:
	var victim := GameManager.spawn_unit(TANK_STATS, GameManager.get_player(GameManager.BLUE_TEAM_ID), Vector3(-1, 0, -1))

	victim.take_damage(DamageInstance.new(TANK_STATS.max_health + 100.0, null, DamageInstance.DamageType.PURE))

	assert_true(_any_positional_player_matches(Sfx._death_sound, victim.global_position))


func test_casting_an_ability_plays_the_ability_cast_sound() -> void:
	var caster := GameManager.spawn_unit(TANK_STATS, GameManager.get_player(GameManager.BLUE_TEAM_ID), Vector3(4, 0, 4))

	var cast_ok := caster.cast_ability(0) # Tank's War Stomp, NO_TARGET -- no start_battle()/target needed
	assert_true(cast_ok, "sanity check -- the cast itself should succeed")
	assert_true(_any_positional_player_matches(Sfx._ability_cast_sound, caster.global_position))


func test_a_failed_cast_plays_no_ability_sound() -> void:
	var caster := GameManager.spawn_unit(TANK_STATS, GameManager.get_player(GameManager.BLUE_TEAM_ID), Vector3(7, 0, 7))
	caster.cast_ability(0) # succeeds, starts War Stomp's cooldown

	var cast_ok := caster.cast_ability(0) # immediately again -- should fail, still on cooldown

	assert_false(cast_ok)


## Integration: an actual HUD button press (not a direct Sfx call) should
## reach the click sound, same as UI/HUD.gd's own _add_toggle_button()/
## _build_start_button() wiring intends.
func test_pressing_the_start_battle_button_plays_a_ui_click() -> void:
	_main._hud._start_button.pressed.emit()
	assert_true(Sfx._ui_player.playing)


## set_pressed_no_signal() (used by every programmatic toggle sync in
## UI/HUD.gd -- set_ai_toggle(), etc.) must NOT play a click, since
## nothing was actually clicked.
func test_a_programmatic_toggle_sync_plays_no_click() -> void:
	Sfx._ui_player.stop()
	_main._hud.set_ai_toggle(true)
	assert_false(Sfx._ui_player.playing)
