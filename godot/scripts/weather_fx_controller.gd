extends Node3D
## Этап 11.0: камерный рендер всех осадков, ветра и пылевых завес.
## Узел никогда не изменяет климат, грунт, гидрологию и природные объекты.

const VisualState = preload("res://scripts/weather_visual_state.gd")
const PrecipitationShader = preload("res://shaders/local_precipitation.gdshader")
const TornadoShader = preload("res://shaders/tornado_funnel.gdshader")
const DustHazeShader = preload("res://shaders/wind_dust_haze.gdshader")
const RAIN_PARTICLES := 640
const MASK_SIZE := 17
const MASK_STEP := 6.0
const MASK_SPAN := MASK_SIZE * MASK_STEP
const SNOW_PARTICLES := 320
const WET_SNOW_PARTICLES := 220
const HAIL_PARTICLES := 180
const SPLASH_PARTICLES := 240
const DRIFT_PARTICLES := 180
const TORNADO_RINGS := 19
const TORNADO_SIDES := 24

var _rain: GPUParticles3D
var _snow: GPUParticles3D
var _wet_snow: GPUParticles3D
var _hail: GPUParticles3D
var _splashes: GPUParticles3D
var _snowdrift: GPUParticles3D
var _gusts: GPUParticles3D
var _dust: GPUParticles3D
var _tornado_funnel: MeshInstance3D
var _dust_haze: MeshInstance3D
var _tornado_phase := 0.0
var _event_origin := Vector3.ZERO
var _event_has_origin := false
var _event_aerosol := 1.0
var _event_life := 0.0
var _event_severity := 0.0
var _event_direction := Vector2.ZERO
var _event_squall := false
var _event_hurricane := false
var _event_tornado := false
var _event_dust := false
var _enabled := true
var _last_state: Dictionary = {}
var _quality := 1
var _mask_texture: ImageTexture
var _mask_origin := Vector2.ZERO
var _mask_revision := -1
var _mask_climate: RefCounted
var _mask_peak := Vector2.ZERO
var _mask_special_peak := Vector2.ZERO


func _ready() -> void:
	## Эмиттеры создаются один раз, затем меняются только параметры.
	## Это исключает сотни новых узлов при каждом перемещении камеры.
	_rain = _make_emitter("Дождь", Color(0.67, 0.80, 0.94, 0.48),
		Vector2(0.082, 0.71), RAIN_PARTICLES, 17.0, 1.7)
	_snow = _make_emitter("Снег", Color(0.96, 0.97, 1.0, 0.86),
		Vector2(0.24, 0.24), SNOW_PARTICLES, 3.4, 5.5)
	# Мокрые крупные хлопья, плотные градины, брызги и позёмка
	# отделены силуэтом, но не имеют собственной физики погоды.
	_wet_snow = _make_emitter("Мокрый снег",
		Color(0.85, 0.90, 0.96, 0.84),
		Vector2(0.31, 0.48), WET_SNOW_PARTICLES, 8.0, 2.4)
	_hail = _make_emitter("Град", Color(0.95, 0.96, 0.99, 0.93),
		Vector2(0.115, 0.16), HAIL_PARTICLES, 24.0, 1.4)
	_splashes = _make_emitter("Брызги дождя",
		Color(0.76, 0.86, 0.97, 0.48),
		Vector2(0.38, 0.18), SPLASH_PARTICLES, 2.5, 0.72)
	_snowdrift = _make_emitter("Снежная взвесь",
		Color(0.89, 0.95, 1.0, 0.46),
		Vector2(0.85, 0.12), DRIFT_PARTICLES, 8.0, 1.4)
	var emitters := [_rain, _snow, _wet_snow, _hail, _splashes, _snowdrift]
	for kind in range(emitters.size()):
		# Один GPU-шейдер использует шесть форм; количество
		# узлов и их максимум фиксируются при создании контроллера.
		var emitter: GPUParticles3D = emitters[kind]
		var quad := emitter.draw_pass_1 as QuadMesh
		var previous := quad.material as StandardMaterial3D
		var material := ShaderMaterial.new()
		material.shader = PrecipitationShader
		material.set_shader_parameter("particle_color", previous.albedo_color)
		material.set_shader_parameter("particle_kind", kind)
		material.set_shader_parameter("snow", kind == 1)
		quad.material = material
		emitter.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		emitter.local_coords = false
	var splash_motion := _splashes.process_material as ParticleProcessMaterial
	splash_motion.direction = Vector3.UP
	splash_motion.spread = 55.0
	splash_motion.gravity = Vector3(0.0, -8.0, 0.0)
	var drift_motion := _snowdrift.process_material as ParticleProcessMaterial
	drift_motion.gravity = Vector3.ZERO
	drift_motion.spread = 12.0
	# Разреженные горизонтальные полосы показывают порывы над картой.
	# Это один GPU-эмиттер, а не отдельный Node3D на каждую частицу.
	_gusts = _make_emitter("Порывы ветра",
		Color(0.83, 0.87, 0.76, 0.23),
		Vector2(0.92, 0.035), 300, 16.0, 1.1)
	# Прозрачные края порывов смягчают штрихи на фоне грунта.
	var gust_gradient := Gradient.new()
	gust_gradient.offsets = PackedFloat32Array([0.0, 0.42, 1.0])
	gust_gradient.colors = PackedColorArray([
		Color(1.0, 1.0, 1.0, 0.0), Color.WHITE, Color(1.0, 1.0, 1.0, 0.0)])
	var gust_texture := GradientTexture2D.new()
	gust_texture.width = 32
	gust_texture.height = 1
	gust_texture.gradient = gust_gradient
	var gust_mesh := _gusts.draw_pass_1 as QuadMesh
	var gust_material := gust_mesh.material as StandardMaterial3D
	gust_material.albedo_texture = gust_texture
	var gust_motion: ParticleProcessMaterial = _gusts.process_material
	gust_motion.gravity = Vector3.ZERO
	gust_motion.spread = 12.0
	gust_motion.initial_velocity_min = 9.0
	gust_motion.initial_velocity_max = 18.0
	# Отдельный фиксированный GPU-эмиттер для цветной низкой
	# пылевой завесы; количество узлов не растёт с площадью мира.
	_dust = _make_emitter("Пылевая завеса",
		Color(0.73, 0.58, 0.35, 0.24),
		Vector2(0.95, 0.46), 220, 13.0, 2.1)
	var dust_motion: ParticleProcessMaterial = _dust.process_material
	dust_motion.gravity = Vector3(0.0, 0.12, 0.0)
	dust_motion.spread = 11.0
	# Мягкий радиальный альфа-градиент вместо прямоугольных
	# пылевых карточек. Материал создаётся один раз.
	var fade := Gradient.new()
	fade.offsets = PackedFloat32Array([0.0, 0.42, 1.0])
	fade.colors = PackedColorArray([
		Color(1.0, 1.0, 1.0, 0.95),
		Color(1.0, 1.0, 1.0, 0.48),
		Color(1.0, 1.0, 1.0, 0.0)])
	var texture := GradientTexture2D.new()
	texture.width = 128
	texture.height = 128
	texture.fill = GradientTexture2D.FILL_RADIAL
	texture.fill_from = Vector2(0.5, 0.5)
	texture.fill_to = Vector2(0.5, 0.0)
	texture.gradient = fade
	var dust_quad := _dust.draw_pass_1 as QuadMesh
	(dust_quad.material as StandardMaterial3D).albedo_texture = texture
	# Одна многоугольная воронка вместо нескольких сотен узлов.
	_tornado_funnel = MeshInstance3D.new()
	_tornado_funnel.name = "Спиральная воронка физического смерча"
	_tornado_funnel.mesh = _build_tornado_mesh()
	_tornado_funnel.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var funnel_material := ShaderMaterial.new()
	funnel_material.shader = TornadoShader
	_tornado_funnel.material_override = funnel_material
	_tornado_funnel.visible = false
	add_child(_tornado_funnel)
	# Один мягкий шлейф над реальным сухим участком. GPU-частиц
	# больше не выделяется, а грунт не пересчитывается в рендере.
	_dust_haze = MeshInstance3D.new()
	_dust_haze.name = "Приземная аэрозольная завеса"
	var sheet := PlaneMesh.new()
	sheet.size = Vector2(58.0, 28.0)
	_dust_haze.mesh = sheet
	var haze_material := ShaderMaterial.new()
	haze_material.shader = DustHazeShader
	_dust_haze.material_override = haze_material
	_dust_haze.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_dust_haze.visible = false
	add_child(_dust_haze)


func _process(delta: float) -> void:
	# Всплеск строго ограничен временем и относится к уже случившемуся
	# физическому событию. При скрытом режиме не изменяем модель ветра.
	if _event_life <= 0.0 or not is_finite(delta) or delta <= 0.0:
		return
	if is_inside_tree() and get_tree().paused:
		# Игровая пауза не должна сокращать визуальную жизнь
		# уже завершённого физического шторма.
		return
	_event_life = maxf(0.0, _event_life - delta)
	# Только материал вращается, коллизии и физический след
	# не меняются. Пауза уже обработана выше.
	if _tornado_funnel != null:
		_tornado_phase += delta
		if _event_tornado:
			(_tornado_funnel.material_override as ShaderMaterial).set_shader_parameter(
				"animation_phase", _tornado_phase)
		if _dust_haze != null and _dust_haze.visible:
			(_dust_haze.material_override as ShaderMaterial).set_shader_parameter(
				"animation_phase", _tornado_phase)
	if _event_life == 0.0 and _gusts != null:
		if _tornado_funnel != null:
			_tornado_funnel.visible = false
		if _dust_haze != null:
			_dust_haze.visible = false
		_gusts.emitting = false
		_event_squall = false
		_event_hurricane = false
		_event_tornado = false
		_event_dust = false
		_event_has_origin = false
		if _dust != null:
			_dust.emitting = false
			_dust.visible = false


func show_storm_event(severity: float, direction: Vector2,
		duration: float = 4.0) -> void:
	# Только визуальный отклик на реальный hazard из суточного результата;
	# не создаём новую грозу и не передаём силу назад в Climate.
	_event_life = maxf(0.0, duration)
	_tornado_phase = 0.0
	_event_squall = false
	_event_hurricane = false
	_event_tornado = false
	_event_dust = false
	_event_has_origin = false
	_event_aerosol = 1.0
	if _tornado_funnel != null:
		_tornado_funnel.visible = false
	if _dust_haze != null:
		_dust_haze.visible = false
	_event_severity = clampf(severity, 0.0, 1.0)
	_event_direction = direction.normalized() if direction.length_squared() > 0.0 		else Vector2.RIGHT


func show_squall_event(severity: float, direction: Vector2,
		duration: float = 2.8) -> void:
	# Шквал короче шторма, но его полоса порывов движется быстрее.
	# Метод меняет только один визуальный эмиттер, не сам климат.
	show_storm_event(severity, direction, duration)
	_event_squall = true


func show_hurricane_event(severity: float, direction: Vector2,
		duration: float = 6.5) -> void:
	# Ураган оставляет широкий и более продолжительный след
	# над камерой. Это только отклик на уже случившуюся физику.
	show_storm_event(severity, direction, duration)
	_event_hurricane = true


func show_tornado_event(severity: float, direction: Vector2,
		duration: float = 4.8, origin: Vector3 = Vector3.ZERO,
		located: bool = false) -> void:
	# Положение получаем от фактического события, а не от камеры;
	# старые smoke без координат сохраняют камерный fallback.
	show_storm_event(severity, direction, duration)
	_event_tornado = true
	_event_origin = origin
	_event_has_origin = located
	_tornado_phase = 0.0
	if _tornado_funnel != null:
		_tornado_funnel.visible = _enabled and _event_life > 0.0
		_tornado_funnel.position = origin
		(_tornado_funnel.material_override as ShaderMaterial).set_shader_parameter(
			"severity", _event_severity)


func show_dust_storm_event(severity: float, direction: Vector2,
		duration: float = 5.0, sediment_volume: float = -1.0,
		origin: Vector3 = Vector3.ZERO, located: bool = false) -> void:
	# Интенсивность завесы следует за объёмом грунта, который
	# реально перенёс NaturalDisasters. Старый API тестов без
	# массы использует прежнюю интенсивность и остаётся совместим.
	show_storm_event(severity, direction, duration)
	_event_dust = true
	_event_origin = origin
	_event_has_origin = located
	_event_aerosol = 1.0 if sediment_volume < 0.0 else (
		clampf(sediment_volume / 0.042, 0.0, 1.0))
	_tornado_phase = 0.0
	if _dust_haze != null:
		_dust_haze.position = origin + Vector3.UP * 3.0
		_dust_haze.rotation.y = -atan2(_event_direction.y,
			_event_direction.x)
		_dust_haze.visible = _enabled and _event_aerosol > 0.025
		(_dust_haze.material_override as ShaderMaterial).set_shader_parameter(
			"transported_mass", _event_aerosol * _event_severity)



func _build_tornado_mesh() -> ArrayMesh:
	# 19 колец и 24 сегмента: узкая ножка у земли плавно
	# расширяется к туче. Сетка строится при создании узла
	# и не пересоздаётся в процессе анимации.
	var vertices := PackedVector3Array()
	var uvs := PackedVector2Array()
	var indices := PackedInt32Array()
	for level in range(TORNADO_RINGS):
		var progress := float(level) / float(TORNADO_RINGS - 1)
		var radius := 1.1 + pow(progress, 1.62) * 7.9
		var centre := Vector2(2.3 * progress,
			sin(progress * TAU * 1.3) * 1.25 * progress)
		for side in range(TORNADO_SIDES + 1):
			var theta := TAU * float(side) / float(TORNADO_SIDES)
			vertices.append(Vector3(
				centre.x + cos(theta) * radius,
				0.45 + progress * 33.0,
				centre.y + sin(theta) * radius))
			uvs.append(Vector2(float(side) / float(TORNADO_SIDES), progress))
	for level in range(TORNADO_RINGS - 1):
		for side in range(TORNADO_SIDES):
			var a := level * (TORNADO_SIDES + 1) + side
			var b := a + TORNADO_SIDES + 1
			indices.append_array(PackedInt32Array([
				a, b, a + 1, b, b + 1, a + 1]))
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh

func _make_emitter(title: String, color: Color, size: Vector2,
		amount: int, speed: float, life: float) -> GPUParticles3D:
	## Создаём единый GPU-эмиттер без отдельных Node3D на каплю.
	## Шейдеры частиц не содержат логики возникновения погоды.
	var emitter := GPUParticles3D.new()
	emitter.name = title
	emitter.amount = amount
	emitter.lifetime = life
	emitter.local_coords = true
	emitter.use_fixed_seed = true
	emitter.emitting = false
	emitter.visibility_aabb = AABB(
		Vector3(-90.0, -80.0, -90.0), Vector3(180.0, 160.0, 180.0))

	var motion := ParticleProcessMaterial.new()
	motion.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	motion.emission_box_extents = Vector3(20.0, 6.0, 20.0)
	motion.direction = Vector3.DOWN
	motion.spread = 14.0 if speed > 10.0 else 30.0
	motion.initial_velocity_min = speed * 0.78
	motion.initial_velocity_max = speed * 1.12
	motion.gravity = Vector3(0.0, -1.3, 0.0)
	emitter.process_material = motion

	# Недорогие прозрачные плоскости читаются как полосы дождя или снежинки.
	var quad := QuadMesh.new()
	quad.size = size
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.albedo_color = color
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	material.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	quad.material = material
	emitter.draw_pass_1 = quad
	add_child(emitter)
	return emitter


func set_quality(level: int) -> void:
	## Для слабого GPU используем ту же физическую погоду, но меньше частиц.
	## Расчёты физики не зависят от графического уровня качества.
	_quality = clampi(level, 0, 2)


func set_effects_enabled(enabled: bool) -> void:
	## Диагностика и маршруты производительности могут скрыть эффекты,
	## не останавливая суточные события, урон или изменения ландшафта.
	_enabled = enabled
	if not enabled and _rain != null:
		# Прячем уже рожденные частицы и остатки события:
		# обычное emitting=false само по себе не гасит старый кадр.
		for emitter in [_rain, _snow, _wet_snow, _hail,
				_splashes, _snowdrift, _gusts, _dust]:
			emitter.emitting = false
			emitter.visible = false
		_event_life = 0.0
		_event_squall = false
		_event_hurricane = false
		_event_tornado = false
		_event_dust = false
		_event_has_origin = false
		if _tornado_funnel != null:
			_tornado_funnel.visible = false
		if _dust_haze != null:
			_dust_haze.visible = false


func clear_visuals() -> void:
	# После загрузки или замены мира запрещаем утечку старых
	# масок фронта, эмиттеров и незавершённых штормовых эффектов.
	# При следующем sync_world строится снимок нового Climate.
	var was_enabled := _enabled
	set_effects_enabled(false)
	_last_state.clear()
	_mask_climate = null
	_mask_revision = -1
	_mask_peak = Vector2.ZERO
	_mask_special_peak = Vector2.ZERO
	_mask_origin = Vector2.ZERO
	_event_aerosol = 1.0
	if _dust_haze != null:
		_dust_haze.visible = false
	_tornado_phase = 0.0
	# Оставляем настройку качества: это пользовательское предпочтение.
	# Новую физику и сохранения этот сброс не затрагивает.
	_enabled = was_enabled


func sync_world(climate: RefCounted, world: RefCounted,
		center: Vector2, zoom: float) -> void:
	## Читаем физические данные лишь после окончания фонового расчёта дня.
	## За один вызов запрашиваем пять клеток вместо всей карты.
	var snapshot: Dictionary = VisualState.sample(
		climate, world.config, center, zoom)
	if _enabled and zoom < 105.0 and _rain != null:
		_update_precipitation_mask(climate, world.config, center)
		snapshot["rain"] = _mask_peak.x
		snapshot["snow"] = _mask_peak.y
		snapshot["hail"] = _mask_special_peak.x
		snapshot["wet_snow"] = _mask_special_peak.y
	var height: float = world.height_at(center)
	var altitude: float = world.config.to_scene(center, height).y
	apply_snapshot(snapshot, center, altitude, zoom, world.config.world_seed)


func _update_precipitation_mask(climate: RefCounted, config: RefCounted,
		center: Vector2) -> void:
	# Общая карта для дождя и снега, в мировых координатах. Сухие
	# области отсекаются даже при сносе частицы из соседней мокрой клетки.
	var origin := center.snappedf(MASK_STEP) - Vector2.ONE * MASK_SPAN * 0.5
	if _mask_climate == climate and _mask_revision == climate.revision and origin == _mask_origin:
		return
	_mask_origin = origin
	_mask_revision = climate.revision
	_mask_climate = climate
	_mask_peak = Vector2.ZERO
	_mask_special_peak = Vector2.ZERO
	var image := Image.create_empty(MASK_SIZE, MASK_SIZE, false,
		Image.FORMAT_RGBA8)
	for y in range(MASK_SIZE):
		for x in range(MASK_SIZE):
			var point := origin + (Vector2(x, y) + Vector2(0.5, 0.5)) * MASK_STEP
			if point.x < 0.0 or point.y < 0.0 or point.x >= config.width 					or point.y >= config.height:
				continue
			var weather: Dictionary = climate.weather_at(config.cell_at(point))
			var rain := clampf(float(weather["rainfall"]) / 2.4, 0.0, 1.0)
			var snow := clampf(float(weather["snowfall"]) / 2.4, 0.0, 1.0)
			var kinds: Dictionary = VisualState.from_weather(weather)
			var hail: float = float(kinds["hail"])
			var wet: float = float(kinds["wet_snow"])
			_mask_peak = _mask_peak.max(Vector2(rain, snow))
			_mask_special_peak = _mask_special_peak.max(Vector2(hail, wet))
			image.set_pixel(x, y, Color(rain, snow, hail, wet))
	if _mask_texture == null:
		_mask_texture = ImageTexture.create_from_image(image)
	else:
		_mask_texture.update(image)
	for emitter in [_rain, _snow, _wet_snow, _hail, _splashes, _snowdrift]:
		var material := emitter.draw_pass_1.material as ShaderMaterial
		material.set_shader_parameter("precipitation_map", _mask_texture)
		material.set_shader_parameter("map_origin", origin)
		material.set_shader_parameter("map_span", MASK_SPAN)
		material.set_shader_parameter("use_map", true)


func apply_snapshot(state: Dictionary, center: Vector2,
		altitude: float, zoom: float, world_seed: int) -> void:
	## Снимок не связан с исходным словарём: рендер не может случайно
	## изменить параметры погоды или испортить сохранение мира.
	_last_state = state.duplicate(true)
	if _rain == null or _snow == null or _gusts == null:
		return
	var distance := clampf(zoom * 0.7, 10.0, 70.0)
	# Видимость воронки согласована с тем же LOD, что и частицы:
	# дальний обзор не получает крупный объект вне масштаба.
	var event_visible := _enabled and _event_life > 0.0 and zoom < 105.0
	if _tornado_funnel != null:
		_tornado_funnel.visible = event_visible and _event_tornado
		if _event_tornado and not _event_has_origin:
			_tornado_funnel.position = Vector3(center.x, altitude, center.y)
		_tornado_funnel.rotation.y = -atan2(
			_event_direction.y, _event_direction.x)
	if _dust_haze != null:
		# Сохраняем одну сетку и для штормовых потоков, и для
		# пыльного вихря. Цвета и полоса выбираются лишь по
		# реально зарегистрированному виду NaturalDisasters.
		var mode := 0
		var sheet_intensity := 0.0
		var sheet_size := Vector2(58.0, 28.0)
		if _event_dust:
			mode = 0
			sheet_intensity = _event_severity * _event_aerosol
		elif _event_squall:
			mode = 2
			sheet_intensity = _event_severity * 0.94
			sheet_size = Vector2(74.0, 13.0)
		elif _event_hurricane:
			mode = 3
			sheet_intensity = _event_severity * 0.95
			sheet_size = Vector2(90.0, 80.0)
		elif _event_life > 0.0 and not _event_tornado:
			mode = 1
			sheet_intensity = _event_severity * 0.65
			sheet_size = Vector2(77.0, 47.0)
		_dust_haze.visible = event_visible and not _event_tornado \
			and sheet_intensity > 0.025
		if not _event_has_origin:
			_dust_haze.position = Vector3(center.x, altitude + 3.0, center.y)
		_dust_haze.rotation.y = -atan2(_event_direction.y,
			_event_direction.x)
		# Размеры геометрии меняем только при переходе к другому
		# типу ветрового бедствия, а не каждые 0.35 с у камеры.
		var sheet_mesh := _dust_haze.mesh as PlaneMesh
		if sheet_mesh.size != sheet_size:
			sheet_mesh.size = sheet_size
		var veil_material := _dust_haze.material_override as ShaderMaterial
		veil_material.set_shader_parameter("event_mode", mode)
		veil_material.set_shader_parameter("transported_mass",
			clampf(sheet_intensity, 0.0, 1.0))
	var quality_factor: float = [0.36, 0.72, 1.0][_quality]
	var precipitation_lod := 1.0 - smoothstep(72.0, 105.0, zoom)
	# Ветровой снос наследует нормализованное направление пяти
	# климатических проб. При ручных старых снимках без направления
	# вертикальные осадки остаются совместимыми.
	var airflow := Vector2(float(state.get("wind_x", 0.0)),
		float(state.get("wind_y", 0.0)))
	if airflow.length_squared() > 0.000001:
		airflow = airflow.normalized()
	var gust := clampf(float(state.get("gust", state.get("wind", 0.0))),
		0.0, 1.0)
	var storm := clampf(float(state.get("storm", 0.0)), 0.0, 1.0)
	if _event_life > 0.0:
		# Экранное испытание выводит след именно зарегистрированного
		# ураганного эпизода; физическая текущая погода не меняется.
		storm = maxf(storm, _event_severity)
		gust = maxf(gust, 0.9 * _event_severity)
		airflow = _event_direction
	for emitter in [_rain, _snow, _gusts]:
		# Область осадков следует за камерой и не растёт до размера карты.
		emitter.position = Vector3(center.x,
			altitude + (10.0 if emitter == _gusts else 22.0), center.y)
		var material: ParticleProcessMaterial = emitter.process_material
		var extent := distance if emitter == _gusts else minf(distance, 34.0)
		material.emission_box_extents = Vector3(extent, 5.0, extent)
		if emitter == _gusts:
			# Физический смерч концентрирует порывы непосредственно
			# вокруг своей воронки, а не в произвольной точке камеры.
			if _event_tornado and _event_has_origin and _event_life > 0.0:
				emitter.position = _event_origin + Vector3.UP * 10.0
			# У шквала плотная узкая полоса и высокая скорость; у
			# продолжительной грозы — широкая зона порывов над картой.
			var visible_squall := _event_squall and _event_life > 0.0
			var visible_hurricane := _event_hurricane and _event_life > 0.0
			var visible_tornado := _event_tornado and _event_life > 0.0
			# Шквал вытянут узкой полосой; ураган покрывает большую
			# площадь, но использует всё тот же один GPU-эмиттер.
			material.emission_box_extents = Vector3(
				distance * (0.35 if visible_tornado else (
					1.20 if visible_hurricane else (0.65 if visible_squall else 1.0))),
				7.0 if visible_tornado else (3.0 if visible_squall else 5.0),
				distance * (0.20 if visible_tornado else (
					1.20 if visible_hurricane else (0.30 if visible_squall else 1.0))))
			material.initial_velocity_min = 24.0 if visible_tornado else (
				20.0 if visible_hurricane else (14.0 if visible_squall else 9.0))
			material.initial_velocity_max = 38.0 if visible_tornado else (
				34.0 if visible_hurricane else (26.0 if visible_squall else 18.0))
			material.direction = Vector3(airflow.x, 0.0, airflow.y)
		else:
			# Снежинки сносит сильнее, чем капли дождя.
			var drift := gust * (1.25 if emitter == _snow else 0.42)
			material.direction = Vector3(
				airflow.x * drift, -1.0, airflow.y * drift).normalized()
		emitter.seed = world_seed
	# Самостоятельные формы не дублируют весь дождь и снег:
	# часть мощности переходит в град или мокрый снег.
	var hail_strength := clampf(float(state.get("hail", 0.0)), 0.0, 1.0)
	var wet_strength := clampf(float(state.get("wet_snow", 0.0)), 0.0, 1.0)
	var downpour := clampf(float(state.get("downpour", 0.0)), 0.0, 1.0)
	var drizzle := clampf(float(state.get("drizzle", 0.0)), 0.0, 1.0)
	var blizzard := clampf(float(state.get("blizzard", 0.0)), 0.0, 1.0)
	_rain.amount_ratio = clampf(float(state.get("rain", 0.0))
		* (1.0 - hail_strength * 0.55 - wet_strength * 0.25)
		* quality_factor * precipitation_lod, 0.0, 1.0)
	_snow.amount_ratio = clampf(float(state.get("snow", 0.0))
		* (1.0 - wet_strength * 0.70)
		* quality_factor * precipitation_lod, 0.0, 1.0)
	# Морось остаётся тонкой и прозрачной, ливень заметно
	# уплотняет и удлиняет струи без создания новых объектов.
	var rain_quad := _rain.draw_pass_1 as QuadMesh
	rain_quad.size = Vector2(lerpf(0.045, 0.12, downpour),
		lerpf(0.37, 1.25, downpour))
	var rain_motion := _rain.process_material as ParticleProcessMaterial
	rain_motion.initial_velocity_min = lerpf(9.0, 21.0, downpour)
	rain_motion.initial_velocity_max = lerpf(14.0, 29.0, downpour)
	var rain_shader := rain_quad.material as ShaderMaterial
	rain_shader.set_shader_parameter("visual_intensity",
		lerpf(0.48, 1.40, downpour) * (1.0 - drizzle * 0.22))
	_rain.emitting = _enabled and _rain.amount_ratio >= 0.025
	_snow.emitting = _enabled and _snow.amount_ratio >= 0.025
	_rain.visible = _rain.emitting
	_snow.visible = _snow.emitting
	# Снег и дождь расходуют собственный фиксированный бюджет.
	# Низовые брызги/взвесь не участвуют в геологии и исчезают
	# на дальнем масштабе или при отключении графических эффектов.
	_apply_precipitation_details(state, center, altitude, distance,
		quality_factor * precipitation_lod, airflow, gust, world_seed,
		hail_strength, wet_strength, blizzard, downpour)
	# На обычном ветре штормовые полосы не возникают.
	_gusts.amount_ratio = clampf(
		storm * smoothstep(0.15, 0.65, gust) * quality_factor, 0.0, 1.0)
	if (_event_squall or _event_hurricane or _event_tornado) \
			and _event_life > 0.0:
		# На пике шквала и урагана усиливаем видимые порывы,
		# сохраняя установленный пользователем уровень качества.
		_gusts.amount_ratio = maxf(_gusts.amount_ratio,
			_event_severity * quality_factor)
	_gusts.amount_ratio *= precipitation_lod
	_gusts.emitting = _enabled and _gusts.amount_ratio >= 0.08
	_gusts.visible = _gusts.emitting
	# Сухая буря рисуется низко над грунтом. Ширина и число частиц
	# зависят от приближения камеры и уровня качества, а не от FPS.
	# Пыль поднимается у физического эпицентра бедствия.
	# Количество и насыщенность зависят от фактической массы
	# грунта, перенесённой NaturalDisasters, а не от числа кадров.
	_dust.position = _event_origin + Vector3.UP * 2.4 \
		if _event_has_origin else Vector3(center.x, altitude + 2.4, center.y)
	var dust_motion: ParticleProcessMaterial = _dust.process_material
	var dust_strength := 0.0
	if _event_dust and _event_life > 0.0:
		dust_strength = _event_severity * _event_aerosol
	elif _event_tornado and _event_life > 0.0:
		# Низовой пылевой вихрь использует тот же эмиттер;
		# второй аэрозольный бюджет не создаём.
		dust_strength = _event_severity * 0.23
	dust_motion.emission_box_extents = Vector3(
		distance * (0.23 if _event_tornado else 0.78),
		0.7 if _event_tornado else 2.0,
		distance * (0.22 if _event_tornado else 0.46))
	dust_motion.direction = Vector3(airflow.x, 0.14, airflow.y).normalized()
	dust_motion.initial_velocity_min = lerpf(6.0, 13.0, dust_strength)
	dust_motion.initial_velocity_max = lerpf(10.0, 22.0, dust_strength)
	var dust_quad := _dust.draw_pass_1 as QuadMesh
	dust_quad.size = Vector2(lerpf(0.78, 1.62, dust_strength),
		lerpf(0.44, 1.08, dust_strength))
	var dust_material := dust_quad.material as StandardMaterial3D
	dust_material.albedo_color = Color(0.73, 0.58, 0.35,
		0.11 + dust_strength * 0.28)
	_dust.seed = world_seed + 71
	_dust.amount_ratio = clampf(
		dust_strength * quality_factor * precipitation_lod, 0.0, 1.0)
	_dust.emitting = _enabled and _dust.amount_ratio >= 0.025
	_dust.visible = _dust.emitting


func _apply_precipitation_details(state: Dictionary, center: Vector2,
		altitude: float, distance: float, budget: float,
		airflow: Vector2, gust: float, world_seed: int,
		hail: float, wet: float, blizzard: float,
		downpour: float) -> void:
	# Детальные частицы имеют постоянные эмиттеры и порог
	# появления. Сила зависит от снимка, но не от числа кадров.
	var rain := clampf(float(state.get("rain", 0.0)), 0.0, 1.0)
	var snow := clampf(float(state.get("snow", 0.0)), 0.0, 1.0)
	var kinds := [_wet_snow, _hail, _splashes, _snowdrift]
	var densities := [
		wet * 0.85, hail * 0.72,
		rain * (0.13 + downpour * 0.82),
		snow * blizzard * 0.9
	]
	for index in range(kinds.size()):
		var emitter: GPUParticles3D = kinds[index]
		var near_ground := index >= 2
		emitter.position = Vector3(center.x,
			altitude + (0.75 if near_ground else 22.0), center.y)
		var motion := emitter.process_material as ParticleProcessMaterial
		motion.emission_box_extents = Vector3(minf(distance, 34.0),
			0.25 if near_ground else 5.0, minf(distance, 34.0))
		motion.direction = Vector3(airflow.x * gust * 2.0, -1.0,
			airflow.y * gust * 2.0).normalized()
		if index == 0:
			# Мокрые хлопья заметно тяжелее сухого снега.
			motion.initial_velocity_min = 7.0
			motion.initial_velocity_max = 11.0
		elif index == 1:
			# Град падает резко; отдельно не повреждает объекты.
			motion.initial_velocity_min = 21.0
			motion.initial_velocity_max = 28.0
		elif index == 2:
			# Поверхностная вспышка брызг только в дождевом фронте.
			motion.direction = Vector3.UP
			motion.initial_velocity_min = 1.3
			motion.initial_velocity_max = 3.4
		else:
			# Низовой снег подхватывает только уже существующий ветер.
			motion.direction = Vector3(airflow.x, 0.04,
				airflow.y).normalized() if airflow.length_squared() > 0.000001 \
				else Vector3.ZERO
			motion.initial_velocity_min = 5.0
			motion.initial_velocity_max = 13.0
		emitter.seed = world_seed + 101 + index
		emitter.amount_ratio = clampf(float(densities[index]) * budget, 0.0, 1.0)
		emitter.emitting = _enabled and emitter.amount_ratio >= 0.025
		emitter.visible = emitter.emitting
	var wet_shader := _wet_snow.draw_pass_1.material as ShaderMaterial
	wet_shader.set_shader_parameter("visual_intensity", 1.1)
	var hail_shader := _hail.draw_pass_1.material as ShaderMaterial
	hail_shader.set_shader_parameter("visual_intensity", 1.15)
	var splash_shader := _splashes.draw_pass_1.material as ShaderMaterial
	splash_shader.set_shader_parameter("visual_intensity", 0.65 + downpour * 0.8)
	var drift_shader := _snowdrift.draw_pass_1.material as ShaderMaterial
	drift_shader.set_shader_parameter("visual_intensity", 0.60 + blizzard * 0.65)


func debug_state() -> Dictionary:
	## Контракт теста: можно читать графический снимок, но не владеть им.
	return _last_state.duplicate(true)
