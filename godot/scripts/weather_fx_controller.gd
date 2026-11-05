extends Node3D
## Этап 11.0: лёгкий камерный рендер дождя и снега.
## Узел никогда не изменяет климат, грунт, гидрологию и природные объекты.

const VisualState = preload("res://scripts/weather_visual_state.gd")
const RAIN_PARTICLES := 640
const SNOW_PARTICLES := 320

var _rain: GPUParticles3D
var _snow: GPUParticles3D
var _enabled := true
var _last_state: Dictionary = {}
var _quality := 1


func _ready() -> void:
	## Эмиттеры создаются один раз, затем меняются только параметры.
	## Это исключает сотни новых узлов при каждом перемещении камеры.
	_rain = _make_emitter("Дождь", Color(0.67, 0.80, 0.94, 0.48),
		Vector2(0.035, 0.46), RAIN_PARTICLES, 17.0, 1.7)
	_snow = _make_emitter("Снег", Color(0.96, 0.97, 1.0, 0.86),
		Vector2(0.14, 0.14), SNOW_PARTICLES, 3.4, 5.5)


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


func sync_world(climate: RefCounted, world: RefCounted,
		center: Vector2, zoom: float) -> void:
	## Читаем физические данные лишь после окончания фонового расчёта дня.
	## За один вызов запрашиваем пять клеток вместо всей карты.
	var snapshot: Dictionary = VisualState.sample(
		climate, world.config, center, zoom)
	var height: float = world.height_at(center)
	var altitude := world.config.to_scene(center, height).y
	apply_snapshot(snapshot, center, altitude, zoom, world.config.world_seed)


func apply_snapshot(state: Dictionary, center: Vector2,
		altitude: float, zoom: float, seed: int) -> void:
	## Снимок не связан с исходным словарём: рендер не может случайно
	## изменить параметры погоды или испортить сохранение мира.
	_last_state = state.duplicate(true)
	if _rain == null or _snow == null:
		return
	var distance := clampf(zoom * 0.7, 10.0, 70.0)
	var quality_factor := [0.36, 0.72, 1.0][_quality]
	for emitter in [_rain, _snow]:
		# Область осадков следует за камерой и не растёт до размера карты.
		emitter.position = Vector3(center.x, altitude + 22.0, center.y)
		var material: ParticleProcessMaterial = emitter.process_material
		material.emission_box_extents = Vector3(distance, 5.0, distance)
		emitter.seed = seed
	_rain.amount_ratio = clampf(float(state.get("rain", 0.0))
		* quality_factor, 0.0, 1.0)
	_snow.amount_ratio = clampf(float(state.get("snow", 0.0))
		* quality_factor, 0.0, 1.0)
	_rain.emitting = _enabled and _rain.amount_ratio >= 0.025
	_snow.emitting = _enabled and _snow.amount_ratio >= 0.025


func debug_state() -> Dictionary:
	## Контракт теста: можно читать графический снимок, но не владеть им.
	return _last_state.duplicate(true)
