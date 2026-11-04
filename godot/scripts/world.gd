extends Node3D
## Показ физического рельефа GPU-чанками. Экономика и природные объекты не подключены.

const Terrain = preload("res://scripts/terrain.gd")
const WorldConfig = preload("res://scripts/world_config.gd")
const WorldMap = preload("res://scripts/world_map.gd")
const Relief = preload("res://scripts/relief.gd")
const Chunk = preload("res://scripts/chunk.gd")
const ChunkVisibility = preload("res://scripts/chunk_visibility.gd")
const ChunkRenderCache = preload("res://scripts/chunk_render_cache.gd")
const ChunkBuildQueue = preload("res://scripts/chunk_build_queue.gd")
const ChunkBuildWorker = preload("res://scripts/chunk_build_worker.gd")
const BenchmarkRoute = preload("res://scripts/world_benchmark_route.gd")
const BenchmarkRunner = preload("res://scripts/world_benchmark_runner.gd")
const NaturalGroundShader = preload("res://shaders/natural_ground.gdshader")
const TerrainAlbedo = preload("res://assets/terrain/terrain_albedo.png")
const TerrainNormalRoughness = preload("res://assets/terrain/terrain_normal_roughness.png")
const NaturalWaterShader = preload("res://shaders/natural_water.gdshader")
const Hydrology = preload("res://scripts/hydrology.gd")
const WaterMesh = preload("res://scripts/water_mesh.gd")
const Boundary = preload("res://scripts/world_boundary.gd")
const Surface = preload("res://scripts/surface.gd")
const Climate = preload("res://scripts/climate.gd")
const LandscapeEvents = preload("res://scripts/landscape_events.gd")
const NaturalProcesses = preload("res://scripts/natural_processes.gd")
const NaturalDisasters = preload("res://scripts/natural_disasters.gd")
const WeatherEvents = preload("res://scripts/weather_events.gd")
const WorldDayRunner = preload("res://scripts/world_day_runner.gd")
const WorldSave = preload("res://scripts/world_save.gd")
const Nature = preload("res://scripts/nature_registry.gd")
const NatureRenderer = preload("res://scripts/nature_renderer.gd")
const NatureFelling = preload("res://scripts/nature_felling_visual.gd")
const NatureCollision = preload("res://scripts/nature_collision.gd")

# Радиус 4 используется только для автономных тестов без камеры.
const VIEW_RADIUS := 4
const VIEW_NAMES := [
	"Природная поверхность", "Грунты", "Влажность",
	"Температура", "Климатические области", "Снег",
	"Перенос наносов", "Вода и паводки"
]
const MAX_BUILDS_PER_FRAME := 2
const MAX_NATURE_REFRESHES_PER_FRAME := 2
const MAX_CONCURRENT_CHUNK_JOBS := 2
const MESH_BUDGET_US := 4200
const HEIGHT_BOUNDS_CACHE_LIMIT := 512
const FRAME_SAMPLE_LIMIT := 120
const CAMERA_SPEED := 32.0
const MIN_ZOOM := 16.0
const MAX_ZOOM := 105.0

var _world_model: RefCounted
var _hydro: RefCounted
var _surface: RefCounted
var _climate: RefCounted
var _nature: RefCounted
var _nature_dirty: Dictionary = {}
var _landscape_events: RefCounted
var _natural_processes: RefCounted
var _natural_disasters: RefCounted
var _disaster_status := "Сильных природных событий пока не было"
var _weather_events: RefCounted
var _weather_status := "Молний пока не было"
var _lightning_light: OmniLight3D
var _lightning_life := 0.0
var _process_status := "Естественные процессы ещё не изменяли рельеф"
var _last_event := "Изменений ландшафта нет"
var _view_mode := 0
var _days_pending := 0
var _day_runner: RefCounted
var _day_task_id := -1
var _last_completed_day := 1
var _last_synchronized_world_revision := 0
var _last_day_step_us := 0
var _peak_day_step_us := 0
var _visual_refreshes := 0
var _last_day_profile_us: Dictionary = {}
var _last_day_statistics: Dictionary = {}
var _storage_request := ""
var _storage_status := "Сохранений ещё нет"
var _save_path: String = WorldSave.SAVE_PATH
var _water_material: ShaderMaterial
var _center := Vector2.ZERO
var _camera: Camera3D
var _terrain_holder: Node3D
var _ground_material: ShaderMaterial
var _debug_ground_material: StandardMaterial3D
var _active: Dictionary = {}
var _pending: Array[Vector2i] = []
var _chunk_jobs := {}
var _chunk_generation := 0
var _wanted_chunks := {}
var _rebuild_pending := {}
var _pan_delta := Vector2.ZERO
var _pan_pending := false
var _skipped_stale_jobs := 0
var _mesh_build_budget_us := MESH_BUDGET_US
var _render_cache := ChunkRenderCache.new()
var _render_world_revision := -1
var _render_water_revision := -1
var _render_surface_revision := -1
var _frame_samples: Array[float] = []
var _terrain_dirty := {}
var _last_chunk_build_us := 0
var _last_ground_build_us := 0
var _last_water_build_us := 0
var _total_ground_build_us := 0
var _total_ground_prepare_us := 0
var _total_ground_upload_us := 0
var _total_water_build_us := 0
var _chunk_rebuilds := 0
var _visibility_refreshes := 0
var _visibility_fast_rejects := 0
var _visibility_precise_checks := 0
var _last_visibility_us := 0
var _chunk_center := Vector2i(-1, -1)
var _visibility_center := Vector2(-1000000.0, -1000000.0)
var _chunk_height_bounds := {}
var _chunk_height_order: Array[Vector2i] = []
var _height_bounds_revision := -1
var _water_bounds_revision := -1
var _status: Label
var _summary: Label
var _debug_details: VBoxContainer
var _details_toggle: Button
var _hud_timer := 0.0
var _benchmark_running := false
var _benchmark_status := ""


func _ready() -> void:
	_world_model = WorldMap.new(WorldConfig.new())
	# Изменения из фоновой симуляции приходят в главный поток.
	_world_model.vertices_changed.connect(_on_world_changed, CONNECT_DEFERRED)
	_hydro = Hydrology.new(_world_model)
	_hydro.rebuild()
	_surface = Surface.new(_world_model, _hydro)
	_surface.rebuild()
	_climate = Climate.new(_world_model, _hydro)
	_climate.rebuild()
	_landscape_events = LandscapeEvents.new(_world_model)
	_natural_processes = NaturalProcesses.new(
		_world_model, _hydro, _surface, _climate)
	_natural_disasters = NaturalDisasters.new(
		_world_model, _hydro, _surface, _climate)
	_weather_events = WeatherEvents.new(
		_world_model, _climate, _surface, _hydro)
	_climate.set_day(1)
	_surface.advance_climate_day(_climate)
	_hydro.apply_rainfall_map(_surface.runoff_map())
	_nature = Nature.new(_world_model, _hydro, _surface, _climate)
	_nature.generate()
	_bind_nature_events()
	_ensure_day_runner()
	_last_completed_day = _climate.day
	_last_synchronized_world_revision = _world_model.revision
	_center = Vector2(_world_model.config.width, _world_model.config.height) * 0.5
	_setup_environment()
	_setup_materials()
	_terrain_holder = Node3D.new()
	_terrain_holder.name = "Чанки"
	add_child(_terrain_holder)
	_camera = Camera3D.new()
	_camera.name = "Изометрическая камера"
	_camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	_camera.size = 66.0
	_camera.current = true
	add_child(_camera)
	_update_material_detail()
	_update_camera()
	_setup_interface()
	_refresh_visible(true)
	get_viewport().size_changed.connect(_on_viewport_resized)


func _on_viewport_resized() -> void:
	# При смене ориентации экрана пересчитываем зону видимости.
	_refresh_visible(false)


func _setup_environment() -> void:
	# Короткая вспышка показывается только на месте физического удара.
	_lightning_light = OmniLight3D.new()
	_lightning_light.name = "Вспышка молнии"
	_lightning_light.omni_range = 42.0
	_lightning_light.light_energy = 5.0
	_lightning_light.visible = false
	add_child(_lightning_light)
	var world_light := DirectionalLight3D.new()
	world_light.rotation_degrees = Vector3(-54, -36, 0)
	world_light.light_color = Color(1.0, 0.94, 0.84)
	world_light.light_energy = 1.25
	world_light.shadow_enabled = false
	add_child(world_light)
	var sky := WorldEnvironment.new()
	var options := Environment.new()
	options.background_mode = Environment.BG_COLOR
	options.background_color = Color(0.54, 0.65, 0.69)
	options.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	options.ambient_light_color = Color(0.74, 0.81, 0.85)
	options.ambient_light_energy = 0.61
	sky.environment = options
	add_child(sky)


func _setup_materials() -> void:
	# Фактура создаётся на GPU; физическое содержание вершин
	# и диагностические палитры остаются без изменений.
	_ground_material = ShaderMaterial.new()
	_ground_material.shader = NaturalGroundShader
	_ground_material.set_shader_parameter("terrain_albedo", TerrainAlbedo)
	_ground_material.set_shader_parameter("terrain_normal_roughness",
		TerrainNormalRoughness)
	_ground_material.set_shader_parameter("macro_strength", 1.0)
	_debug_ground_material = StandardMaterial3D.new()
	_debug_ground_material.vertex_color_use_as_albedo = true
	_debug_ground_material.roughness = 1.0
	_debug_ground_material.cull_mode = BaseMaterial3D.CULL_DISABLED
	_water_material = ShaderMaterial.new()
	_water_material.shader = NaturalWaterShader

func _setup_interface() -> void:
	var canvas_layer := CanvasLayer.new()
	add_child(canvas_layer)
	var panel := PanelContainer.new()
	panel.position = Vector2(14, 14)
	panel.custom_minimum_size = Vector2(355, 0)
	canvas_layer.add_child(panel)
	var column := VBoxContainer.new()
	panel.add_child(column)
	_summary = Label.new()
	column.add_child(_summary)
	var day_button := Button.new()
	day_button.text = "Следующий день"
	day_button.pressed.connect(func(): _queue_days(1))
	column.add_child(day_button)
	var season_button := Button.new()
	season_button.text = "Вперёд на сезон (+24 дня)"
	season_button.pressed.connect(func(): _queue_days(Climate.SEASON_DAYS))
	column.add_child(season_button)
	var save_button := Button.new()
	save_button.text = "Сохранить мир"
	save_button.pressed.connect(_request_storage.bind("save"))
	column.add_child(save_button)
	var load_button := Button.new()
	load_button.text = "Загрузить мир"
	load_button.pressed.connect(_request_storage.bind("load"))
	column.add_child(load_button)
	var view_button := Button.new()
	view_button.text = "Переключить слой карты"
	view_button.pressed.connect(_cycle_view)
	column.add_child(view_button)
	_details_toggle = Button.new()
	_details_toggle.text = "Показать диагностику"
	_details_toggle.pressed.connect(_toggle_debug)
	column.add_child(_details_toggle)
	_debug_details = VBoxContainer.new()
	_debug_details.visible = false
	column.add_child(_debug_details)
	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(360, 275)
	_debug_details.add_child(scroll)
	_status = Label.new()
	_status.custom_minimum_size = Vector2(345, 0)
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	scroll.add_child(_status)
	var benchmark_button := Button.new()
	benchmark_button.text = "Измерить производительность камеры (8.8)"
	benchmark_button.pressed.connect(_run_device_benchmark)
	_debug_details.add_child(benchmark_button)
	var felling_button := Button.new()
	felling_button.text = "Ударить по ближайшему дереву"
	felling_button.pressed.connect(_debug_fell_nearest_tree)
	_debug_details.add_child(felling_button)
	for kind in ["поднятие", "просадка", "эрозия", "оползень"]:
		var event_button := Button.new()
		event_button.text = "Изменить рельеф: " + kind
		event_button.pressed.connect(_apply_landscape_event.bind(kind))
		_debug_details.add_child(event_button)
	_update_hud()


func _toggle_debug() -> void:
	_debug_details.visible = not _debug_details.visible
	_details_toggle.text = "Скрыть диагностику" if _debug_details.visible \
		else "Показать диагностику"
	_update_hud()


func _update_camera() -> void:
	var offset := Vector3(45.0, 63.0, 45.0)
	_camera.position = Vector3(_center.x, 0.0, _center.y) + offset
	_camera.look_at(Vector3(_center.x, 0.0, _center.y), Vector3.UP)


func _process(delta: float) -> void:
	_record_frame(delta)
	if _lightning_life > 0.0:
		_lightning_life -= delta
		if _lightning_life <= 0.0:
			_lightning_light.visible = false
	var movement := Vector2.ZERO
	if Input.is_key_pressed(KEY_A) or Input.is_key_pressed(KEY_LEFT):
		movement.x -= 1.0
	if Input.is_key_pressed(KEY_D) or Input.is_key_pressed(KEY_RIGHT):
		movement.x += 1.0
	if Input.is_key_pressed(KEY_W) or Input.is_key_pressed(KEY_UP):
		movement.y -= 1.0
	if Input.is_key_pressed(KEY_S) or Input.is_key_pressed(KEY_DOWN):
		movement.y += 1.0
	if not _benchmark_running and movement.length_squared() > 0.0:
		_move_center(movement.normalized() * CAMERA_SPEED * delta * _camera.size / 66.0)
	# Год может считаться несколько секунд, но камера и UI работают.
	# WorkerThreadPool трогает только RefCounted-модели, не сцену.
	# Сначала забираем готовую CPU-геометрию на главном потоке.
	# Работающие воркеры не могут пересекаться с изменением физики дня.
	_last_chunk_build_us = 0
	_last_ground_build_us = 0
	_last_water_build_us = 0
	if _day_task_id < 0:
		_collect_chunk_jobs()
	if _day_task_id >= 0:
		if WorkerThreadPool.is_task_completed(_day_task_id):
			WorkerThreadPool.wait_for_task_completion(_day_task_id)
			_day_task_id = -1
			_complete_day(_day_runner.last_result)
			_days_pending -= 1
			if _days_pending == 0 and _storage_request != "load":
				_refresh_visible(true)
				_visual_refreshes += 1
	elif _days_pending > 0 and _chunk_jobs.is_empty():
		if is_inside_tree():
			_ensure_day_runner()
			_day_task_id = WorkerThreadPool.add_task(
				_day_runner.run_day, false, "Суточная физика карты")
		else:
			# В автономных smoke-тестах нет игрового дерева сцены.
			_simulate_one_day()
			_days_pending -= 1
			if _days_pending == 0:
				_refresh_visible(true)
				_visual_refreshes += 1
	# Загрузка отменяет очередь сезонов только после завершения
	# текущего рабочего дня. Сохранение ждёт конец всей перемотки.
	if (_day_task_id < 0 and _chunk_jobs.is_empty() and
			not _storage_request.is_empty()):
		if _storage_request == "load":
			_days_pending = 0
			_perform_storage("load")
		elif _days_pending == 0:
			_perform_storage("save")
	if (_day_task_id < 0 and _chunk_jobs.is_empty() and
			not _terrain_dirty.is_empty()):
		_flush_world_changes()
	if _day_task_id < 0 and _days_pending == 0:
		_flush_nature_visuals()
		_sync_nature_colliders()
	# Обновление мешей откладывается до конца перемотки,
	# поэтому очередь GPU не тормозит каждый из 24 физических дней.
	if _days_pending == 0 and _day_task_id < 0:
		_mesh_build_budget_us = ChunkBuildQueue.budget_us(
			_frame_percentile(_frame_samples, 0.95), _pan_pending, MESH_BUDGET_US)
		if is_inside_tree():
			_start_chunk_jobs()
		else:
			_build_chunks_synchronously()
	_pan_pending = false
	_hud_timer += delta
	if _hud_timer > 0.3:
		_update_hud()
		_hud_timer = 0.0


func _input(event: InputEvent) -> void:
	if _benchmark_running:
		return
	if event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP:
			_change_zoom(0.88)
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_change_zoom(1.12)
	elif event is InputEventScreenDrag:
		var scale_factor := _camera.size / 720.0
		_move_center(Vector2(-event.relative.x, -event.relative.y) * scale_factor)
	elif event is InputEventMouseMotion and event.button_mask & MOUSE_BUTTON_MASK_MIDDLE:
		var scale_factor := _camera.size / 720.0
		_move_center(Vector2(-event.relative.x, -event.relative.y) * scale_factor)


func _record_frame(delta: float) -> void:
	if delta <= 0.0 or delta > 0.5:
		return
	_frame_samples.append(delta * 1000.0)
	if _frame_samples.size() > FRAME_SAMPLE_LIMIT:
		_frame_samples.pop_front()


static func _frame_percentile(samples: Array[float], fraction: float) -> float:
	if samples.is_empty():
		return 0.0
	var ordered: Array[float] = samples.duplicate()
	ordered.sort()
	var index := clampi(ceili(float(ordered.size()) * fraction) - 1,
		0, ordered.size() - 1)
	return ordered[index]


static func _detail_for_zoom(size: float) -> float:
	# Мелкие GPU-эффекты постепенно исчезают при отдалении камеры.
	return 1.0 - smoothstep(44.0, 96.0, size)


static func _radius_for_zoom(size: float, aspect: float, chunk_size: int) -> int:
	# Консервативная проекция прямоугольника ортокамеры на X/Z
	# при её диагональном направлении и наклоне около 45 градусов.
	var half_span := size * (0.354 * maxf(aspect, 0.5) + 0.502)
	return clampi(ceili(half_span / float(maxi(chunk_size, 1))) + 1, 2, 32)


func _visible_radius() -> int:
	if _camera == null:
		return VIEW_RADIUS
	var aspect := 16.0 / 9.0
	# В автономных тестах камера может ещё не быть в дереве сцены.
	if _camera.is_inside_tree():
		var dimensions: Vector2 = _camera.get_viewport().get_visible_rect().size
		if dimensions.y > 0.0:
			aspect = dimensions.x / dimensions.y
	return _radius_for_zoom(_camera.size, aspect, _world_model.config.chunk_size)


func _update_material_detail() -> void:
	if _camera == null:
		return
	var detail := _detail_for_zoom(_camera.size)
	if _ground_material != null:
		_ground_material.set_shader_parameter("detail_strength", detail)
		# Дальние планы обходятся без дополнительного шума и изгиба UV.
		_ground_material.set_shader_parameter("macro_strength", detail)
	if _water_material != null:
		_water_material.set_shader_parameter("ripple_strength", detail)


func _change_zoom(multiplier: float) -> void:
	var previous_lod := _detail_for_zoom(_camera.size) < 0.28
	_camera.size = clampf(_camera.size * multiplier, MIN_ZOOM, MAX_ZOOM)
	var next_lod := _detail_for_zoom(_camera.size) < 0.28
	_pan_delta = Vector2.ZERO
	_pan_pending = true
	_update_material_detail()
	# Пересобираем видимые модели только при смене уровня детализации.
	_refresh_visible(previous_lod != next_lod)


func _move_center(amount: Vector2) -> void:
	var previous := _center
	_center = Vector2(
		clampf(_center.x + amount.x, 0.0, float(_world_model.config.width) - 0.001),
		clampf(_center.y + amount.y, 0.0, float(_world_model.config.height) - 0.001))
	var displacement := _center - previous
	if displacement.length_squared() > 0.001:
		_pan_delta = displacement
		_pan_pending = true
	_update_camera()
	var next_chunk := Vector2i(floori(_center.x / float(_world_model.config.chunk_size)),
		floori(_center.y / float(_world_model.config.chunk_size)))
	# При точном отсечении новая область может появиться внутри чанка.
	# Подпуск в расчёте видимости страхует промежутки между обновлениями.
	if next_chunk != _chunk_center or \
			_center.distance_squared_to(_visibility_center) >= 1.0:
		_refresh_visible(false)


func _ensure_chunk_bounds_fresh() -> void:
	var water_revision: int = _hydro.revision if _hydro != null else -1
	if _height_bounds_revision == _world_model.revision \
			and _water_bounds_revision == water_revision:
		return
	_chunk_height_bounds.clear()
	_chunk_height_order.clear()
	_height_bounds_revision = _world_model.revision
	_water_bounds_revision = water_revision


func _chunk_elevation_bounds(coord: Vector2i) -> Vector2:
	if _chunk_height_bounds.has(coord):
		return _chunk_height_bounds[coord]
	var bounds: Rect2i = _world_model.config.chunk_rect(coord)
	var minimum := INF
	var maximum := -INF
	for y in range(bounds.position.y, bounds.end.y + 1):
		for x in range(bounds.position.x, bounds.end.x + 1):
			var height: float = _world_model.vertex_at(Vector2i(x, y))
			minimum = minf(minimum, height)
			maximum = maxf(maximum, height)

	if _hydro != null:
		# Русло может перейти в соседнюю клетку, а озеро быть выше дна.
		# Проверяем и пограничный ряд, чтобы не срезать поверхность воды.
		for y in range(maxi(0, bounds.position.y - 1),
				mini(_world_model.config.height, bounds.end.y + 1)):
			for x in range(maxi(0, bounds.position.x - 1),
					mini(_world_model.config.width, bounds.end.x + 1)):
				var index: int = _hydro.cell_index(Vector2i(x, y))
				if _hydro.has_water(index):
					var level: float = _hydro.level_at(index)
					if is_finite(level):
						minimum = minf(minimum, level)
						maximum = maxf(maximum, level)
	var scene_scale: float = _world_model.config.height_scale
	var elevation := Vector2(minimum * scene_scale - 0.25,
		maximum * scene_scale + 0.25)
	_remember_height_bounds(coord, elevation)
	return elevation


func _remember_height_bounds(coord: Vector2i, elevation: Vector2) -> void:
	_chunk_height_bounds[coord] = elevation
	_chunk_height_order.append(coord)
	if _chunk_height_order.size() > HEIGHT_BOUNDS_CACHE_LIMIT:
		_chunk_height_bounds.erase(_chunk_height_order.pop_front())


func _synchronize_render_cache(force: bool) -> void:
	if _hydro == null or _surface == null:
		if force:
			_render_cache.clear()
		return
	if force:
		_render_cache.clear()
	elif _day_task_id >= 0:
		# Физическая модель сейчас принадлежит фоновому потоку.
		return
	elif _render_world_revision != _world_model.revision \
			or _render_water_revision != _hydro.revision \
			or _render_surface_revision != _surface.revision:
		_render_cache.clear()
	if _day_task_id < 0 and _surface != null and _hydro != null:
		_render_world_revision = _world_model.revision
		_render_water_revision = _hydro.revision
		_render_surface_revision = _surface.revision


func _refresh_visible(force: bool) -> void:
	var refresh_started := Time.get_ticks_usec()
	if force:
		_chunk_generation += 1
	_synchronize_render_cache(force)
	var center_chunk := Vector2i(floori(_center.x / float(_world_model.config.chunk_size)),
		floori(_center.y / float(_world_model.config.chunk_size)))
	_chunk_center = center_chunk
	_visibility_center = _center
	# Во время фоновой физики высоты читать нельзя: временно используем
	# консервативный квадрат и уточняем его после синхронизации.
	var cull := _camera != null and _camera.is_inside_tree() \
		and _day_task_id < 0
	var radius := _visible_radius()
	if cull:
		_ensure_chunk_bounds_fresh()
		# Кандидаты покрывают и вершины у предельной высоты физической карты.
		radius += ceili(2.0 * WorldMap.MAX_HEIGHT * \
			_world_model.config.height_scale / float(_world_model.config.chunk_size)) + 2
	var aspect := 16.0 / 9.0
	var camera_position := Vector3.ZERO
	var right := Vector3.RIGHT
	var up := Vector3.UP
	if cull:
		var viewport_size: Vector2 = _camera.get_viewport().get_visible_rect().size
		if viewport_size.y > 0.0:
			aspect = viewport_size.x / viewport_size.y
		camera_position = _camera.global_position
		right = _camera.global_transform.basis.x
		up = _camera.global_transform.basis.y
	var chunk_count: Vector2i = _world_model.config.chunk_count()
	var desired := {}
	for cy in range(maxi(0, center_chunk.y - radius),
			mini(chunk_count.y, center_chunk.y + radius + 1)):
		for cx in range(maxi(0, center_chunk.x - radius),
				mini(chunk_count.x, center_chunk.x + radius + 1)):
			var coord := Vector2i(cx, cy)
			var bounds: Rect2i = _world_model.config.chunk_rect(coord)
			if not bounds.has_area():
				continue
			if cull:
				if not ChunkVisibility.horizontal_intersects(bounds,
						camera_position, right, _camera.size, aspect):
					_visibility_fast_rejects += 1
					continue
				_visibility_precise_checks += 1
				if not ChunkVisibility.intersects(bounds,
						_chunk_elevation_bounds(coord), camera_position, right,
						up, _camera.size, aspect):
					continue
			desired[coord] = true
	_wanted_chunks = desired
	if force:
		# Старые меши могут оставаться видимыми до замены.
		for coord in _active.keys():
			_rebuild_pending[coord] = true
	# Нельзя переносить в кеш меш с устаревшей физикой.
	for coord in _active.keys():
		if desired.has(coord):
			continue
		var node: Node3D = _active[coord]
		_active.erase(coord)
		if _rebuild_pending.has(coord):
			_rebuild_pending.erase(coord)
			node.queue_free()
		elif _terrain_holder != null and node.get_parent() == _terrain_holder:
			# В кеше остаётся только итоговое состояние, без анимации.
			for child in node.get_children():
				if child.name in ["Падение дерева", "Щепки дерева", NatureCollision.COLLISION_NAME]:
					node.remove_child(child)
					child.queue_free()
			_render_cache.put(coord, node)
		else:
			node.queue_free()
	for coord in _rebuild_pending.keys():
		if not desired.has(coord):
			_rebuild_pending.erase(coord)
	if not force:
		for coord in desired.keys():
			if _active.has(coord) or _chunk_jobs.has(coord):
				continue
			var restored: Node3D = _render_cache.take(coord)
			if restored != null:
				_active[coord] = restored
	var scheduled := {}
	for coord in _pending:
		if desired.has(coord) and not _chunk_jobs.has(coord) and (
				not _active.has(coord) or _rebuild_pending.has(coord)):
			scheduled[coord] = true
	for coord in desired.keys():
		if not _chunk_jobs.has(coord) and (
				not _active.has(coord) or _rebuild_pending.has(coord)):
			scheduled[coord] = true
	_pending.clear()
	for coord in scheduled.keys():
		_pending.append(coord)
	ChunkBuildQueue.prioritize(_pending, _center, _pan_delta,
		_world_model.config.chunk_size, _active)
	_last_visibility_us = Time.get_ticks_usec() - refresh_started
	_visibility_refreshes += 1


func _build_chunks_synchronously() -> void:
	# Автономный детерминированный путь тестов без SceneTree.
	# Игровой рендер всегда отправляет CPU-подготовку в воркеры.
	var started := Time.get_ticks_usec()
	var built := 0
	while built < MAX_BUILDS_PER_FRAME and not _pending.is_empty():
		var coord: Vector2i = _pending.pop_front()
		if not _wanted_chunks.has(coord) or (
				_active.has(coord) and not _rebuild_pending.has(coord)):
			_skipped_stale_jobs += 1
			continue
		_create_chunk(coord)
		built += 1
		if Time.get_ticks_usec() - started >= _mesh_build_budget_us:
			break
	_last_chunk_build_us += Time.get_ticks_usec() - started


func _start_chunk_jobs() -> void:
	if _pending.is_empty() or _chunk_jobs.size() >= MAX_CONCURRENT_CHUNK_JOBS:
		return
	# Ленивая подготовка физических моделей допускается только в main.
	if _view_mode == 0:
		_hydro.ensure_ready()
		_surface.ensure_ready()
	while (_chunk_jobs.size() < MAX_CONCURRENT_CHUNK_JOBS and
			not _pending.is_empty()):
		var coord: Vector2i = _pending.pop_front()
		if not _wanted_chunks.has(coord) or (
				_active.has(coord) and not _rebuild_pending.has(coord)):
			_skipped_stale_jobs += 1
			continue
		var worker := ChunkBuildWorker.new(coord, _view_mode, _world_model,
			_surface, _climate, _hydro)
		var task: int = WorkerThreadPool.add_task(worker.run, false,
			"Подготовка поверхности чанка")
		_chunk_jobs[coord] = {
			"task": task, "worker": worker, "generation": _chunk_generation,
			"world": _world_model.revision, "surface": _surface.revision,
			"hydro": _hydro.revision, "mode": _view_mode
		}


func _collect_chunk_jobs() -> void:
	var started := Time.get_ticks_usec()
	var completed := 0
	for coord in _chunk_jobs.keys():
		var item: Dictionary = _chunk_jobs[coord]
		var task: int = item["task"]
		if not WorkerThreadPool.is_task_completed(task):
			continue
		# Очередь записи потока синхронизирована через wait_for_task.
		WorkerThreadPool.wait_for_task_completion(task)
		_chunk_jobs.erase(coord)
		var valid: bool = (
			item["generation"] == _chunk_generation and
			item["world"] == _world_model.revision and
			item["surface"] == _surface.revision and
			item["hydro"] == _hydro.revision and
			item["mode"] == _view_mode and _wanted_chunks.has(coord)
		)
		if not valid:
			_skipped_stale_jobs += 1
			if _wanted_chunks.has(coord) and not _pending.has(coord):
				_pending.append(coord)
			continue
		var worker: RefCounted = item["worker"]
		var upload_started := Time.get_ticks_usec()
		var ground_mesh: ArrayMesh = Chunk.mesh_from_arrays(worker.arrays)
		var upload_us := Time.get_ticks_usec() - upload_started
		_last_ground_build_us += worker.prepare_us + upload_us
		_total_ground_build_us += worker.prepare_us + upload_us
		_total_ground_prepare_us += worker.prepare_us
		_total_ground_upload_us += upload_us
		_attach_chunk(coord, ground_mesh)
		completed += 1
		if (completed >= MAX_BUILDS_PER_FRAME or
				Time.get_ticks_usec() - started >= _mesh_build_budget_us):
			break
	_last_chunk_build_us += Time.get_ticks_usec() - started


func _wait_chunk_jobs() -> void:
	# Только при остановке сцены, загрузке сохранения или редком
	# ручном изменении рельефа. Никакого ожидания в обычном кадре.
	for item in _chunk_jobs.values():
		WorkerThreadPool.wait_for_task_completion(int(item["task"]))
	_chunk_jobs.clear()


func _create_chunk(coord: Vector2i) -> void:
	# Синхронный путь сохраняем для тестов и изолированных вызовов.
	var started := Time.get_ticks_usec()
	var arrays: Array = Chunk.prepare_arrays(coord.x, coord.y, 1,
		_world_model, _surface, _view_mode, _climate, _hydro)
	var prepared_us := Time.get_ticks_usec() - started
	started = Time.get_ticks_usec()
	var mesh := Chunk.mesh_from_arrays(arrays)
	var upload_us := Time.get_ticks_usec() - started
	_last_ground_build_us += prepared_us + upload_us
	_total_ground_build_us += prepared_us + upload_us
	_total_ground_prepare_us += prepared_us
	_total_ground_upload_us += upload_us
	_attach_chunk(coord, mesh)


func _attach_chunk(coord: Vector2i, ground_mesh: ArrayMesh) -> void:
	# Ни один воркер не трогает Node, ArrayMesh или RenderingServer.
	var old_node: Node3D = _active.get(coord)
	var node := Node3D.new()
	node.name = "Чанк_%d_%d" % [coord.x, coord.y]
	var ground := MeshInstance3D.new()
	ground.mesh = ground_mesh
	if _view_mode == 0:
		ground.material_override = _ground_material
	else:
		ground.material_override = _debug_ground_material
	ground.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	node.add_child(ground)
	var water_started := Time.get_ticks_usec()
	var water_mesh: ArrayMesh = WaterMesh.create_mesh(
		_world_model, _hydro, coord, _surface)
	var water_us := Time.get_ticks_usec() - water_started
	_last_water_build_us += water_us
	_total_water_build_us += water_us
	if water_mesh.get_surface_count() > 0:
		var water_node := MeshInstance3D.new()
		water_node.name = "Поверхностная вода"
		water_node.mesh = water_mesh
		water_node.material_override = _water_material
		water_node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		node.add_child(water_node)
	if _view_mode == 0 and _nature != null:
		node.add_child(NatureRenderer.create_chunk(_world_model, _nature, coord,
			_detail_for_zoom(_camera.size)))
	_terrain_holder.add_child(node)
	if old_node != null:
		old_node.queue_free()
	_active[coord] = node
	_rebuild_pending.erase(coord)
	_chunk_rebuilds += 1

func _bind_nature_events() -> void:
	if _nature == null:
		return
	if not _nature.objects_changed.is_connected(_on_nature_changed):
		_nature.objects_changed.connect(_on_nature_changed, CONNECT_DEFERRED)
	if not _nature.tree_felled.is_connected(_on_tree_felled):
		_nature.tree_felled.connect(_on_tree_felled, CONNECT_DEFERRED)
	if not _nature.tree_struck.is_connected(_on_tree_struck):
		_nature.tree_struck.connect(_on_tree_struck, CONNECT_DEFERRED)


func _on_nature_changed(chunks: Array[Vector2i], _revision: int) -> void:
	for chunk in chunks:
		_nature_dirty[chunk] = true


func _refresh_nature_chunk(chunk: Vector2i) -> void:
	_render_cache.discard(chunk)
	if _view_mode != 0 or not _active.has(chunk):
		return
	var chunk_root: Node3D = _active[chunk]
	var previous: Node = chunk_root.get_node_or_null("Природные объекты")
	if previous != null:
		chunk_root.remove_child(previous)
		previous.queue_free()
	chunk_root.add_child(NatureRenderer.create_chunk(_world_model, _nature, chunk,
		_detail_for_zoom(_camera.size)))
	var old_collisions: Node = chunk_root.get_node_or_null(
		NatureCollision.COLLISION_NAME)
	if old_collisions != null:
		chunk_root.remove_child(old_collisions)
		old_collisions.queue_free()
	if NatureCollision.near_camera(chunk, _chunk_center):
		chunk_root.add_child(NatureCollision.create_chunk(
			_world_model, _nature, chunk))


func _sync_nature_colliders() -> void:
	# В физическом сервере держим только препятствия возле камеры.
	if _nature == null or _day_task_id >= 0 or _days_pending > 0:
		return
	var created := 0
	for chunk in _active.keys():
		var chunk_root: Node3D = _active[chunk]
		var current: Node = chunk_root.get_node_or_null(
			NatureCollision.COLLISION_NAME)
		var required: bool = _view_mode == 0 and \
			NatureCollision.near_camera(chunk, _chunk_center)
		if not required:
			if current != null:
				chunk_root.remove_child(current)
				current.queue_free()
			continue
		if current != null or created >= NatureCollision.MAX_NEW_CHUNKS_PER_FRAME:
			continue
		chunk_root.add_child(NatureCollision.create_chunk(
			_world_model, _nature, chunk))
		created += 1


func _flush_nature_visuals() -> void:
	# В кадре обновляем только изменённые чанки, без перестройки грунта.
	if _day_task_id >= 0 or _nature_dirty.is_empty():
		return
	var processed := 0
	for chunk in _nature_dirty.keys():
		_refresh_nature_chunk(chunk)
		_nature_dirty.erase(chunk)
		processed += 1
		if processed >= MAX_NATURE_REFRESHES_PER_FRAME:
			break


func _show_hit_effect(previous: Dictionary, chunk: Vector2i) -> void:
	if _view_mode != 0 or not _active.has(chunk):
		return
	var visual: Node3D = NatureFelling.make_hit_visual(
		_world_model, previous)
	if visual == null:
		return
	_active[chunk].add_child(visual)
	NatureFelling.animate_hit(visual)


func _on_tree_struck(previous: Dictionary, _progress: int) -> void:
	if _day_task_id >= 0 or _nature == null:
		return
	var cell := Vector2i(int(previous["x"]), int(previous["y"]))
	var chunk: Vector2i = _world_model.config.chunk_of(cell)
	_nature_dirty.erase(chunk)
	_refresh_nature_chunk(chunk)
	_show_hit_effect(previous, chunk)


func _on_tree_felled(previous: Dictionary) -> void:
	# Для невидимых объектов анимация не создаётся.
	if _day_task_id >= 0 or _nature == null:
		return
	var cell := Vector2i(int(previous["x"]), int(previous["y"]))
	var chunk: Vector2i = _world_model.config.chunk_of(cell)
	_nature_dirty.erase(chunk)
	_refresh_nature_chunk(chunk)
	_show_hit_effect(previous, chunk)
	if _view_mode != 0 or not _active.has(chunk):
		return
	var visual: Node3D = NatureFelling.make_visual(
		_world_model, previous, _detail_for_zoom(_camera.size))
	if visual == null:
		return
	var chunk_root: Node3D = _active[chunk]
	chunk_root.add_child(visual)
	NatureFelling.animate(visual)


func _debug_fell_nearest_tree() -> void:
	# Ручная демонстрация без лесорубов, строительства и экономики.
	if _nature == null or _benchmark_running or _day_task_id >= 0 \
			or _days_pending > 0 or _view_mode != 0:
		_storage_status = "Рубка доступна в природном виде после расчёта дня"
		return
	var chosen := -1
	var distance := INF
	for chunk in _active.keys():
		for item in _nature.objects_in_chunk(chunk):
			if item["kind"] != "дерево" or item["state"] not in [
					"целое", "сухостой"]:
				continue
			var object_position := Vector2(float(item["x"]) + 0.5,
				float(item["y"]) + 0.5)
			var length: float = object_position.distance_squared_to(_center)
			if length < distance:
				chosen = int(item["id"])
				distance = length
	if chosen < 0:
		_storage_status = "В загруженных чанках нет доступных деревьев"
		return
	var result: Dictionary = _nature.hit_tree(chosen, 250)
	if result.is_empty():
		_storage_status = "Удар не выполнен"
		return
	if bool(result["felled"]):
		_storage_status = "Повалено дерево %d · древесина %d ед." % [
			chosen, int(result["wood_units"])]
	else:
		_storage_status = "Дерево %d · зарубка %d из %d" % [
			chosen, int(result["cut_progress"]), Nature.CUT_THRESHOLD]
	_update_hud()


func _on_world_changed(chunks: Array[Vector2i], revision: int) -> void:
	# Событие, уже согласованное фоновым расчётом, не запускаем снова.
	if revision <= _last_synchronized_world_revision:
		return
	for chunk in chunks:
		_terrain_dirty[chunk] = true


func _ensure_day_runner() -> void:
	if _day_runner != null:
		return
	_day_runner = WorldDayRunner.new(_world_model, _hydro, _surface,
		_climate, _weather_events, _natural_processes, _natural_disasters,
		_nature)


func _flush_world_changes() -> void:
	if _day_task_id >= 0:
		return
	_ensure_day_runner()
	var changed: bool = _day_runner.synchronize_world()
	_terrain_dirty.clear()
	_last_synchronized_world_revision = _world_model.revision
	if changed and _days_pending == 0:
		_refresh_visible(true)


func _storage_models() -> Dictionary:
	return {
		"world": _world_model, "hydro": _hydro,
		"surface": _surface, "climate": _climate,
		"weather": _weather_events, "natural": _natural_processes,
		"disasters": _natural_disasters, "nature": _nature
	}


func _request_storage(action: String) -> void:
	if _benchmark_running or action not in ["save", "load"]:
		return
	# Для ручной загрузки гарантируем отсутствие ссылок воркера на
	# заменяемую физическую модель. Выполняется только по запросу.
	if action == "load" and _day_task_id < 0:
		_wait_chunk_jobs()
	if (_day_task_id >= 0 or _days_pending > 0 or
			not _chunk_jobs.is_empty()):
		_storage_request = action
		_storage_status = "Сохранение ожидает конец перемотки" if action == "save" \
			else "Загрузка ожидает завершения текущего дня"
		return
	_perform_storage(action)


func _perform_storage(action: String) -> void:
	if _day_task_id >= 0 or not _chunk_jobs.is_empty():
		return
	_storage_request = ""
	if action == "save":
		_flush_world_changes()
		if WorldSave.write_file(_storage_models(), _save_path):
			_storage_status = "Мир сохранён · день %d" % _climate.day
		else:
			_storage_status = "Ошибка записи мира; предыдущее сохранение не затронуто"
	elif action == "load":
		var models: Dictionary = WorldSave.read_file(_save_path)
		if models.is_empty():
			_storage_status = "Нет корректного сохранения или повреждён файл"
		else:
			_install_loaded_world(models)
			_storage_status = "Мир восстановлен · день %d" % _climate.day
	_update_hud()


func _install_loaded_world(models: Dictionary) -> void:
	# Применяем новые модели только после проверки каждого слоя.
	if _world_model.vertices_changed.is_connected(_on_world_changed):
		_world_model.vertices_changed.disconnect(_on_world_changed)
	_world_model = models["world"]
	_world_model.vertices_changed.connect(_on_world_changed, CONNECT_DEFERRED)
	_hydro = models["hydro"]
	_surface = models["surface"]
	_climate = models["climate"]
	_weather_events = models["weather"]
	_natural_processes = models["natural"]
	_natural_disasters = models["disasters"]
	if _nature != null:
		if _nature.objects_changed.is_connected(_on_nature_changed):
			_nature.objects_changed.disconnect(_on_nature_changed)
		if _nature.tree_felled.is_connected(_on_tree_felled):
			_nature.tree_felled.disconnect(_on_tree_felled)
		if _nature.tree_struck.is_connected(_on_tree_struck):
			_nature.tree_struck.disconnect(_on_tree_struck)
	_nature = models["nature"]
	_bind_nature_events()
	_nature_dirty.clear()
	_landscape_events = models["landscape"]
	_day_runner = models["runner"]
	_day_task_id = -1
	_days_pending = 0
	_last_completed_day = _climate.day
	_last_synchronized_world_revision = _world_model.revision
	_terrain_dirty.clear()
	_last_day_step_us = 0
	_peak_day_step_us = 0
	_last_day_profile_us.clear()
	_last_day_statistics.clear()
	_lightning_life = 0.0
	_lightning_light.visible = false
	_weather_status = "Молний всего %d" % _weather_events.total_strikes
	_disaster_status = "Стихийных событий всего %d" % _natural_disasters.total_events
	_process_status = "Природные процессы восстановлены до дня %d" % \
		_natural_processes.last_day
	_last_event = "Мир успешно загружен"
	_center = _world_model.config.clamp_point(_center)
	_update_camera()
	for chunk in _active.keys():
		_active[chunk].queue_free()
	_active.clear()
	_pending.clear()
	_wanted_chunks.clear()
	_rebuild_pending.clear()
	_pan_delta = Vector2.ZERO
	_pan_pending = false
	_render_cache.clear()
	_render_world_revision = -1
	_render_water_revision = -1
	_render_surface_revision = -1
	_chunk_height_bounds.clear()
	_chunk_height_order.clear()
	_height_bounds_revision = -1
	_water_bounds_revision = -1
	_chunk_center = Vector2i(-1, -1)
	_refresh_visible(true)


func _exit_tree() -> void:
	# Не освобождаем карту, пока фоновый поток использует её массивы.
	_wait_chunk_jobs()
	if _day_task_id >= 0:
		WorkerThreadPool.wait_for_task_completion(_day_task_id)
		_day_task_id = -1


func _apply_landscape_event(kind: String) -> void:
	if _day_task_id >= 0 or _benchmark_running:
		return
	_wait_chunk_jobs()
	var result: Dictionary = _landscape_events.apply(kind, _center, 18.0, 3.0)
	_last_event = "%s: %d вершин" % [kind, result["vertices"]] \
		if not result.is_empty() else "%s: нет подходящего участка" % kind
	_flush_world_changes()
	_update_hud()


func _queue_days(number: int) -> void:
	if _benchmark_running:
		return
	_days_pending = mini(96, _days_pending + number)


func _simulate_one_day() -> void:
	# Прямой вызов нужен для тестов и отладки; в настоящем игровом
	# дереве тот же расчёт выполняется через WorkerThreadPool.
	_ensure_day_runner()
	_day_runner.run_day()
	_complete_day(_day_runner.last_result)


func _complete_day(result: Dictionary) -> void:
	_last_completed_day = int(result["day"])
	_last_day_step_us = _day_runner.last_duration_us
	_peak_day_step_us = maxi(_peak_day_step_us, _last_day_step_us)
	_last_day_profile_us = _day_runner.last_profile_us.duplicate()
	_last_day_statistics = _day_runner.last_statistics.duplicate()
	_last_synchronized_world_revision = _world_model.revision
	_terrain_dirty.clear()
	var strikes: Array[Dictionary] = result["strikes"]
	if not strikes.is_empty():
		var first: Dictionary = strikes[0]
		var hit: Vector2i = first["cell"]
		var point := Vector2(hit) + Vector2(0.5, 0.5)
		_lightning_light.position = _world_model.config.to_scene(point,
			_world_model.height_at(point) + 8.0)
		_lightning_light.visible = true
		_lightning_life = 0.28
		_weather_status = "Молний сегодня %d · всего %d · удар %s" % [
			strikes.size(), _weather_events.total_strikes, hit]
	var event: Dictionary = result["erosion"]
	if not event.is_empty():
		_process_status = "%s, день %d: %s" % [
			event["process"], event["day"], event["cell"]]
	var hazards: Array[Dictionary] = result["hazards"]
	if not hazards.is_empty():
		var latest: Dictionary = hazards[hazards.size() - 1]
		_disaster_status = "%s · день %d · %s · интенсивность %.0f%%" % [
			latest["kind"], latest["day"], latest["cell"],
			float(latest["severity"]) * 100.0]


func _cycle_view() -> void:
	if _benchmark_running:
		return
	_view_mode = (_view_mode + 1) % 8
	if _day_task_id < 0:
		_refresh_visible(true)
	_update_hud()


func _prepare_benchmark_start() -> void:
	# Холодное начало одинаково для CI, ПК и Android.
	_wait_chunk_jobs()
	for coord in _active.keys():
		var node: Node3D = _active[coord]
		node.visible = false
		node.queue_free()
	_active.clear()
	_pending.clear()
	_wanted_chunks.clear()
	_rebuild_pending.clear()
	_render_cache.clear()
	_chunk_height_bounds.clear()
	_chunk_height_order.clear()
	_height_bounds_revision = -1
	_water_bounds_revision = -1
	_frame_samples.clear()
	_pan_delta = Vector2.ZERO
	_pan_pending = false
	_center = Vector2(_world_model.config.width, _world_model.config.height) * 0.5
	_camera.size = BenchmarkRoute.INITIAL_ZOOM
	_update_material_detail()
	_update_camera()
	_refresh_visible(true)


func _run_device_benchmark() -> void:
	if _benchmark_running:
		return
	if _days_pending > 0 or _day_task_id >= 0 or not _storage_request.is_empty():
		_benchmark_status = "Испытание доступно после завершения расчёта дней"
		_update_hud()
		return
	_benchmark_running = true
	_benchmark_status = "Идёт маршрут из 370 кадров; управление заблокировано"
	var saved_center := _center
	var saved_zoom := _camera.size
	var report: Dictionary = await BenchmarkRunner.new().run(self)
	var path := "user://world-camera-8-8-device.json"
	var file := FileAccess.open(path, FileAccess.WRITE)
	var saved := file != null
	if saved:
		file.store_string(JSON.stringify(report, "\t") + "\n")
		file.close()
	if DisplayServer.get_name() != "headless":
		DisplayServer.clipboard_set(JSON.stringify(report))
	var summary: Dictionary = report["summary"]
	_benchmark_status = "Маршрут: p95 %.1f мс · мешей %d · попаданий %d. %s" % [
		float(summary["interval_ms_p95"]), int(summary["chunks_built"]),
		int(summary["cache_hits"]),
		"JSON скопирован и сохранён: " + path if saved
		else "JSON скопирован; сохранение файла не удалось"]
	_center = saved_center
	_camera.size = saved_zoom
	_update_material_detail()
	_update_camera()
	_refresh_visible(false)
	_benchmark_running = false
	_update_hud()


func _update_hud() -> void:
	if _summary == null:
		return
	var phase := " · расчёт в фоне" if _day_task_id >= 0 else ""
	_summary.text = "День %d · FPS %d · чанки %d/%d%s\nОчередь дней %d · пик физики %.1f мс\nВид: %s\n%s" % [
		_last_completed_day, Engine.get_frames_per_second(), _active.size(),
		_active.size() + _pending.size(), phase, _days_pending,
		float(_peak_day_step_us) / 1000.0, VIEW_NAMES[_view_mode],
		_storage_status]
	# Даже диагностическая панель не читает модель одновременно
	# с фоновым потоком, иначе возникнет гонка массивов.
	if _day_task_id >= 0 or _debug_details == null \
			or not _debug_details.visible:
		return
	var profile := Relief.profile_at(_world_model, _center)
	var water: Dictionary = _hydro.water_at(_world_model.config.cell_at(_center))
	var amounts: Dictionary = _hydro.water_count()
	var cell: Vector2i = _world_model.config.cell_at(_center)
	var ground: Dictionary = _surface.profile_at(cell)
	var weather: Dictionary = _climate.weather_at(cell)
	var biome: String = _climate.biome_at(cell, _surface)
	_status.text = "ЗЕМЛИ И ЭПОХИ · КЛИМАТ И БИОМЫ\n"
	_status.text += "Карта %d×%d · seed %d\n" % [
		_world_model.config.width, _world_model.config.height,
		_world_model.config.seed]
	_status.text += "%s · высота %.2f · уклон %.1f°\n" % [
		profile["form"], profile["height"], profile["slope_degrees"]]
	_status.text += "Водосбор %.0f · вода %.2f · осадки %.2f\n" % [
		water["catchment"], water["depth"], weather["precipitation"]]
	_status.text += "Море %d · озёра %d · реки %d · паводок %d\n" % [
		amounts["ocean"], amounts["lakes"], amounts["rivers"], amounts["flooded"]]
	var edge := Boundary.geography_at(_center.x, _center.y,
		_world_model.config.width, _world_model.config.height, _world_model.config.seed)
	_status.text += "Местность: %s · поверхность: %s\n" % [
		edge["zone"], ground["cover"]]
	_status.text += "%s · почва %.2f м · плодородие %.0f%% · влажность %.0f%%\n" % [
		ground["substrate"], ground["depth"], float(ground["fertility"]) * 100.0,
		float(ground["moisture"]) * 100.0]
	_status.text += "День %d · %s · воздух %.1f° · %s\n" % [
		_climate.day, weather["season"], weather["temperature"], weather["weather"]]
	_status.text += "Биом: %s · влажность воздуха %.0f%%\n" % [
		biome, float(weather["humidity"]) * 100.0]
	_status.text += "Гроза %.0f%% · заболоченность %.0f%% · риск пожара %.0f%%\n" % [
		float(weather["storm_intensity"]) * 100.0,
		float(ground["waterlogging"]) * 100.0,
		float(_weather_events.last_events[0]["ignition_potential"]) * 100.0
		if not _weather_events.last_events.is_empty() else 0.0]
	if _nature != null and _nature.generated:
		_status.text += "Природа: %d объектов · запас древесины %d условных ед.\n" % [
			_nature.count(), _nature.wood_total()]
	_status.text += "Снег здесь %.0f%% · покрыто снегом %.1f%% карты\n" % [
		float(ground["snow"]) * 100.0, _surface.snow_coverage * 100.0]
	_status.text += "Промерзание %.0f%% · потенциал роста %.0f%%\n" % [
		float(ground["frost"]) * 100.0,
		float(ground["growth_potential"]) * 100.0]
	_status.text += "Отложения здесь %.3f · баланс %.6f\n" % [
		float(ground["sediment"]), _surface.sediment_balance()]
	_status.text += "Ветер %.1f · изменённых вершин %d\n" % [
		float(weather["wind_speed"]), _world_model.changed_vertex_count()]
	_status.text += "%s\n" % _weather_status
	_status.text += "%s · событий всего %d\n" % [
		_disaster_status, _natural_disasters.total_events]
	_status.text += "%s\n" % _process_status
	_status.text += "%s\n" % _last_event
	_status.text += "Почва: %d клеток · климат: %d строк · гидро: %d пересчётов\n" % [
		_surface.last_rebuilt_cells, _climate.last_rebuild_rows,
		_hydro.full_rebuilds]
	_status.text += "Меши CPU: %d · кадр %.1f мс (земля %.1f, вода %.1f) · сезонов %d\n" % [
		_chunk_rebuilds, float(_last_chunk_build_us) / 1000.0,
		float(_last_ground_build_us) / 1000.0,
		float(_last_water_build_us) / 1000.0, _visual_refreshes]
	_status.text += "Очередь GPU %d · обновить %d · бюджет %d мкс · отброшено %d\n" % [
		_pending.size() + _chunk_jobs.size(), _rebuild_pending.size(),
		_mesh_build_budget_us, _skipped_stale_jobs]
	_status.text += "Видимость: %.2f мс · быстрых отсечений %d · точных проверок %d\n" % [
		float(_last_visibility_us) / 1000.0,
		_visibility_fast_rejects, _visibility_precise_checks]
	if not _benchmark_status.is_empty():
		_status.text += "Замеры: %s\n" % _benchmark_status
	_status.text += "Кеш мешей: %d/%d · оценка %.2f/%.0f МиБ · попаданий %d · вытеснений %d\n" % [
		_render_cache.count(), ChunkRenderCache.MAX_CHUNKS,
		float(_render_cache.estimated_bytes) / 1048576.0,
		float(ChunkRenderCache.MAX_ESTIMATED_BYTES) / 1048576.0,
		_render_cache.hits, _render_cache.evictions]
	_status.text += "Кеш высот %d/%d · кадр p50 %.1f мс / p95 %.1f мс\n" % [
		_chunk_height_bounds.size(), HEIGHT_BOUNDS_CACHE_LIMIT,
		_frame_percentile(_frame_samples, 0.50),
		_frame_percentile(_frame_samples, 0.95)]
	_status.text += "Статическая память Godot %.1f МиБ (не вся ОЗУ/VRAM)\n" % [
		Performance.get_monitor(Performance.MEMORY_STATIC) / 1048576.0]
	if _camera != null:
		_status.text += "Масштаб %.0f · радиус чанков %d · детали GPU %.0f%%\n" % [
			_camera.size, _visible_radius(), _detail_for_zoom(_camera.size) * 100.0]
	_status.text += "Шаг физики: последний %.1f мс · максимум %.1f мс\n" % [
		float(_last_day_step_us) / 1000.0,
		float(_peak_day_step_us) / 1000.0]
	for kind in _last_day_profile_us.keys():
		_status.text += "%s: %.1f мс\n" % [
			kind, float(_last_day_profile_us[kind]) / 1000.0]
	for kind in _last_day_statistics.keys():
		_status.text += "%s: %d\n" % [
			kind, int(_last_day_statistics[kind])]
	_status.text += "FPS %d · чанки %d/%d · осталось дней %d" % [
		Engine.get_frames_per_second(), _active.size(),
		_wanted_chunks.size(), _days_pending]
