extends Node3D
## Этап 11.4: видимый канал молнии, световой импульс и пространственный гром.
## Физика и сохранения принадлежат WeatherEvents/NatureRegistry/FireRegistry.
## Этот контроллер только показывает уже подтверждённые удары.

const MAX_VISIBLE_BOLTS := 4
const BOLT_LIFETIME := 0.45
const SOUND_RATE := 22050
const SOUND_DURATION := 2.2
const BOLT_JOINTS := 11

var _slots: Array[Dictionary] = []
var _last_played_day := -1
var _thunder_stream: AudioStreamWAV
var _accepted_bolts := 0


func _ready() -> void:
	# Узлы создаём заранее и переиспользуем. Даже при восьми
	# физических ударах число световых и звуковых объектов постоянно.
	_thunder_stream = _make_thunder_sound()
	for index in range(MAX_VISIBLE_BOLTS):
		var core := _make_ribbon("Канал молнии %d" % index,
			Color(0.94, 0.97, 1.0, 0.98))
		var glow := _make_ribbon("Свечение молнии %d" % index,
			Color(0.39, 0.71, 1.0, 0.27))
		var flash := OmniLight3D.new()
		flash.name = "Вспышка разряда %d" % index
		flash.light_color = Color(0.73, 0.84, 1.0)
		flash.omni_range = 52.0
		flash.light_energy = 0.0
		flash.shadow_enabled = false
		flash.visible = false
		add_child(flash)
		var audio := AudioStreamPlayer3D.new()
		audio.name = "Гром %d" % index
		audio.stream = _thunder_stream
		audio.max_distance = 170.0
		audio.unit_size = 26.0
		audio.volume_db = -6.0
		add_child(audio)
		_slots.append({
			"core": core, "glow": glow, "flash": flash,
			"audio": audio, "life": 0.0, "delay": 0.0,
			"thunder_pending": false
		})
	set_process(false)


func _make_ribbon(title: String, tint: Color) -> MeshInstance3D:
	# Два слоя одной геометрии дают резкое белое ядро
	# и рассеянное голубое свечение без частиц на каждый сегмент.
	var node := MeshInstance3D.new()
	node.name = title
	node.visible = false
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	material.albedo_color = tint
	node.material_override = material
	add_child(node)
	return node


func _make_thunder_sound() -> AudioStreamWAV:
	# Оригинальная синтезированная запись: сначала резкий треск,
	# потом низкочастотный раскат. Внешние звуковые лицензии
	# и новые ресурсы при каждом ударе не требуются.
	var count := roundi(float(SOUND_RATE) * SOUND_DURATION)
	var samples := PackedByteArray()
	samples.resize(count * 2)
	for index in range(count):
		var seconds := float(index) / float(SOUND_RATE)
		# Неповторяющийся на слух детерминированный шум;
		# высокие частоты гаснут быстрее низкого раската.
		var random_value := sin(float(index) * 1.6137) * 43758.5453
		var noise := (random_value - floorf(random_value)) * 2.0 - 1.0
		var crackle := noise * exp(-seconds * 18.0) * 0.56
		var rumble := (sin(seconds * TAU * 53.0)
			+ 0.50 * sin(seconds * TAU * 87.0)
			+ noise * 0.26) * exp(-seconds * 1.75) * 0.21
		var amplitude := clampf(crackle + rumble, -0.94, 0.94)
		samples.encode_s16(index * 2, roundi(amplitude * 32767.0))
	var stream := AudioStreamWAV.new()
	stream.mix_rate = SOUND_RATE
	stream.format = AudioStreamWAV.FORMAT_16_BITS
	stream.stereo = false
	stream.data = samples
	return stream


func _add_segment(vertices: PackedVector3Array, start: Vector3,
		finish: Vector3, width: float) -> void:
	# Прямоугольник из двух треугольников: канал не исчезает
	# из-за одно-пиксельных линий на обычном масштабе.
	var across := Vector3(0.70, 0.0, -0.70) * width
	var a := start - across
	var b := start + across
	var c := finish + across
	var d := finish - across
	for vertex in [a, b, c, a, c, d]:
		vertices.append(vertex)


func _bolt_mesh(impact: Vector3, day: int,
		cell: Vector2i, width: float) -> ArrayMesh:
	# Канал строится от фактической точки удара вверх.
	# Изломы и боковые ветви зависят только от seed события,
	# поэтому один физический удар всегда имеет тот же рисунок.
	var vertices := PackedVector3Array()
	var previous := impact
	var salt := float(day * 17 + cell.x * 31 + cell.y * 47)
	for step in range(1, BOLT_JOINTS + 1):
		var fraction := float(step) / float(BOLT_JOINTS)
		var wobble := 0.0 if step == BOLT_JOINTS else sin(
			salt + float(step) * 2.39) * 2.3
		var point := impact + Vector3(
			wobble + fraction * 2.8, fraction * 42.0,
			sin(salt * 0.37 + float(step) * 3.1) * 1.9)
		_add_segment(vertices, previous, point,
			width * lerpf(0.65, 1.0, 1.0 - fraction))
		# Два коротких ответвления усиливают узнаваемость разряда.
		# Они не означают дополнительные удары по поверхности.
		if step == 5 or step == 8:
			var branch := point + Vector3(
				(-8.0 if step == 5 else 7.0),
				8.0, 2.8 if step == 5 else -3.0)
			_add_segment(vertices, point, branch, width * 0.55)
		previous = point
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


func show_strikes(events: Array[Dictionary], map: RefCounted,
		center: Vector2, zoom: float, day: int,
		enabled: bool = true) -> int:
	# Только результат нового физического дня может запустить
	# визуализацию. Повторный callback и загрузка не создают гром.
	if day <= _last_played_day:
		return 0
	_last_played_day = day
	if not enabled or map == null or zoom >= 105.0:
		return 0
	var shown := 0
	for event in events:
		if shown >= MAX_VISIBLE_BOLTS:
			break
		if event.get("day") != day or event.get("cause") != "молния" \
				or not (event.get("cell") is Vector2i):
			continue
		var cell: Vector2i = event["cell"]
		if not map.config.contains_cell(cell):
			continue
		var point := Vector2(cell) + Vector2(0.5, 0.5)
		var distance := center.distance_to(point)
		if distance > zoom * 0.72 + 18.0:
			continue
		var impact: Vector3 = map.config.to_scene(point,
			map.height_at(point) + 1.0)
		var slot: Dictionary = _slots[shown]
		var core: MeshInstance3D = slot["core"]
		var glow: MeshInstance3D = slot["glow"]
		core.mesh = _bolt_mesh(impact, day, cell, 0.20)
		glow.mesh = _bolt_mesh(impact, day, cell, 0.68)
		core.visible = true
		glow.visible = true
		var flash: OmniLight3D = slot["flash"]
		flash.position = impact + Vector3.UP * 9.0
		flash.visible = true
		flash.light_energy = 6.0
		var audio: AudioStreamPlayer3D = slot["audio"]
		audio.position = impact + Vector3.UP * 5.0
		audio.stop()
		# Условный масштаб карты: примерно 10 м на единицу.
		# Задержка выражает распространение звука, а не новый
		# физический закон для игровой географии.
		slot["delay"] = clampf(distance * 10.0 / 343.0, 0.05, 2.6)
		slot["life"] = BOLT_LIFETIME
		slot["thunder_pending"] = true
		_slots[shown] = slot
		shown += 1
	_accepted_bolts += shown
	if shown > 0:
		set_process(true)
	return shown


func _process(delta: float) -> void:
	# Вспышка состоит из двух коротких импульсов. Звук следует
	# за ней с расстоянием и продолжает играть после исчезновения
	# канала. Пауза останавливает эти визуальные часы.
	if delta <= 0.0 or not is_finite(delta):
		return
	if get_tree().paused:
		return
	var busy := false
	for slot in _slots:
		var remaining: float = float(slot["life"])
		if remaining > 0.0:
			remaining = maxf(0.0, remaining - delta)
			slot["life"] = remaining
			var elapsed := BOLT_LIFETIME - remaining
			var pulse := 1.0 if elapsed < 0.07 else (
				0.72 if elapsed >= 0.13 and elapsed < 0.22 else
				0.0)
			var core: MeshInstance3D = slot["core"]
			var glow: MeshInstance3D = slot["glow"]
			var flash: OmniLight3D = slot["flash"]
			core.visible = pulse > 0.0
			glow.visible = pulse > 0.0
			flash.visible = pulse > 0.0
			flash.light_energy = 6.0 * pulse
		if bool(slot["thunder_pending"]):
			slot["delay"] = float(slot["delay"]) - delta
			if float(slot["delay"]) <= 0.0:
				var audio: AudioStreamPlayer3D = slot["audio"]
				audio.play()
				slot["thunder_pending"] = false
		busy = busy or float(slot["life"]) > 0.0 \
			or bool(slot["thunder_pending"])
	if not busy:
		set_process(false)


func clear(last_day: int = -1) -> void:
	# Вызывается при загрузке: сохранённые физические молнии
	# не проигрываются заново и не оставляют старый гром.
	_last_played_day = last_day
	set_process(false)
	for slot in _slots:
		slot["life"] = 0.0
		slot["delay"] = 0.0
		slot["thunder_pending"] = false
		var core: MeshInstance3D = slot["core"]
		var glow: MeshInstance3D = slot["glow"]
		var flash: OmniLight3D = slot["flash"]
		var audio: AudioStreamPlayer3D = slot["audio"]
		core.visible = false
		glow.visible = false
		flash.visible = false
		audio.stop()


func debug_state() -> Dictionary:
	# Smoke видит только служебное состояние визуализатора;
	# контроллер не даёт доступа к физическим реестрам.
	var visible := 0
	var pending := 0
	for slot in _slots:
		if float(slot["life"]) > 0.0:
			visible += 1
		if bool(slot["thunder_pending"]):
			pending += 1
	return {
		"last_played_day": _last_played_day,
		"slots": _slots.size(), "visible": visible,
		"pending_thunder": pending, "shown_total": _accepted_bolts
	}
