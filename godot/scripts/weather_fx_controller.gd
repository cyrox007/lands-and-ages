extends Node3D
## Этап 11.0: лёгкий камерный рендер дождя и снега.
## Узел никогда не изменяет климат, грунт, гидрологию и природные объекты.

const VisualState = preload("res://scripts/weather_visual_state.gd")
const PrecipitationShader = preload("res://shaders/local_precipitation.gdshader")
const RAIN_PARTICLES := 640
const MASK_SIZE := 17
const MASK_STEP := 6.0
const MASK_SPAN := MASK_SIZE * MASK_STEP
const SNOW_PARTICLES := 320

var _rain: GPUParticles3D
var _snow: GPUParticles3D
var _gusts: GPUParticles3D
var _dust: GPUParticles3D
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


func _ready() -> void:
	## Эмиттеры создаются один раз, затем меняются только параметры.
	## Это исключает сотни новых узлов при каждом перемещении камеры.
	_rain = _make_emitter("Дождь", Color(0.67, 0.80, 0.94, 0.48),
		Vector2(0.082, 0.71), RAIN_PARTICLES, 17.0, 1.7)
	_snow = _make_emitter("Снег", Color(0.96, 0.97, 1.0, 0.86),
		Vector2(0.24, 0.24), SNOW_PARTICLES, 3.4, 5.5)
	for emitter in [_rain, _snow]:
		var quad := emitter.draw_pass_1 as QuadMesh
		var previous := quad.material as StandardMaterial3D
		var material := ShaderMaterial.new()
		material.shader = PrecipitationShader
		material.set_shader_parameter("particle_color", previous.albedo_color)
		material.set_shader_parameter("snow", emitter == _snow)
		quad.material = material
		emitter.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		emitter.local_coords = false
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


func _process(delta: float) -> void:
	# Всплеск строго ограничен временем и относится к уже случившемуся
	# физическому событию. При скрытом режиме не изменяем модель ветра.
	if _event_life <= 0.0:
		return
	_event_life = maxf(0.0, _event_life - delta)
	if _event_life == 0.0 and _gusts != null:
		_gusts.emitting = false
		_event_squall = false
		_event_hurricane = false
		_event_tornado = false
		_event_dust = false
		if _dust != null:
			_dust.emitting = false


func show_storm_event(severity: float, direction: Vector2,
		duration: float = 4.0) -> void:
	# Только визуальный отклик на реальный hazard из суточного результата;
	# не создаём новую грозу и не передаём силу назад в Climate.
	_event_life = maxf(0.0, duration)
	_event_squall = false
	_event_hurricane = false
	_event_tornado = false
	_event_dust = false
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
		duration: float = 4.8) -> void:
	# Видимый узкий след назначается только после расчёта
	# физического смерча. Отрисовка не создаёт деревьям ущерб.
	show_storm_event(severity, direction, duration)
	_event_tornado = true


func show_dust_storm_event(severity: float, direction: Vector2,
		duration: float = 5.0) -> void:
	# Цветное облако показываем только для уже перенесённого грунта.
	# Эффект не меняет климат и не создаёт дополнительный осадок.
	show_storm_event(severity, direction, duration)
	_event_dust = true


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
		_rain.emitting = false
		_snow.emitting = false
		_rain.hide()
		_snow.hide()
		if _gusts != null:
			_gusts.emitting = false
		if _dust != null:
			_dust.emitting = false


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
	var image := Image.create_empty(MASK_SIZE, MASK_SIZE, false, Image.FORMAT_RG8)
	for y in range(MASK_SIZE):
		for x in range(MASK_SIZE):
			var point := origin + (Vector2(x, y) + Vector2(0.5, 0.5)) * MASK_STEP
			if point.x < 0.0 or point.y < 0.0 or point.x >= config.width 					or point.y >= config.height:
				continue
			var weather: Dictionary = climate.weather_at(config.cell_at(point))
			var rain := clampf(float(weather["rainfall"]) / 2.4, 0.0, 1.0)
			var snow := clampf(float(weather["snowfall"]) / 2.4, 0.0, 1.0)
			_mask_peak = _mask_peak.max(Vector2(rain, snow))
			image.set_pixel(x, y, Color(rain, snow, 0.0))
	if _mask_texture == null:
		_mask_texture = ImageTexture.create_from_image(image)
	else:
		_mask_texture.update(image)
	for emitter in [_rain, _snow]:
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
	_rain.amount_ratio = clampf(float(state.get("rain", 0.0))
		* quality_factor * precipitation_lod, 0.0, 1.0)
	_snow.amount_ratio = clampf(float(state.get("snow", 0.0))
		* quality_factor * precipitation_lod, 0.0, 1.0)
	_rain.emitting = _enabled and _rain.amount_ratio >= 0.025
	_snow.emitting = _enabled and _snow.amount_ratio >= 0.025
	_rain.visible = _rain.emitting
	_snow.visible = _snow.emitting
	# На обычном ветре штормовые полосы не возникают.
	_gusts.amount_ratio = clampf(
		storm * smoothstep(0.15, 0.65, gust) * quality_factor, 0.0, 1.0)
	if (_event_squall or _event_hurricane or _event_tornado) \
			and _event_life > 0.0:
		# На пике шквала и урагана усиливаем видимые порывы,
		# сохраняя установленный пользователем уровень качества.
		_gusts.amount_ratio = maxf(_gusts.amount_ratio,
			_event_severity * quality_factor)
	_gusts.emitting = _enabled and _gusts.amount_ratio >= 0.08
	# Сухая буря рисуется низко над грунтом. Ширина и число частиц
	# зависят от приближения камеры и уровня качества, а не от FPS.
	_dust.position = Vector3(center.x, altitude + 4.5, center.y)
	var dust_motion: ParticleProcessMaterial = _dust.process_material
	dust_motion.emission_box_extents = Vector3(distance * 0.78,
		2.0, distance * 0.46)
	dust_motion.direction = Vector3(airflow.x, 0.13, airflow.y).normalized()
	_dust.seed = world_seed + 71
	_dust.amount_ratio = _event_severity * quality_factor \
		if _event_dust and _event_life > 0.0 else 0.0
	_dust.emitting = _enabled and _dust.amount_ratio >= 0.08


func debug_state() -> Dictionary:
	## Контракт теста: можно читать графический снимок, но не владеть им.
	return _last_state.duplicate(true)
