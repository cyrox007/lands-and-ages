extends Node3D
## Показ физического рельефа GPU-чанками. Экономика и природные объекты не подключены.

const Terrain = preload("res://scripts/terrain.gd")
const WorldConfig = preload("res://scripts/world_config.gd")
const WorldMap = preload("res://scripts/world_map.gd")
const Relief = preload("res://scripts/relief.gd")
const Chunk = preload("res://scripts/chunk.gd")
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

const VIEW_RADIUS := 4
const MAX_BUILDS_PER_FRAME := 8
const MESH_BUDGET_US := 4200
const CAMERA_SPEED := 32.0
const MIN_ZOOM := 16.0
const MAX_ZOOM := 105.0

var _world_model: RefCounted
var _hydro: RefCounted
var _surface: RefCounted
var _climate: RefCounted
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
var _view_mode := 4
var _days_pending := 0
var _day_runner: RefCounted
var _day_task_id := -1
var _last_completed_day := 1
var _last_synchronized_world_revision := 0
var _last_day_step_us := 0
var _peak_day_step_us := 0
var _visual_refreshes := 0
var _last_day_profile_us: Dictionary = {}
var _water_material: StandardMaterial3D
var _center := Vector2.ZERO
var _camera: Camera3D
var _terrain_holder: Node3D
var _ground_material: StandardMaterial3D
var _active: Dictionary = {}
var _pending: Array[Vector2i] = []
var _terrain_dirty := {}
var _last_chunk_build_us := 0
var _chunk_rebuilds := 0
var _chunk_center := Vector2i(-1, -1)
var _status: Label
var _summary: Label
var _debug_details: VBoxContainer
var _details_toggle: Button
var _hud_timer := 0.0


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
	_update_camera()
	_setup_interface()
	_refresh_visible(true)


func _setup_environment() -> void:
	# Короткая вспышка показывается только на месте физического удара.
	_lightning_light = OmniLight3D.new()
	_lightning_light.name = "Вспышка молнии"
	_lightning_light.omni_range = 42.0
	_lightning_light.light_energy = 5.0
	_lightning_light.visible = false
	add_child(_lightning_light)
	var world_light := DirectionalLight3D.new()
	world_light.rotation_degrees = Vector3(-48, -40, 0)
	world_light.light_energy = 1.15
	world_light.shadow_enabled = false
	add_child(world_light)
	var sky := WorldEnvironment.new()
	var options := Environment.new()
	options.background_mode = Environment.BG_COLOR
	options.background_color = Color(0.47, 0.62, 0.72)
	options.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	options.ambient_light_color = Color(0.80, 0.85, 0.92)
	options.ambient_light_energy = 0.8
	sky.environment = options
	add_child(sky)


func _setup_materials() -> void:
	_ground_material = StandardMaterial3D.new()
	_ground_material.vertex_color_use_as_albedo = true
	_ground_material.roughness = 1.0
	_ground_material.cull_mode = BaseMaterial3D.CULL_DISABLED
	_water_material = StandardMaterial3D.new()
	_water_material.vertex_color_use_as_albedo = true
	_water_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_water_material.roughness = 0.25
	_water_material.cull_mode = BaseMaterial3D.CULL_DISABLED


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
	if movement.length_squared() > 0.0:
		_move_center(movement.normalized() * CAMERA_SPEED * delta * _camera.size / 66.0)
	# Год может считаться несколько секунд, но камера и UI работают.
	# WorkerThreadPool трогает только RefCounted-модели, не сцену.
	if _day_task_id >= 0:
		if WorkerThreadPool.is_task_completed(_day_task_id):
			WorkerThreadPool.wait_for_task_completion(_day_task_id)
			_day_task_id = -1
			_complete_day(_day_runner.last_result)
			_days_pending -= 1
			if _days_pending == 0:
				_refresh_visible(true)
				_visual_refreshes += 1
	elif _days_pending > 0:
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
	if _day_task_id < 0 and not _terrain_dirty.is_empty():
		_flush_world_changes()
	# Обновление мешей откладывается до конца перемотки,
	# поэтому очередь GPU не тормозит каждый из 24 физических дней.
	_last_chunk_build_us = 0
	if _days_pending == 0 and _day_task_id < 0:
		var frame_start := Time.get_ticks_usec()
		var built := 0
		while built < MAX_BUILDS_PER_FRAME and not _pending.is_empty():
			_create_chunk(_pending.pop_front())
			built += 1
			if Time.get_ticks_usec() - frame_start >= MESH_BUDGET_US:
				break
		_last_chunk_build_us = Time.get_ticks_usec() - frame_start
	_hud_timer += delta
	if _hud_timer > 0.3:
		_update_hud()
		_hud_timer = 0.0


func _input(event: InputEvent) -> void:
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


func _change_zoom(multiplier: float) -> void:
	_camera.size = clampf(_camera.size * multiplier, MIN_ZOOM, MAX_ZOOM)
	_refresh_visible(false)


func _move_center(amount: Vector2) -> void:
	_center = Vector2(
		clampf(_center.x + amount.x, 0.0, float(_world_model.config.width) - 0.001),
		clampf(_center.y + amount.y, 0.0, float(_world_model.config.height) - 0.001))
	_update_camera()
	var next_chunk := Vector2i(floori(_center.x / float(_world_model.config.chunk_size)),
		floori(_center.y / float(_world_model.config.chunk_size)))
	if next_chunk != _chunk_center:
		_refresh_visible(false)


func _refresh_visible(force: bool) -> void:
	var center_chunk := Vector2i(floori(_center.x / float(_world_model.config.chunk_size)),
		floori(_center.y / float(_world_model.config.chunk_size)))
	_chunk_center = center_chunk
	var desired := {}
	for cy in range(center_chunk.y - VIEW_RADIUS, center_chunk.y + VIEW_RADIUS + 1):
		for cx in range(center_chunk.x - VIEW_RADIUS, center_chunk.x + VIEW_RADIUS + 1):
			var coord := Vector2i(cx, cy)
			if _world_model.config.chunk_rect(coord).has_area():
				desired[coord] = true
	# Невидимые чанки удаляем, видимые сохраняем до готовности новой сетки.
	for coord in _active.keys():
		if not desired.has(coord):
			_active[coord].queue_free()
			_active.erase(coord)
	var scheduled := {}
	for coord in _pending:
		if desired.has(coord):
			scheduled[coord] = true
	for coord in desired.keys():
		if force or not _active.has(coord):
			scheduled[coord] = true
	_pending.clear()
	for coord in scheduled.keys():
		_pending.append(coord)
	_pending.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
		return (a - center_chunk).length_squared() < (b - center_chunk).length_squared())


func _create_chunk(coord: Vector2i) -> void:
	var old_node: Node3D = _active.get(coord)
	var node := Node3D.new()
	node.name = "Чанк_%d_%d" % [coord.x, coord.y]
	var ground := MeshInstance3D.new()
	ground.mesh = Chunk.create_mesh(coord.x, coord.y, 1, _world_model,
		_surface, _view_mode, _climate)
	ground.material_override = _ground_material
	ground.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	node.add_child(ground)
	var water_mesh: ArrayMesh = WaterMesh.create_mesh(_world_model, _hydro, coord, _surface)
	if water_mesh.get_surface_count() > 0:
		var water_node := MeshInstance3D.new()
		water_node.name = "Поверхностная вода"
		water_node.mesh = water_mesh
		water_node.material_override = _water_material
		water_node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		node.add_child(water_node)
	_terrain_holder.add_child(node)
	if old_node != null:
		old_node.queue_free()
	_active[coord] = node
	_chunk_rebuilds += 1


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
		_climate, _weather_events, _natural_processes, _natural_disasters)


func _flush_world_changes() -> void:
	if _day_task_id >= 0:
		return
	_ensure_day_runner()
	var changed: bool = _day_runner.synchronize_world()
	_terrain_dirty.clear()
	_last_synchronized_world_revision = _world_model.revision
	if changed and _days_pending == 0:
		_refresh_visible(true)


func _exit_tree() -> void:
	# Не освобождаем карту, пока фоновый поток использует её массивы.
	if _day_task_id >= 0:
		WorkerThreadPool.wait_for_task_completion(_day_task_id)
		_day_task_id = -1


func _apply_landscape_event(kind: String) -> void:
	if _day_task_id >= 0:
		return
	var result: Dictionary = _landscape_events.apply(kind, _center, 18.0, 3.0)
	_last_event = "%s: %d вершин" % [kind, result["vertices"]] \
		if not result.is_empty() else "%s: нет подходящего участка" % kind
	_flush_world_changes()
	_update_hud()


func _queue_days(number: int) -> void:
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
	_view_mode = (_view_mode + 1) % 8
	if _day_task_id < 0:
		_refresh_visible(true)
	_update_hud()

func _update_hud() -> void:
	if _summary == null:
		return
	_summary.text = "День %d · FPS %d · чанки %d/%d\nОчередь дней %d · пик шага %.1f мс" % [
		_last_completed_day, Engine.get_frames_per_second(), _active.size(),
		_active.size() + _pending.size(), _days_pending,
		float(_peak_day_step_us) / 1000.0]
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
	_status.text += "GPU: %d мешей · кадр %.1f мс · перерисовок сезонов %d\n" % [
		_chunk_rebuilds, float(_last_chunk_build_us) / 1000.0,
		_visual_refreshes]
	_status.text += "Шаг физики: последний %.1f мс · максимум %.1f мс\n" % [
		float(_last_day_step_us) / 1000.0,
		float(_peak_day_step_us) / 1000.0]
	for kind in _last_day_profile_us.keys():
		_status.text += "%s: %.1f мс\n" % [
			kind, float(_last_day_profile_us[kind]) / 1000.0]
	_status.text += "FPS %d · чанки %d/%d · осталось дней %d" % [
		Engine.get_frames_per_second(), _active.size(),
		_active.size() + _pending.size(), _days_pending]
