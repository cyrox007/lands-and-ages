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
const WeatherEvents = preload("res://scripts/weather_events.gd")

const VIEW_RADIUS := 4
const BUILD_PER_FRAME := 2
const CAMERA_SPEED := 32.0
const MIN_ZOOM := 16.0
const MAX_ZOOM := 105.0

var _world_model: RefCounted
var _hydro: RefCounted
var _surface: RefCounted
var _climate: RefCounted
var _landscape_events: RefCounted
var _natural_processes: RefCounted
var _weather_events: RefCounted
var _weather_status := "Молний пока не было"
var _lightning_light: OmniLight3D
var _lightning_life := 0.0
var _process_status := "Естественные процессы ещё не изменяли рельеф"
var _last_event := "Изменений ландшафта нет"
var _view_mode := 4
var _days_pending := 0
var _water_material: StandardMaterial3D
var _center := Vector2.ZERO
var _camera: Camera3D
var _terrain_holder: Node3D
var _ground_material: StandardMaterial3D
var _active: Dictionary = {}
var _pending: Array[Vector2i] = []
var _chunk_center := Vector2i(-1, -1)
var _status: Label
var _hud_timer := 0.0


func _ready() -> void:
	_world_model = WorldMap.new(WorldConfig.new())
	_world_model.vertices_changed.connect(_on_world_changed)
	_hydro = Hydrology.new(_world_model)
	_hydro.rebuild()
	_surface = Surface.new(_world_model, _hydro)
	_surface.rebuild()
	_climate = Climate.new(_world_model, _hydro)
	_climate.rebuild()
	_landscape_events = LandscapeEvents.new(_world_model)
	_natural_processes = NaturalProcesses.new(
		_world_model, _hydro, _surface, _climate)
	_weather_events = WeatherEvents.new(
		_world_model, _climate, _surface, _hydro)
	_climate.set_day(1)
	_surface.advance_climate_day(_climate)
	_hydro.apply_rainfall_map(_surface.runoff_map())
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
	panel.custom_minimum_size = Vector2(320, 130)
	canvas_layer.add_child(panel)
	var column := VBoxContainer.new()
	panel.add_child(column)
	_status = Label.new()
	column.add_child(_status)
	var info := Label.new()
	info.text = "Этап 6.4: ливни, грозы, молнии, паводки, болота и речные дельты."
	info.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	column.add_child(info)
	var day_button := Button.new()
	day_button.text = "Следующий день"
	day_button.pressed.connect(func(): _queue_days(1))
	column.add_child(day_button)
	var season_button := Button.new()
	season_button.text = "Вперёд на сезон (+24 дня)"
	season_button.pressed.connect(func(): _queue_days(Climate.SEASON_DAYS))
	column.add_child(season_button)
	var view_button := Button.new()
	view_button.text = "Слои: рельеф / почва / влага / температура / биом / снег / наносы / паводки"
	view_button.pressed.connect(_cycle_view)
	column.add_child(view_button)
	for kind in ["поднятие", "просадка", "эрозия", "оползень"]:
		var event_button := Button.new()
		event_button.text = "Изменить рельеф: " + kind
		event_button.pressed.connect(_apply_landscape_event.bind(kind))
		column.add_child(event_button)
	var hint := Label.new()
	hint.text = "WASD / стрелки — перемещение · колесо — масштаб · пальцем — сдвиг"
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	column.add_child(hint)
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
	# Большие переходы по календарю считаются по одному дню за кадр,
	# чтобы управление камерой и интерфейс не блокировались на сезон.
	if _days_pending > 0 and _pending.is_empty():
		# Обновляем изображение после каждого шага, чтобы снег наступал
		# на глазах, а не появлялся целиком в последний день сезона.
		_simulate_one_day()
		_days_pending -= 1
		_refresh_visible(true)
	for i in range(mini(BUILD_PER_FRAME, _pending.size())):
		_create_chunk(_pending.pop_front())
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
			if not _world_model.config.chunk_rect(Vector2i(cx, cy)).has_area():
				continue
			desired[Vector2i(cx, cy)] = true
	for coord in _active.keys():
		if force or not desired.has(coord):
			_active[coord].queue_free()
			_active.erase(coord)
	_pending.clear()
	for coord in desired.keys():
		if not _active.has(coord):
			_pending.append(coord)
	_pending.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
		return (a - center_chunk).length_squared() < (b - center_chunk).length_squared())


func _create_chunk(coord: Vector2i) -> void:
	if _active.has(coord):
		return
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
	_active[coord] = node


func _on_world_changed(chunks: Array[Vector2i], _revision: int) -> void:
	# Система мира обновляется от одного изменения высот, не от GPU.
	_hydro.rebuild()
	_climate.rebuild()
	_surface.rebuild(chunks)
	_surface.synchronize_climate(_climate)
	_hydro.apply_rainfall_map(_surface.runoff_map())
	_refresh_visible(true)


func _apply_landscape_event(kind: String) -> void:
	var result: Dictionary = _landscape_events.apply(kind, _center, 18.0, 3.0)
	_last_event = "%s: %d вершин" % [kind, result["vertices"]] \
		if not result.is_empty() else "%s: нет подходящего участка" % kind
	_update_hud()


func _queue_days(number: int) -> void:
	_days_pending = mini(96, _days_pending + number)


func _simulate_one_day() -> void:
	_climate.set_day(_climate.day + 1)
	_surface.advance_climate_day(_climate)
	_hydro.apply_rainfall_map(_surface.runoff_map())
	var strikes: Array[Dictionary] = _weather_events.advance_day(_climate.day)
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
	var event: Dictionary = _natural_processes.advance_day(_climate.day)
	if not event.is_empty():
		_process_status = "%s, день %d: %s" % [
			event["process"], event["day"], event["cell"]]


func _cycle_view() -> void:
	_view_mode = (_view_mode + 1) % 8
	_refresh_visible(true)
	_update_hud()

func _update_hud() -> void:
	if _status == null:
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
	_status.text += "%s\n" % _process_status
	_status.text += "%s\n" % _last_event
	_status.text += "FPS %d · чанки %d/%d · осталось дней %d" % [
		Engine.get_frames_per_second(), _active.size(),
		_active.size() + _pending.size(), _days_pending]
