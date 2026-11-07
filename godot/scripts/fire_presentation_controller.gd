extends Node3D
## 11.5/F6 — локальная подсветка и оригинальный звук живого пожара.
## Один источник света и одна звуковая петля на весь видимый мир.
## Объекты и топливо принадлежат FireRegistry/NatureRegistry, не FX.

const SOUND_RATE := 11025
const SOUND_SECONDS := 1.8
const SYNC_INTERVAL := 0.32
const MAX_DISTANCE := 58.0
const MAX_ZOOM := 92.0

var _light: OmniLight3D
var _audio: AudioStreamPlayer3D
var _sound: AudioStreamWAV
var _quality := 1
var _enabled := true
var _elapsed := SYNC_INTERVAL
var _flicker_time := 0.0
var _source_id := -1
var _source_strength := 0.0
var _scans := 0
var _idle_frames := 0


func _ready() -> void:
	# Единожды создаём свет без теневой карты: для мобильного GPU
	# нельзя выделять свет и аудиоплеер на каждое горящее дерево.
	_light = OmniLight3D.new()
	_light.name = "Отблеск ближайшего пожара"
	_light.light_color = Color(1.0, 0.45, 0.18)
	_light.omni_range = 11.0
	_light.light_energy = 0.0
	_light.shadow_enabled = false
	_light.visible = false
	add_child(_light)

	# Оригинальный процедурный треск воспроизводится циклом.
	# Никаких внешних WAV, аудиолицензий и генерации звука за кадр.
	_sound = _make_crackle()
	_audio = AudioStreamPlayer3D.new()
	_audio.name = "Треск пожара"
	_audio.stream = _sound
	_audio.max_distance = MAX_DISTANCE
	_audio.unit_size = 12.0
	_audio.volume_db = -11.0
	add_child(_audio)
	process_mode = Node.PROCESS_MODE_ALWAYS


func _make_crackle() -> AudioStreamWAV:
	# Белый шум проходит два фильтра: медленное низкое шуршание
	# и короткие редкие щелчки. Детерминированный seed исключает
	# случайный расход ресурсов и обеспечивает повторное использование.
	var sample_count := roundi(float(SOUND_RATE) * SOUND_SECONDS)
	var data := PackedByteArray()
	data.resize(sample_count * 2)
	var random_state := 72139
	var low := 0.0
	for index in range(sample_count):
		random_state = (random_state * 1103515245 + 12345) & 0x7fffffff
		var white := float(random_state) / 1073741824.0 - 1.0
		low = lerpf(low, white, 0.046)
		var crack := white * 0.12 if index % 1729 < 80 else 0.0
		var sample := clampf(low * 0.90 + crack, -0.75, 0.75)
		# Короткие плавные края не создают щелчка на стыке WAV.
		var edge := minf(1.0, float(mini(index,
			sample_count - index - 1)) / 220.0)
		data.encode_s16(index * 2, roundi(sample * edge * 32767.0))
	var result := AudioStreamWAV.new()
	result.mix_rate = SOUND_RATE
	result.format = AudioStreamWAV.FORMAT_16_BITS
	result.stereo = false
	result.data = data
	result.loop_mode = AudioStreamWAV.LOOP_FORWARD
	result.loop_begin = 0
	result.loop_end = sample_count
	return result


func set_quality(level: int) -> void:
	# Качество задаёт только видимый свет; звук и число активных
	# физических очагов остаются независимыми от пресета GPU.
	_quality = clampi(level, 0, 2)
	if _light != null:
		_light.omni_range = [7.0, 10.0, 14.0][_quality]
		_light.visible = _source_id >= 0 and _quality > 0 and _enabled


func set_effects_enabled(enabled: bool) -> void:
	# Во время загрузки, панорамы в технический режим и
	# длительного моделирования прекращаем старое звучание.
	if _enabled == enabled:
		return
	_enabled = enabled
	if not enabled:
		clear_visuals()


func _stop_source() -> void:
	# Кончился пожар или ушла камера — выключаем один имеющийся
	# свет и звук. Никаких фиктивных дополнительных источников.
	_source_id = -1
	_source_strength = 0.0
	if _light != null:
		_light.visible = false
		_light.light_energy = 0.0
	if _audio != null:
		_audio.stop()


func clear_visuals() -> void:
	# После загрузки очищаем предыдущую сцену и разрешаем
	# немедленный поиск по новому физическому состоянию мира.
	_stop_source()
	_elapsed = SYNC_INTERVAL


func sync_view(delta: float, fire: RefCounted, nature: RefCounted,
		world: RefCounted, center: Vector2, zoom: float,
		enabled: bool = true) -> void:
	# Читаем лишь завершённый суточный снимок на главном потоке.
	# WorkerThreadPool может менять FireRegistry — вызывающий
	# World обязан не заходить сюда во время расчёта дня.
	set_effects_enabled(enabled and zoom < MAX_ZOOM)
	if not _enabled or fire == null or nature == null or world == null:
		return
	if not is_finite(delta) or delta < 0.0:
		return
	_elapsed += delta
	if _elapsed < SYNC_INTERVAL:
		_idle_frames += 1
		return
	_elapsed = 0.0
	_scans += 1
	var distance_limit := minf(MAX_DISTANCE, zoom * 0.70 + 8.0)
	var best_distance := distance_limit * distance_limit
	var chosen_id := -1
	var chosen_point := Vector2.ZERO

	# Сортированный реестр содержит только физически горящие
	# деревья/кусты. Не ищем частицы и не создаём отдельные очаги.
	for id in fire.burning_ids():
		var object: Dictionary = nature.object_at(id)
		if object.is_empty():
			continue
		var point := Vector2(float(object["x"]) + 0.5,
			float(object["y"]) + 0.5)
		var distance: float = point.distance_squared_to(center)
		if distance >= best_distance:
			continue
		best_distance = distance
		chosen_id = id
		chosen_point = point
	if chosen_id < 0:
		# Отсутствие огня тоже проверяем не чаще SYNC_INTERVAL:
		# иначе пустая карта заставит обходить реестр каждый кадр.
		_stop_source()
		return

	_source_id = chosen_id
	_source_strength = fire.burning_visual_strength(chosen_id)
	var position: Vector3 = world.config.to_scene(
		chosen_point, world.height_at(chosen_point)) + Vector3.UP * 1.3
	_light.position = position
	_light.visible = _quality > 0
	_audio.position = position
	_audio.volume_db = -15.0 + _source_strength * 5.0
	if not _audio.is_playing():
		_audio.play()


func _process(delta: float) -> void:
	# Свет слегка дрожит без новых GPU-узлов. При настоящей паузе
	# звук замолкает, хотя обработчик работает в режиме ALWAYS.
	if _audio == null or _light == null:
		return
	if get_tree().paused:
		_audio.stream_paused = true
		_light.light_energy = 0.0
		return
	_audio.stream_paused = false
	if not _light.visible:
		return
	_flicker_time += minf(delta, 0.12)
	var flutter := 0.87 + sin(_flicker_time * 13.7) * 0.09 		+ sin(_flicker_time * 23.9) * 0.04
	_light.light_energy = (0.38 + _source_strength * 0.72) * flutter


func debug_budget() -> Dictionary:
	# Отчёт показывает число созданных ресурсов, а не
	# выдуманное аппаратное значение CPU/GPU/FPS.
	return {
		"lights": 1 if _light != null else 0,
		"audio_players": 1 if _audio != null else 0,
		"source_id": _source_id,
		"strength": _source_strength,
		"quality": _quality,
		"scans": _scans,
		"idle_frames": _idle_frames
	}
