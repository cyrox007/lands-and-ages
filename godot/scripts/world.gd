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
const VisualBudget = preload("res://scripts/world_visual_budget.gd")
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
const Atmosphere = preload("res://scripts/weather_atmosphere_controller.gd")
const WeatherLighting = preload("res://scripts/weather_lighting_state.gd")
const ShadowLOD = preload("res://scripts/world_shadow_lod.gd")
const WorldDayRunner = preload("res://scripts/world_day_runner.gd")
const WorldAftermath = preload("res://scripts/world_aftermath.gd")
const WorldShowcase = preload("res://scripts/world_showcase.gd")
const WorldSave = preload("res://scripts/world_save.gd")
const WorldFireDemo = preload("res://scripts/world_fire_demo.gd")
const Nature = preload("res://scripts/nature_registry.gd")
const NaturalResources = preload("res://scripts/natural_resource_registry.gd")
const ResourceGeneration = preload("res://scripts/natural_resource_generation.gd")
const FirstEconomy = preload("res://scripts/world_first_economy.gd")
const ResourceIndustry = preload("res://scripts/world_resource_industry.gd")
const Wildlife = preload("res://scripts/wildlife_populations.gd")
const WildlifeVisuals = preload("res://scripts/wildlife_visuals.gd")
const FoodWeb = preload("res://scripts/wildlife_food_web.gd")
const WildlifeHarvest = preload("res://scripts/wildlife_harvest.gd")
const WildlifeDomestic = preload("res://scripts/wildlife_domestication.gd")
const WildlifeAccess = preload("res://scripts/wildlife_region_access.gd")
const ResourceRecipes = preload("res://scripts/natural_resource_recipes.gd")
const Fire = preload("res://scripts/fire_registry.gd")
const FirePresentation = preload("res://scripts/fire_presentation_controller.gd")
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
const MAX_STORM_FALL_ANIMATIONS := 8
const MAX_CONCURRENT_CHUNK_JOBS := 2
const MESH_BUDGET_US := 4200
const HEIGHT_BOUNDS_CACHE_LIMIT := 512
const FRAME_SAMPLE_LIMIT := 120
const CAMERA_SPEED := 32.0
const MIN_ZOOM := 16.0
const MAX_ZOOM := 105.0
const STREAM_PREFETCH_PADDING := 16.0
const STREAM_TARGET_PADDING := 5.0

@export var stream_camera := false

var _world_model: RefCounted
var _hydro: RefCounted
var _surface: RefCounted
var _climate: RefCounted
var _nature: RefCounted
var _resources: RefCounted
var _economy: RefCounted
var _industry: RefCounted
var _wildlife: RefCounted
var _food_web: RefCounted
var _wildlife_visuals
var _harvest: RefCounted
var _domestic: RefCounted
var _animal_status: Label
var _hunt_species := "олень"
var _capture_species := "корова"
var _wildlife_status: Label
var _industry_status: Label
var _industry_kind := "камень"
var _industry_recipe := "тесать камень"
var _industry_building := "каменный фундамент"
var _economy_visual: Node3D
var _economy_status: Label
var _fire: RefCounted
var _fire_presentation: Node3D
var _nature_dirty: Dictionary = {}
# Природную физику синхронизируем только при смене области или чанков.
# Флаг не относится к сохранению: препятствия можно восстановить из природы.
var _collider_plan_dirty := true
var _collider_last_center := Vector2i(-1000000, -1000000)
var _collider_last_mode := -1
var _collider_sweeps := 0
var _collider_idle_skips := 0
var _collider_chunks_created := 0
var _landscape_events: RefCounted
var _natural_processes: RefCounted
var _natural_disasters: RefCounted
var _disaster_status := "Сильных природных событий пока не было"
var _weather_events: RefCounted
var _weather_status := "Молний пока не было"
var _lightning_light: OmniLight3D
var _lightning_fx: Node3D
var _world_light: DirectionalLight3D
var _sky_environment: Environment
var _shadow_center_chunk := Vector2i(-100000, -100000)
var _shadow_active := false
var _shadow_quality := 1
var _atmosphere_quality := 1
# Только рендер зависит от адаптивного бюджета, не физические поля.
var _visual_budget := VisualBudget.new()
var _applied_visual_quality := -1
var _last_shadow_zoom := -1.0
var _atmosphere: Node3D
var _lightning_life := 0.0
var _weather_fx: Node3D
var _weather_fx_cooldown := 0.0
var _mesh_budget_p95 := 0.0
var _mesh_budget_sample_in := 0.0
var _weather_light_target: Dictionary = {}
var _weather_light_current: Dictionary = {}
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
var _water_animation_time := 0.0
var _center := Vector2.ZERO
var _camera: Camera3D
var _display_camera: Camera3D
var _display_center := Vector2.ZERO
var _display_chunks := {}
var _target_chunks := {}
var _target_view_valid := false
var _loading_layer: CanvasLayer
var _loading_label: Label
var _loading_progress: ProgressBar
var _startup_task_id := -1
var _terrain_holder: Node3D
var _ground_material: ShaderMaterial
# A/B-диагностика CPU-чанков; в обычной игре кеш всегда включён.
var _pbr_shore_cache_enabled := true
# A/B-переключатель физических проб цвета и материала.
var _pbr_physical_cells_enabled := true
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
var _total_nature_attach_us := 0
var _total_scene_attach_us := 0
var _total_collider_attach_us := 0
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
var _main_panel: PanelContainer
var _showcase_overlay: PanelContainer
var _showcase_overlay_text: Label
var _showcase_text: Label
var _showcase_views: Array[Dictionary] = []
var _showcase_index := -1
var _hud_timer := 0.0
var _benchmark_running := false
var _benchmark_status := ""
# UI-сценарий сохраняет один ракурс для всех трёх кадров
# и не касается стандартного пользовательского WorldSave.
var _fire_demo: Dictionary = {}
var _fire_demo_status: Label
var _fire_demo_stable_frames := 0


static func _generate_world_models() -> Dictionary:
	var world := WorldMap.new(WorldConfig.new())
	var hydro := Hydrology.new(world)
	hydro.rebuild()
	var surface := Surface.new(world, hydro)
	surface.rebuild()
	var climate := Climate.new(world, hydro)
	climate.rebuild()
	climate.set_day(1)
	surface.advance_climate_day(climate)
	hydro.apply_rainfall_map(surface.runoff_map())
	var nature := Nature.new(world, hydro, surface, climate)
	nature.generate()
	# Естественные источники формируются вместе с ландшафтом,
	# а не появляются только после постройки карьера или шахты.
	var resources := NaturalResources.new(world)
	ResourceGeneration.populate(world, hydro, surface, resources)
	var economy := FirstEconomy.new(world, hydro, surface, nature,
		resources, climate.day)
	var industry := ResourceIndustry.new(world, hydro, surface, nature,
		resources, climate.day)
	# Фауна формируется лишь в биотопах с доказанным кормом, водой
	# и укрытием. Не создаём Node3D для каждого животного.
	var wildlife := Wildlife.new(world, hydro, surface, climate, nature)
	wildlife.generate()
	# Хищники инициализируются ПОСЛЕ травоядных, иначе нет
	# реального источника добычи и появились бы фиктивные стаи.
	var food_web := FoodWeb.new(world, climate, wildlife)
	food_web.generate()
	# Охота и домашние линии не создают животных сами по себе:
	# запуск требует реального источника и сухопутного маршрута.
	var harvest := WildlifeHarvest.new(world, hydro, surface, climate, wildlife)
	var domestic := WildlifeDomestic.new(world, hydro, surface, climate,
		wildlife, food_web, harvest)
	return {"harvest": harvest, "domestic": domestic, "food_web": food_web, "wildlife": wildlife, "industry": industry, "economy": economy,
		"resources": resources, "world": world, "hydro": hydro, "surface": surface,
		"climate": climate, "nature": nature}


func _ready() -> void:
	var models := {}
	if stream_camera:
		_setup_loading()
		set_process(false)
		set_process_unhandled_input(false)
		# У моделей до завершения задания один владелец. Сцена и GPU
		# создаются на главном потоке после получения результата.
		_startup_task_id = WorkerThreadPool.add_task(func():
			models.merge(_generate_world_models()), false, "Подготовка мира")
		while not WorkerThreadPool.is_task_completed(_startup_task_id):
			await get_tree().process_frame
		WorkerThreadPool.wait_for_task_completion(_startup_task_id)
		_startup_task_id = -1
	else:
		models = _generate_world_models()
	_world_model = models["world"]
	_world_model.vertices_changed.connect(_on_world_changed, CONNECT_DEFERRED)
	_hydro = models["hydro"]
	_surface = models["surface"]
	_climate = models["climate"]
	_nature = models["nature"]
	_resources = models["resources"]
	_economy = models["economy"]
	_industry = models["industry"]
	_wildlife = models["wildlife"]
	_food_web = models["food_web"]
	_harvest = models["harvest"]
	_domestic = models["domestic"]
	_landscape_events = LandscapeEvents.new(_world_model)
	_natural_processes = NaturalProcesses.new(
		_world_model, _hydro, _surface, _climate)
	_natural_disasters = NaturalDisasters.new(_world_model, _hydro, _surface, _climate)
	_weather_events = WeatherEvents.new(_world_model, _climate, _surface, _hydro)
	_fire = Fire.new(_world_model, _hydro, _surface, _climate, _nature)
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
	# Графика животных существует только около камеры. Её создание
	# не прибавляет особей и не вмешивается в физический календарь.
	_wildlife_visuals = WildlifeVisuals.new()
	_wildlife_visuals.name = "Видимые настоящие животные"
	add_child(_wildlife_visuals)
	_wildlife_visuals.configure(_world_model, _hydro, _surface,
		_wildlife, _food_web, _domestic)
	_update_material_detail()
	_update_camera()
	if stream_camera:
		_display_camera = Camera3D.new()
		_display_camera.name = "Камера игрока"
		_display_camera.projection = Camera3D.PROJECTION_ORTHOGONAL
		add_child(_display_camera)
		_display_camera.transform = _camera.transform
		_display_camera.size = _camera.size
		_display_center = _center
		_display_camera.make_current()
		_loading_label.text = "Собираем первый вид"
		_loading_progress.indeterminate = false
	# Общая оболочка владеет эффектами погоды, молниями и громом.
	# Вся физика по-прежнему живёт отдельно в Climate/WeatherEvents.
	_atmosphere = Atmosphere.new()
	_atmosphere.name = "Контроллер атмосферы"
	add_child(_atmosphere)
	_weather_fx = _atmosphere.precipitation
	_lightning_fx = _atmosphere.lightning
	# Один аудиоплеер и один свет на всю карту создаём только
	# после завершения физической генерации и настройки камеры.
	_fire_presentation = FirePresentation.new()
	_fire_presentation.name = "Визуальные и звуковые эффекты пожара"
	add_child(_fire_presentation)
	_apply_visual_budget()
	_atmosphere.sync_world(_climate, _world_model, _center, _camera.size)
	_sync_water_weather()
	_setup_interface()
	_sync_first_economy_visual()
	_refresh_visible(true)
	get_viewport().size_changed.connect(_on_viewport_resized)
	set_process(true)
	set_process_unhandled_input(true)


func _setup_loading() -> void:
	_loading_layer = CanvasLayer.new()
	_loading_layer.layer = 10
	add_child(_loading_layer)
	var backdrop := ColorRect.new()
	backdrop.color = Color("#202c28")
	_loading_layer.add_child(backdrop)
	backdrop.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var center := CenterContainer.new()
	backdrop.add_child(center)
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var column := VBoxContainer.new()
	column.custom_minimum_size.x = 240.0
	center.add_child(column)
	var title := Label.new()
	title.text = "Земли и эпохи"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 28)
	column.add_child(title)
	_loading_label = Label.new()
	_loading_label.text = "Формируем мир"
	_loading_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	column.add_child(_loading_label)
	_loading_progress = ProgressBar.new()
	_loading_progress.show_percentage = false
	_loading_progress.indeterminate = true
	column.add_child(_loading_progress)


func _present_camera() -> void:
	if _display_camera == null or not _target_view_valid:
		return
	if not _loading_layer.visible and is_same(_display_chunks, _target_chunks) \
			and _display_center == _center and _display_camera.size == _camera.size:
		return
	var ready := 0
	for coord in _target_chunks:
		if _active.has(coord):
			ready += 1
	if _loading_layer.visible:
		_loading_progress.max_value = maxf(1.0, float(_target_chunks.size()))
		_loading_progress.value = ready
	if ready < _target_chunks.size():
		return
	var zoom_changed := _display_camera.size != _camera.size
	_display_camera.transform = _camera.transform
	_display_camera.size = _camera.size
	_display_center = _center
	_display_chunks = _target_chunks
	if zoom_changed:
		_update_material_detail()
	else:
		_update_shadow_lod()
	_loading_layer.hide()


func _on_viewport_resized() -> void:
	# Новый размер экрана сразу меняет фактический кадр. Закрываем
	# его, пока расширившаяся область не готова.
	if _display_camera != null:
		_loading_label.text = "Подготавливаем вид"
		_loading_layer.show()
	_refresh_visible(false)
	_present_camera()


func _setup_environment() -> void:
	# Короткая вспышка показывается только на месте физического удара.
	_lightning_light = OmniLight3D.new()
	_lightning_light.name = "Вспышка молнии"
	_lightning_light.omni_range = 42.0
	_lightning_light.light_energy = 5.0
	_lightning_light.visible = false
	add_child(_lightning_light)
	# Настоящий направленный свет создаём один раз. Карта теней
	# включается только в ближнем масштабе через ShadowLOD.
	_world_light = DirectionalLight3D.new()
	_world_light.name = "Солнечный свет"
	_world_light.rotation_degrees = Vector3(-38, -36, 0)
	_world_light.light_color = Color(1.0, 0.94, 0.84)
	_world_light.light_energy = 1.38
	_world_light.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_2_SPLITS
	_world_light.directional_shadow_max_distance = 155.0
	_world_light.shadow_enabled = false
	add_child(_world_light)
	var sky := WorldEnvironment.new()
	var options := Environment.new()
	options.background_mode = Environment.BG_COLOR
	options.background_color = Color(0.54, 0.65, 0.69)
	options.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	options.ambient_light_color = Color(0.74, 0.81, 0.85)
	options.ambient_light_energy = 0.37
	# Один туман для воды, леса и гор. В Compatibility используем
	# обычный экспоненциальный и высотный fog вместо дорогого
	# volumetric, недоступного на мобильном рендерере.
	options.fog_enabled = false
	options.fog_mode = Environment.FOG_MODE_EXPONENTIAL
	options.fog_light_color = Color(0.67, 0.76, 0.80)
	options.fog_density = 0.001
	options.fog_height = 2.5
	options.fog_height_density = 0.0
	options.fog_light_energy = 0.84
	options.fog_sun_scatter = 0.0
	options.fog_sky_affect = 0.18
	sky.environment = options
	_sky_environment = options
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
	# Скальная художественная детализация включена для настоящих
	# обнажений. Для сравнения кадров R4 можно временно задать 0.
	_ground_material.set_shader_parameter("rock_face_detail", 1.0)
	# Подкрашиваем только уже существующие физические покрытия.
	# Параметр 0 воспроизводит R4a для сравнения тех же камер.
	_ground_material.set_shader_parameter("terrain_palette_strength", 1.0)
	# Используем направление уже существующего солнца, а не
	# декоративный источник дальнего света из отдельной системы.
	if _world_light != null:
		# В headless-тесте узел ещё не находится в SceneTree;
		# там локальный базис солнца совпадает с мировым.
		var sun_basis := _world_light.transform.basis
		if _world_light.is_inside_tree():
			sun_basis = _world_light.global_transform.basis
		_ground_material.set_shader_parameter("far_light_direction",
			sun_basis.z.normalized())
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
	_main_panel = panel
	canvas_layer.add_child(panel)
	panel.offset_left = 14.0
	panel.offset_top = 14.0
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.follow_focus = true
	panel.add_child(scroll)
	var column := VBoxContainer.new()
	column.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(column)
	var fit_panel := func() -> void:
		var viewport_size := get_viewport().get_visible_rect().size
		panel.offset_right = minf(405.0, viewport_size.x - 14.0)
		panel.offset_bottom = minf(viewport_size.y - 14.0,
			viewport_size.y if _debug_details.visible else 330.0)
	_summary = Label.new()
	_summary.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
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
	# Маршрут доступен без открытия технической диагностики:
	# игрок сразу видит живые места, которые существуют на карте.
	var showcase_button := Button.new()
	showcase_button.name = "Прогулка по миру"
	showcase_button.text = "Показать следующее красивое место"
	showcase_button.pressed.connect(_next_showcase_view)
	column.add_child(showcase_button)
	_showcase_text = Label.new()
	_showcase_text.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_showcase_text.text = "Лес · река · горы · побережье"
	column.add_child(_showcase_text)
	# Игрок может запустить настоящую цепочку из физического сырья.
	# Работа идёт по календарю, а не по нажатию декоративной кнопки.
	var economy_button := Button.new()
	economy_button.text = "Начать строительство кирпичной мастерской"
	economy_button.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	economy_button.pressed.connect(_begin_first_economy)
	column.add_child(economy_button)
	_economy_status = Label.new()
	_economy_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	column.add_child(_economy_status)
	var event_demo := Button.new()
	event_demo.name = "Сквозной пожар"
	event_demo.text = "Показать пожар: до → после → восстановление"
	event_demo.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	event_demo.pressed.connect(_begin_fire_demo)
	column.add_child(event_demo)
	_fire_demo_status = Label.new()
	_fire_demo_status.name = "Статус испытания пожара"
	_fire_demo_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_fire_demo_status.text = "Кадры и сохранение испытания ещё не создавались"
	column.add_child(_fire_demo_status)
	# В режиме прогулки вместо большой панели останется только
	# маленькое управление. Так почти весь экран занимает сам мир.
	_showcase_overlay = PanelContainer.new()
	_showcase_overlay.name = "Режим прогулки"
	_showcase_overlay.anchor_left = 1.0
	_showcase_overlay.anchor_right = 1.0
	_showcase_overlay.offset_left = -320.0
	_showcase_overlay.offset_right = -14.0
	_showcase_overlay.offset_top = 14.0
	_showcase_overlay.offset_bottom = 124.0
	_showcase_overlay.visible = false
	canvas_layer.add_child(_showcase_overlay)
	var scenic_column := VBoxContainer.new()
	_showcase_overlay.add_child(scenic_column)
	_showcase_overlay_text = Label.new()
	_showcase_overlay_text.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	scenic_column.add_child(_showcase_overlay_text)
	var scenic_controls := HBoxContainer.new()
	scenic_column.add_child(scenic_controls)
	var scenic_next := Button.new()
	scenic_next.text = "Следующее место"
	scenic_next.pressed.connect(_next_showcase_view)
	scenic_controls.add_child(scenic_next)
	var scenic_exit := Button.new()
	scenic_exit.name = "Выход из прогулки"
	scenic_exit.text = "Вернуться"
	scenic_exit.pressed.connect(_exit_showcase)
	scenic_controls.add_child(scenic_exit)
	_details_toggle = Button.new()
	_details_toggle.text = "Показать диагностику"
	_details_toggle.pressed.connect(_toggle_debug)
	column.add_child(_details_toggle)
	_debug_details = VBoxContainer.new()
	_debug_details.visible = false
	column.add_child(_debug_details)
	_status = Label.new()
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_debug_details.add_child(_status)
	var shadow_quality := OptionButton.new()
	shadow_quality.add_item("Тени · экономно")
	shadow_quality.add_item("Тени · стандарт")
	shadow_quality.add_item("Тени · подробно")
	shadow_quality.select(_shadow_quality)
	shadow_quality.item_selected.connect(_set_shadow_quality)
	_debug_details.add_child(shadow_quality)
	# Атмосферный профиль регулирует все GPU-частицы и число
	# одновременных молний, независимо от качества теней.
	var weather_quality := OptionButton.new()
	for name in Atmosphere.QUALITY_NAMES:
		weather_quality.add_item("Атмосфера · " + name)
	weather_quality.select(_atmosphere_quality)
	weather_quality.item_selected.connect(_set_atmosphere_quality)
	_debug_details.add_child(weather_quality)
	var benchmark_button := Button.new()
	benchmark_button.text = "Измерить производительность камеры (8.8)"
	benchmark_button.pressed.connect(_run_device_benchmark)
	_debug_details.add_child(benchmark_button)
	# Отдельный замер реальной перестройки кратера, оползня и
	# просадки: не смешиваем его с неизменяемым маршрутом камеры 8.8.
	var landscape_benchmark := Button.new()
	landscape_benchmark.text = "Измерить перестройку рельефа (11.7/RF4)"
	landscape_benchmark.pressed.connect(_run_landscape_benchmark)
	_debug_details.add_child(landscape_benchmark)
	var relief_benchmark := Button.new()
	relief_benchmark.text = "Профиль рельефа R6: материал и кадры"
	relief_benchmark.pressed.connect(_run_relief_benchmark)
	_debug_details.add_child(relief_benchmark)
	var felling_button := Button.new()
	felling_button.text = "Ударить по ближайшему дереву"
	felling_button.pressed.connect(_debug_fell_nearest_tree)
	_debug_details.add_child(felling_button)
	var storm_button := Button.new()
	storm_button.text = "Испытать шторм: ветер и ветровал"
	storm_button.pressed.connect(_debug_test_storm)
	_debug_details.add_child(storm_button)
	var squall_button := Button.new()
	squall_button.text = "Испытать шквал: полоса ветровала"
	squall_button.pressed.connect(_debug_test_squall)
	_debug_details.add_child(squall_button)
	var hurricane_button := Button.new()
	hurricane_button.text = "Испытать ураган: широкая зона ветровала"
	hurricane_button.pressed.connect(_debug_test_hurricane)
	_debug_details.add_child(hurricane_button)
	var shrub_button := Button.new()
	shrub_button.text = "Испытать ветер: повреждение кустарника"
	shrub_button.pressed.connect(_debug_test_shrub_damage)
	_debug_details.add_child(shrub_button)
	var tornado_button := Button.new()
	tornado_button.text = "Испытать смерч: узкий след разрушений"
	tornado_button.pressed.connect(_debug_test_tornado)
	_debug_details.add_child(tornado_button)
	var dust_button := Button.new()
	dust_button.text = "Испытать пыльную бурю: перенос сухого грунта"
	dust_button.pressed.connect(_debug_test_dust_storm)
	_debug_details.add_child(dust_button)
	var fire_button := Button.new()
	fire_button.text = "Испытать пожар: поджечь сухое дерево"
	fire_button.pressed.connect(_debug_test_fire)
	_debug_details.add_child(fire_button)
	for kind in ["поднятие", "просадка", "эрозия", "оползень"]:
		var event_button := Button.new()
		event_button.text = "Изменить рельеф: " + kind
		event_button.pressed.connect(_apply_landscape_event.bind(kind))
		_debug_details.add_child(event_button)
	# Производственный стенд доступен лишь после первой настоящей
	# мастерской. Выбираем сырьё, рецепт и потребителя из общего
	# реестра; десятки однотипных кнопок не занимают игровую карту.
	var resource_select := OptionButton.new()
	_industry_kind = str(ResourceRecipes.RAW_MATERIALS[0])
	for material in ResourceRecipes.RAW_MATERIALS:
		resource_select.add_item(material)
	resource_select.item_selected.connect(func(i: int):
		_industry_kind = str(ResourceRecipes.RAW_MATERIALS[i]))
	_debug_details.add_child(resource_select)
	var delivery_button := Button.new()
	delivery_button.text = "Доставить выбранное сырьё (3 ед.)"
	delivery_button.pressed.connect(_industry_order)
	_debug_details.add_child(delivery_button)
	var recipe_select := OptionButton.new()
	var recipe_ids := ResourceRecipes.RECIPES.keys()
	recipe_ids.sort()
	_industry_recipe = str(recipe_ids[0])
	for name in recipe_ids:
		recipe_select.add_item(name)
	recipe_select.item_selected.connect(func(i: int):
		_industry_recipe = str(recipe_ids[i]))
	_debug_details.add_child(recipe_select)
	var produce_button := Button.new()
	produce_button.text = "Произвести по выбранному рецепту"
	produce_button.pressed.connect(_industry_produce)
	_debug_details.add_child(produce_button)
	var consumer_select := OptionButton.new()
	var consumer_ids := ResourceRecipes.CONSUMERS.keys()
	consumer_ids.sort()
	_industry_building = str(consumer_ids[0])
	for name in consumer_ids:
		consumer_select.add_item(name)
	consumer_select.item_selected.connect(func(i: int):
		_industry_building = str(consumer_ids[i]))
	_debug_details.add_child(consumer_select)
	var build_button := Button.new()
	build_button.text = "Израсходовать товары на строительство"
	build_button.pressed.connect(_industry_build)
	_debug_details.add_child(build_button)
	var research_button := Button.new()
	research_button.text = "Изучить следующую технологию (за материалы)"
	research_button.pressed.connect(_industry_research)
	_debug_details.add_child(research_button)
	_industry_status = Label.new()
	_industry_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_debug_details.add_child(_industry_status)
	_wildlife_status = Label.new()
	_wildlife_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_debug_details.add_child(_wildlife_status)
	# Существующие стада — единственный источник добычи и предков.
	# Выбор вида не создаёт животных и не обходит физику ареалов.
	var hunt_menu := OptionButton.new()
	var hunt_options := WildlifeHarvest.YIELDS.keys()
	hunt_options.sort()
	_hunt_species = str(hunt_options[0])
	for kind in hunt_options:
		hunt_menu.add_item(str(kind))
	hunt_menu.item_selected.connect(func(i: int):
		_hunt_species = str(hunt_options[i]))
	_debug_details.add_child(hunt_menu)
	var hunt_button := Button.new()
	hunt_button.text = "Отправить охотника за выбранным видом"
	hunt_button.pressed.connect(_order_hunting)
	_debug_details.add_child(hunt_button)
	var butcher_button := Button.new()
	butcher_button.text = "Разделать одну доставленную тушу"
	butcher_button.pressed.connect(_butcher_animal)
	_debug_details.add_child(butcher_button)
	var food_button := Button.new()
	food_button.text = "Израсходовать 1 ед. мяса"
	food_button.pressed.connect(_consume_animal_food)
	_debug_details.add_child(food_button)
	# Сырьё животного происхождения имеет действующие рецепты:
	# без шкур, костей и перьев предметы не появляются.
	for gear in WildlifeHarvest.GEAR:
		var item_button := Button.new()
		item_button.text = "Изготовить: " + str(gear)
		item_button.pressed.connect(_craft_animal_gear.bind(str(gear)))
		_debug_details.add_child(item_button)
	var domestic_menu := OptionButton.new()
	var domestic_options := WildlifeDomestic.LINEAGES.keys()
	domestic_options.sort()
	_capture_species = str(domestic_options[0])
	for kind in domestic_options:
		domestic_menu.add_item(str(kind))
	domestic_menu.item_selected.connect(func(i: int):
		_capture_species = str(domestic_options[i]))
	_debug_details.add_child(domestic_menu)
	var capture_button := Button.new()
	capture_button.text = "Отловить до двух живых предков выбранного вида"
	capture_button.pressed.connect(_order_capture)
	_debug_details.add_child(capture_button)
	_animal_status = Label.new()
	_animal_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_debug_details.add_child(_animal_status)
	for button in _debug_details.get_children():
		if button is Button:
			button.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_debug_details.move_child(_status, -1)
	_debug_details.visibility_changed.connect(fit_panel)
	get_viewport().size_changed.connect(fit_panel)
	fit_panel.call()
	_update_hud()


func _toggle_debug() -> void:
	_debug_details.visible = not _debug_details.visible
	_details_toggle.text = "Скрыть диагностику" if _debug_details.visible \
		else "Показать диагностику"
	_update_hud()


func _next_showcase_view() -> void:
	# Прогулка не запускает физические события и не изменяет мир.
	# Во время расчёта суток или фонового теста остаёмся в
	# последней готовой позиции, избегая гонки с RefCounted-моделями.
	if _benchmark_running or _day_task_id >= 0 or _days_pending > 0 \
			or not _storage_request.is_empty() or _fire_demo_active():
		if _showcase_text != null:
			_showcase_text.text = "Сначала завершите расчёт мира"
		return
	if _showcase_views.is_empty():
		_showcase_views = WorldShowcase.select_views(
			_world_model, _hydro, _surface, _nature)
	if _showcase_views.is_empty():
		_showcase_text.text = "Подходящих природных мест не найдено"
		return

	# Переходим к следующей настоящей географической точке.
	# В отличие от обычного перемещения это дальний переход:
	# ограничение скорости движения камеры к нему не применяется.
	_showcase_index = (_showcase_index + 1) % _showcase_views.size()
	var spot: Dictionary = _showcase_views[_showcase_index]
	var cell: Vector2i = spot["cell"]
	var old_sparse := _detail_for_zoom(_camera.size) \
		< NatureRenderer.SPARSE_GROUND_COVER_DETAIL
	_camera.size = clampf(float(spot["zoom"]), MIN_ZOOM, MAX_ZOOM)
	var next_sparse := _detail_for_zoom(_camera.size) \
		< NatureRenderer.SPARSE_GROUND_COVER_DETAIL
	_center = _world_model.config.clamp_point(
		Vector2(cell) + Vector2(0.5, 0.5))
	_pan_delta = Vector2.ZERO
	_pan_pending = false
	_view_mode = 0
	_weather_fx_cooldown = 0.0
	_update_camera()
	_apply_visual_budget()
	_update_material_detail()

	# При удалённом переходе не показываем незагруженную землю:
	# прежний кадр закрыт, пока нужные чанки не подготовлены.
	if _loading_layer != null:
		_loading_label.text = "Открываем: " + str(spot["name"])
		_loading_layer.show()
	_refresh_visible(old_sparse != next_sparse)
	_showcase_text.text = "%d/%d · %s\n%s" % [
		_showcase_index + 1, _showcase_views.size(), spot["name"],
		spot["meaning"]]
	_showcase_overlay_text.text = _showcase_text.text
	_main_panel.visible = false
	_showcase_overlay.visible = true
	_update_hud()


func _exit_showcase() -> void:
	# Возврат раскрывает основные игровые действия, но не
	# телепортирует камеру назад и не изменяет физическую карту.
	# Игрок может продолжить осмотр интересного места вручную.
	_showcase_index = -1
	_main_panel.visible = true
	_showcase_overlay.visible = false
	_showcase_text.text = "Лес · река · горы · побережье"
	_update_hud()


func _update_camera() -> void:
	var offset := Vector3(45.0, 63.0, 45.0)
	_camera.position = Vector3(_center.x, 0.0, _center.y) + offset
	_camera.look_at(Vector3(_center.x, 0.0, _center.y), Vector3.UP)


func _process(delta: float) -> void:
	# Не читаем изменяемые реестры в момент работы фонового
	# WorldDayRunner; вне видимости не создаём скелетных узлов.
	if _wildlife_visuals != null and _day_task_id < 0 \
			and _days_pending == 0:
		_wildlife_visuals.refresh(_center, _camera.size, delta)
	_record_frame(delta)
	_advance_water_animation(delta)
	_advance_weather_lighting(delta)
	var movement := Vector2.ZERO
	if Input.is_key_pressed(KEY_A) or Input.is_key_pressed(KEY_LEFT):
		movement.x -= 1.0
	if Input.is_key_pressed(KEY_D) or Input.is_key_pressed(KEY_RIGHT):
		movement.x += 1.0
	if Input.is_key_pressed(KEY_W) or Input.is_key_pressed(KEY_UP):
		movement.y -= 1.0
	if Input.is_key_pressed(KEY_S) or Input.is_key_pressed(KEY_DOWN):
		movement.y += 1.0
	if not _benchmark_running and not _fire_demo_active() \
			and movement.length_squared() > 0.0 \
			and (_loading_layer == null or not _loading_layer.visible):
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
		# Пока физическая задача работает в потоке, климат не читаем.
		# Снимок осадков обновляем редко, не при каждом графическом кадре.
		if _atmosphere != null:
			_weather_fx_cooldown -= delta
			if _weather_fx_cooldown <= 0.0:
				# Скрытие частиц и грома не отменяет физическую погоду.
				_atmosphere.set_effects_enabled(
					_view_mode == 0 and not _benchmark_running)
				var weather_center := _display_center if _display_camera != null else _center
				var weather_zoom := _display_camera.size if _display_camera != null else _camera.size
				_atmosphere.sync_world(_climate, _world_model, weather_center, weather_zoom)
				_sync_water_weather()
				_weather_fx_cooldown = VisualBudget.weather_sync_interval(
					_render_zoom(), _mesh_budget_p95)
	# Пространственный треск и отблеск видны только по
	# завершённому физическому дню. Считывание FireRegistry
	# никогда не пересекается с WorkerThreadPool.
	if _fire_presentation != null:
		if _day_task_id < 0 and _days_pending == 0:
			var fire_center := _display_center if _display_camera != null \
				else _center
			_fire_presentation.sync_view(delta, _fire, _nature,
				_world_model, fire_center, _render_zoom(),
				_view_mode == 0 and not _benchmark_running)
		else:
			_fire_presentation.set_effects_enabled(false)
	# Обновление мешей откладывается до конца перемотки,
	# поэтому очередь GPU не тормозит каждый из 24 физических дней.
	if _days_pending == 0 and _day_task_id < 0:
		_mesh_budget_sample_in -= delta
		if _mesh_budget_sample_in <= 0.0:
			_mesh_budget_p95 = _frame_percentile(_frame_samples, 0.95)
			_mesh_budget_sample_in = 0.15
			# Ограничиваем визуальную нагрузку по p95, не меняя
			# ни климат, ни дневной WorkerThreadPool.
			_apply_visual_budget()
		_mesh_build_budget_us = ChunkBuildQueue.budget_us(
			_mesh_budget_p95, _pan_pending, MESH_BUDGET_US)
		if is_inside_tree():
			_start_chunk_jobs()
		else:
			_build_chunks_synchronously()
	_present_camera()
	_advance_fire_demo()
	_pan_pending = false
	_hud_timer += delta
	if _hud_timer > 0.3:
		_update_hud()
		_hud_timer = 0.0


func _unhandled_input(event: InputEvent) -> void:
	if _benchmark_running or _fire_demo_active() \
			or (_loading_layer != null and _loading_layer.visible):
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


func _advance_water_animation(delta: float) -> void:
	## Шейдер читает только часы видимой сцены, не создавая событий.
	## Godot передаёт delta с учётом Engine.time_scale; при паузе
	## _process остановлен, а ручной вызов дополнительно защищён.
	if _water_material == null or not is_finite(delta) or delta <= 0.0:
		return
	if is_inside_tree() and get_tree().paused:
		return
	# Одна запись uniform на кадр для всех водных чанков.
	# Ни климат, ни гидрология, ни сохранения при этом не меняются.
	_water_animation_time += delta
	_water_material.set_shader_parameter("wave_time", _water_animation_time)
	# Пятна облаков используют тот же счётчик кадров, что и волны.
	if _ground_material != null:
		_ground_material.set_shader_parameter("cloud_time",
			_water_animation_time)


func _write_weather_lighting(lighting: Dictionary) -> void:
	## Применяем к сцене только уже интерполированные параметры.
	## Один источник света и один материал работают на все чанки,
	## поэтому на стыках нет отдельных таймеров или различий оттенка.
	if _world_light == null:
		return
	_world_light.light_energy = float(lighting["sun_energy"])
	_world_light.light_color = lighting["sun_color"]
	if _sky_environment != null:
		_sky_environment.ambient_light_energy = float(lighting["ambient_energy"])
		_sky_environment.background_color = lighting["sky_color"]
		# Плотность интерполируется вместе со светом. Профиль
		# лишь уменьшает GPU-нагрузку/контраст: физика не меняется.
		var fog_scale: float = [0.62, 0.84, 1.0][_atmosphere_quality]
		var strength: float = float(lighting["fog_strength"])
		_sky_environment.fog_enabled = _view_mode == 0 and strength > 0.008
		_sky_environment.fog_density = float(lighting["fog_density"]) * fog_scale
		_sky_environment.fog_height_density = (
			float(lighting["fog_height_density"]) * fog_scale)
		_sky_environment.fog_light_color = lighting["fog_color"]
		_sky_environment.fog_sun_scatter = float(lighting["fog_sun_scatter"])
	if _ground_material != null:
		# Пятна облачности читают абсолютные мировые координаты.
		_ground_material.set_shader_parameter("cloud_coverage",
			float(lighting["cloud_coverage"]))
		_ground_material.set_shader_parameter("cloud_wind",
			float(lighting["wind"]))
		_ground_material.set_shader_parameter("cloud_direction", Vector2(
			float(lighting["wind_x"]), float(lighting["wind_y"])))
		_ground_material.set_shader_parameter("cloud_sunbreak",
			float(lighting["cloud_sunbreak"]))


func _advance_weather_lighting(delta: float) -> void:
	## Двигаем только текущую визуальную палитру к сохранённой цели.
	## Climate и фоновые потоки здесь не читаются даже во время
	## расчёта нового дня; пауза и ускорение работают через delta.
	if _weather_light_target.is_empty() or _weather_light_current.is_empty() \
			or _weather_light_current == _weather_light_target:
		return
	if not is_finite(delta) or delta <= 0.0:
		return
	if is_inside_tree() and get_tree().paused:
		return
	_weather_light_current = WeatherLighting.blend(
		_weather_light_current, _weather_light_target, delta)
	var settled := true
	for key in _weather_light_target:
		var value: Variant = _weather_light_current[key]
		var target: Variant = _weather_light_target[key]
		if value is Color:
			settled = settled and value.is_equal_approx(target)
		else:
			settled = settled and absf(float(value) - float(target)) < 0.001
	if settled:
		_weather_light_current = _weather_light_target
	_write_weather_lighting(_weather_light_current)


func _apply_weather_lighting(snapshot: Dictionary) -> void:
	## Обновление погоды меняет целевой свет, а не мгновенный кадр.
	## Первая инициализация — немедленная; автономные smoke-тесты
	## также получают готовое состояние без игрового _process.
	if _world_light == null:
		return
	var target: Dictionary = WeatherLighting.from_snapshot(snapshot)
	if _view_mode != 0:
		# Диагностическая палитра выключает погодный свет сразу,
		# не смешивая цвета категории с предыдущей грозой.
		target = WeatherLighting.from_snapshot({})
	_weather_light_target = target
	if _weather_light_current.is_empty() or not is_inside_tree() or _view_mode != 0:
		_weather_light_current = target.duplicate(true)
		_write_weather_lighting(_weather_light_current)


func _sync_water_weather() -> void:
	## Передаём ветру и шторму один проверенный снимок камеры.
	## Климат не читается, пока фоновый расчёт дня меняет физические массивы.
	if _water_material == null or _weather_fx == null:
		return
	var snapshot: Dictionary = _weather_fx.debug_state()
	# Видимая растительность следует за физическим направлением фронта.
	# Обновляем только шейдеры, без CPU-анимации каждого дерева.
	var airflow := Vector2(float(snapshot.get("wind_x", 1.0)),
		float(snapshot.get("wind_y", 0.0)))
	# На границе встречных фронтов среднее направление может обнулиться.
	# Не передаём нулевой вектор в шейдер: сохраняем западный базис.
	if airflow.length_squared() < 0.000001:
		airflow = Vector2.RIGHT
	else:
		airflow = airflow.normalized()
	NatureRenderer.set_wind_direction(airflow)
	# Волны озёр и моря теперь смотрят туда же, куда кроны и осадки.
	# Параметры меняют только рендер, не уровень физической воды.
	_water_material.set_shader_parameter("wind_direction", airflow)
	_water_material.set_shader_parameter("wind_strength",
		float(snapshot.get("wind", 0.0)))
	_water_material.set_shader_parameter("storm_strength",
		float(snapshot.get("storm", 0.0)))
	_apply_weather_lighting(snapshot)


func _update_material_detail() -> void:
	if _camera == null:
		return
	var detail := _detail_for_zoom(_render_zoom())
	if _ground_material != null:
		_ground_material.set_shader_parameter("detail_strength", detail)
		# Дальние планы обходятся без дополнительного шума и изгиба UV.
		_ground_material.set_shader_parameter("macro_strength", detail)
	if _water_material != null:
		# Два непрерывных уровня: мелкая рябь исчезает вдали,
		# но широкие недорогие блики продолжают движение.
		_water_material.set_shader_parameter("ripple_strength", detail)
		_water_material.set_shader_parameter("far_glint_strength", 1.0 - detail)
	# При отдалении прекращаем дорогие тени, но оставляем R2
	# (светотеневые маски реального рельефа) и обычное освещение.
	_update_shadow_lod()


func _render_zoom() -> float:
	return _display_camera.size if _display_camera != null else _camera.size


func _set_shadow_quality(preset: int) -> void:
	_shadow_quality = clampi(preset, 0, 2)
	_update_shadow_lod()


func _apply_visual_budget() -> void:
	# Автор выбирает максимум качества, а p95/масштаб ограничивают
	# только графические затраты. Физические данные не изменяем.
	if _camera == null:
		return
	var old_pressure: int = _visual_budget._pressure_cap
	var level: int = _visual_budget.resolve(
		_atmosphere_quality, _camera.size, _mesh_budget_p95)
	if _atmosphere != null and _applied_visual_quality != level:
		_atmosphere.set_quality(level)
		if _fire_presentation != null:
			_fire_presentation.set_quality(level)
		_applied_visual_quality = level
		_weather_fx_cooldown = 0.0
	# При смене профиля давления корректируем дальность теней
	# даже без движения камеры.
	if old_pressure != _visual_budget._pressure_cap:
		_update_shadow_lod()


func _set_atmosphere_quality(preset: int) -> void:
	# Ручная настройка остаётся потолком и не переписывается
	# автоматикой. Сохранения и игровые сутки не затрагиваются.
	_atmosphere_quality = clampi(preset, 0, 2)
	_apply_visual_budget()
	# Изменение качества тумана действует немедленно даже при
	# неподвижной камере и неизменном климатическом снимке.
	if not _weather_light_current.is_empty():
		_write_weather_lighting(_weather_light_current)
	_weather_fx_cooldown = 0.0


func _contact_shadow_direction() -> Vector2:
	var sun := _world_light.transform.basis.z
	return Vector2(-sun.x, -sun.z).normalized()


func _shadow_zoom() -> float:
	# Давление кадра временно снижает теневой профиль,
	# но не повышает его выше ручного значения автора.
	var quality := mini(_shadow_quality, _visual_budget._pressure_cap)
	return _render_zoom() * [1.5, 1.0, 0.82][quality]


func _update_shadow_lod() -> void:
	## Меняем теневые свойства только при переходе на иной чанк
	## или при переключении режима/масштаба. В физику не входим.
	if _camera == null or _world_model == null:
		return
	var zoom := _shadow_zoom()
	var center := _display_center if _display_camera != null else _center
	var enabled: bool = ShadowLOD.active(zoom, _view_mode)
	var chunk_size: int = _world_model.config.chunk_size
	var center_chunk := Vector2i(floori(center.x / float(chunk_size)),
		floori(center.y / float(chunk_size)))
	if _world_light != null:
		# Прозрачность меняется даже без смены центрального чанка:
		# ранний выход ниже не должен блокировать плавный переход.
		var opacity: float = ShadowLOD.shadow_opacity_for_zoom(zoom, _view_mode)
		if _world_light.shadow_opacity != opacity:
			_world_light.shadow_opacity = opacity
			if _ground_material != null:
				_ground_material.set_shader_parameter("geometry_shadow_opacity", opacity)
		if _world_light.shadow_enabled != enabled:
			_world_light.shadow_enabled = enabled
	if _shadow_active == enabled and _shadow_center_chunk == center_chunk \
			and is_equal_approx(_last_shadow_zoom, zoom):
		return
	_shadow_active = enabled
	_shadow_center_chunk = center_chunk
	_last_shadow_zoom = zoom
	for coord in _active.keys():
		var near_ground: bool = ShadowLOD.chunk_casts(coord, center_chunk,
			zoom, _view_mode)
		var near_nature: bool = ShadowLOD.chunk_casts(coord, center_chunk,
			zoom, _view_mode, true)
		ShadowLOD.configure_chunk(_active[coord], near_ground, near_nature)


func _change_zoom(multiplier: float) -> void:
	var previous_lod := _detail_for_zoom(_camera.size) < NatureRenderer.SPARSE_GROUND_COVER_DETAIL
	_camera.size = clampf(_camera.size * multiplier, MIN_ZOOM, MAX_ZOOM)
	var next_lod := _detail_for_zoom(_camera.size) < NatureRenderer.SPARSE_GROUND_COVER_DETAIL
	_apply_visual_budget()
	_pan_delta = Vector2.ZERO
	_pan_pending = true
	_update_material_detail()
	# Пересобираем видимые модели только при смене уровня детализации.
	_refresh_visible(previous_lod != next_lod)


func _move_center(amount: Vector2) -> void:
	var previous := _center
	var target := _center + amount
	if _display_camera != null and not _benchmark_running:
		# Не даём запросу уйти далеко, если камера ждёт готовый кадр.
		target = _display_center + (target - _display_center).limit_length(
			STREAM_PREFETCH_PADDING * 0.75)
	_center = Vector2(
		clampf(target.x, 0.0, float(_world_model.config.width) - 0.001),
		clampf(target.y, 0.0, float(_world_model.config.height) - 0.001))
	var displacement := _center - previous
	if displacement != Vector2.ZERO:
		_pan_delta = displacement
		_pan_pending = true
	_update_camera()
	var next_chunk := Vector2i(floori(_center.x / float(_world_model.config.chunk_size)),
		floori(_center.y / float(_world_model.config.chunk_size)))
	# При точном отсечении новая область может появиться внутри чанка.
	# Подпуск в расчёте видимости страхует промежутки между обновлениями.
	var refresh_distance_squared := 4.0 if _display_camera != null else 1.0
	if next_chunk != _chunk_center or \
			_center.distance_squared_to(_visibility_center) >= refresh_distance_squared:
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
	_update_shadow_lod()
	var desired := _plan_camera_chunks(center_chunk)
	_apply_chunk_plan(desired, force)
	_last_visibility_us = Time.get_ticks_usec() - refresh_started
	_visibility_refreshes += 1


func _plan_camera_chunks(center_chunk: Vector2i) -> Dictionary:
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
	var target := {}
	var padding := STREAM_TARGET_PADDING
	if _display_camera != null:
		padding += STREAM_PREFETCH_PADDING
		radius += 1
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
						camera_position, right, _camera.size, aspect, padding):
					_visibility_fast_rejects += 1
					continue
				_visibility_precise_checks += 1
				var gap := ChunkVisibility.required_padding(bounds,
					_chunk_elevation_bounds(coord), camera_position,
					right, up, _camera.size, aspect)
				if gap > padding:
					continue
				if _display_camera != null and gap <= STREAM_TARGET_PADDING:
					target[coord] = true
			desired[coord] = true
	if _display_camera != null:
		# Во время суточного расчёта оставляем последний проверенный вид.
		_target_chunks = target
		_target_view_valid = cull
		desired.merge(_display_chunks)
	return desired


func _apply_chunk_plan(desired: Dictionary, force: bool) -> void:
	_wanted_chunks = desired
	for coord in _chunk_jobs:
		var job: Dictionary = _chunk_jobs[coord]
		if not desired.has(coord) or job["generation"] != _chunk_generation:
			job["worker"].cancel()
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
		# Камера больше не нуждается в коллизиях этой области.
		# Следующую синхронизацию проводим по изменённому набору.
		_collider_plan_dirty = true
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
				# У кешированного чанка физические формы были удалены.
				_collider_plan_dirty = true
	_pending.clear()
	for coord in desired:
		if not _chunk_jobs.has(coord) and (
				not _active.has(coord) or _rebuild_pending.has(coord)):
			_pending.append(coord)
	ChunkBuildQueue.prioritize(_pending, _center, _pan_delta,
		_world_model.config.chunk_size, _active, _target_chunks)


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
			_surface, _climate, _hydro, _fire,
			_pbr_shore_cache_enabled, _pbr_physical_cells_enabled)
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
			not item["worker"].is_cancelled() and
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
		var water_started := Time.get_ticks_usec()
		var water_mesh := WaterMesh.mesh_from_arrays(worker.water_arrays)
		var water_us: int = worker.water_prepare_us + Time.get_ticks_usec() - water_started
		_last_water_build_us += water_us
		_total_water_build_us += water_us
		_attach_chunk(coord, ground_mesh, water_mesh)
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
		_world_model, _surface, _view_mode, _climate, _hydro,
		_pbr_shore_cache_enabled, Callable(), _pbr_physical_cells_enabled)
	var prepared_us := Time.get_ticks_usec() - started
	started = Time.get_ticks_usec()
	var mesh := Chunk.mesh_from_arrays(arrays)
	var upload_us := Time.get_ticks_usec() - started
	_last_ground_build_us += prepared_us + upload_us
	_total_ground_build_us += prepared_us + upload_us
	_total_ground_prepare_us += prepared_us
	_total_ground_upload_us += upload_us
	_attach_chunk(coord, mesh)


func _attach_chunk(coord: Vector2i, ground_mesh: ArrayMesh,
		prepared_water: ArrayMesh = null) -> void:
	# Ни один воркер не трогает Node, ArrayMesh или RenderingServer.
	var old_node: Node3D = _active.get(coord)
	var node := Node3D.new()
	node.name = "Чанк_%d_%d" % [coord.x, coord.y]
	var ground := MeshInstance3D.new()
	ground.name = "Рельеф"
	ground.mesh = ground_mesh
	if _view_mode == 0:
		ground.material_override = _ground_material
	else:
		ground.material_override = _debug_ground_material
	ground.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	node.add_child(ground)
	var water_started := Time.get_ticks_usec()
	var water_mesh: ArrayMesh = prepared_water
	if water_mesh == null:
		water_mesh = WaterMesh.create_mesh(_world_model, _hydro, coord, _surface, _fire)
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
		var nature_started := Time.get_ticks_usec()
		node.add_child(NatureRenderer.create_chunk(_world_model, _nature, coord,
			_detail_for_zoom(_camera.size), _fire, _contact_shadow_direction()))
		_total_nature_attach_us += Time.get_ticks_usec() - nature_started
	# Новый чанк получает корректный бюджет теней до добавления в сцену.
	# При движении камеры существующие чанки перенастраиваются без пересборки.
	if _camera != null:
		ShadowLOD.configure_chunk(node,
			ShadowLOD.chunk_casts(coord, _shadow_center_chunk,
				_shadow_zoom(), _view_mode),
			ShadowLOD.chunk_casts(coord, _shadow_center_chunk,
				_shadow_zoom(), _view_mode, true))
	var scene_started := Time.get_ticks_usec()
	_terrain_holder.add_child(node)
	_total_scene_attach_us += Time.get_ticks_usec() - scene_started
	if old_node != null:
		old_node.queue_free()
	_active[coord] = node
	# Новому GPU-чанку нужны физические формы при близкой камере.
	_collider_plan_dirty = true
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
	# За невидимые чанки не платим кадровым бюджетом: при
	# возвращении камера построит их из актуального NatureRegistry.
	# Кеш инвалидируем сразу, иначе устаревший чанк мог вернуться
	# в кадр до того, как до него дошла очередь обновления.
	for chunk in chunks:
		_render_cache.discard(chunk)
		if _active.has(chunk) and _view_mode == 0:
			_nature_dirty[chunk] = true


func _refresh_nature_chunk(chunk: Vector2i) -> void:
	_render_cache.discard(chunk)
	if _view_mode != 0 or not _active.has(chunk):
		return
	var chunk_node: Node3D = _active[chunk]
	var previous: Node = chunk_node.get_node_or_null("Природные объекты")
	if previous != null:
		chunk_node.remove_child(previous)
		previous.queue_free()
	chunk_node.add_child(NatureRenderer.create_chunk(_world_model, _nature, chunk,
		_detail_for_zoom(_camera.size), _fire, _contact_shadow_direction()))
	# После обновления растений восстанавливаем тени без задержки кадра.
	if _camera != null:
		ShadowLOD.configure_chunk(chunk_node,
			ShadowLOD.chunk_casts(chunk, _shadow_center_chunk,
				_shadow_zoom(), _view_mode),
			ShadowLOD.chunk_casts(chunk, _shadow_center_chunk,
				_shadow_zoom(), _view_mode, true))
	var old_collisions: Node = chunk_node.get_node_or_null(
		NatureCollision.COLLISION_NAME)
	if old_collisions != null:
		chunk_node.remove_child(old_collisions)
		old_collisions.queue_free()
	if NatureCollision.near_camera(chunk, _chunk_center):
		chunk_node.add_child(NatureCollision.create_chunk(
			_world_model, _nature, chunk))


func _sync_nature_colliders() -> void:
	# В физическом сервере держим только препятствия возле камеры.
	# В обычном кадре с неподвижной камерой даже не обходим чанки.
	if _nature == null or _day_task_id >= 0 or _days_pending > 0:
		return
	if not _collider_plan_dirty and _collider_last_center == _chunk_center \
			and _collider_last_mode == _view_mode:
		_collider_idle_skips += 1
		return
	_collider_sweeps += 1
	_collider_last_center = _chunk_center
	_collider_last_mode = _view_mode

	# Лимит на создание физических тел действует при панораме и
	# холодном старте. Если близких чанков больше лимита, помним
	# незавершённую очередь и продолжаем её в следующем кадре.
	var created := 0
	var pending := false
	for chunk in _active.keys():
		var chunk_node: Node3D = _active[chunk]
		var current: Node = chunk_node.get_node_or_null(
			NatureCollision.COLLISION_NAME)
		var required: bool = _view_mode == 0 and \
			NatureCollision.near_camera(chunk, _chunk_center)
		if not required:
			if current != null:
				chunk_node.remove_child(current)
				current.queue_free()
			continue
		if current != null:
			continue
		if created >= NatureCollision.MAX_NEW_CHUNKS_PER_FRAME:
			pending = true
			continue
		var collision_started := Time.get_ticks_usec()
		chunk_node.add_child(NatureCollision.create_chunk(
			_world_model, _nature, chunk))
		_total_collider_attach_us += Time.get_ticks_usec() - collision_started
		created += 1
	_collider_chunks_created += created
	_collider_plan_dirty = pending


func _flush_nature_visuals() -> void:
	# Обновляем только видимые чанки, максимум два за кадр.
	# Невидимые записи можно удалить без пересоздания GPU-объектов:
	# свежую природу они получат при возвращении камеры.
	if _day_task_id >= 0 or _nature_dirty.is_empty():
		return
	var processed := 0
	var refresh_limit := VisualBudget.nature_refresh_limit(_mesh_budget_p95)
	for chunk in _nature_dirty.keys():
		if not _active.has(chunk) or _view_mode != 0:
			_render_cache.discard(chunk)
			_nature_dirty.erase(chunk)
			continue
		if processed >= refresh_limit:
			continue
		_refresh_nature_chunk(chunk)
		_nature_dirty.erase(chunk)
		processed += 1


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
	var winter: bool = _climate != null and \
		_climate.weather_at(cell).get("season") == "зима"
	var visual: Node3D = NatureFelling.make_visual(
		_world_model, previous, _detail_for_zoom(_camera.size), winter)
	if visual == null:
		return
	var chunk_node: Node3D = _active[chunk]
	chunk_node.add_child(visual)
	NatureFelling.animate(visual)



func _fire_demo_active() -> bool:
	# Законченное или неудавшееся испытание не блокирует
	# обычное управление камерой, дни и пользовательский сейв.
	return str(_fire_demo.get("stage", "")) in [
		"before", "running", "ignition_frame", "burning", "after", "restored"]


func _fire_demo_report(message: String) -> void:
	# Статус доступен в обычной панели, без входа в отладку.
	if _fire_demo_status != null:
		_fire_demo_status.text = message


func _fire_demo_fail(message: String) -> void:
	# Отказ после дождя, ошибки файла или неполного кадра
	# не выдаём за завершённое физическое испытание.
	_fire_demo["stage"] = "failed"
	_fire_demo_report("Испытание не завершено: " + message)
	_update_hud()


func _begin_fire_demo() -> void:
	# Мир, камера и реестр огня доступны только когда ни один
	# физический или мешевый воркер не читает общие модели.
	if _benchmark_running or _fire_demo_active() or _day_task_id >= 0 \
			or _days_pending > 0 or not _storage_request.is_empty() \
			or not _chunk_jobs.is_empty():
		_fire_demo_report("Дождитесь завершения расчёта и загрузки карты")
		return
	if _nature == null or _fire == null or _view_mode != 0:
		_fire_demo_report("Переключитесь на природную поверхность")
		return
	var tree: Dictionary = WorldFireDemo.choose_tree(
		_nature, _fire, _active.keys(), _center)
	if tree.is_empty():
		_fire_demo_report("В видимых чанках нет достаточно сухого дерева")
		return
	var cell: Vector2i = tree["cell"]
	_fire_demo = {"stage": "before", "cell": cell, "id": tree["id"],
		"day": _climate.day, "scorched_before": _fire.scorched_count()}
	_fire_demo_stable_frames = 0
	# До, после и после загрузки используют именно этот ракурс:
	# запрещаем перемещение, пока сценарий не завершён.
	_center = _world_model.config.clamp_point(
		Vector2(cell) + Vector2(0.5, 0.5))
	_camera.size = 42.0
	_pan_delta = Vector2.ZERO
	_pan_pending = false
	_update_camera()
	_update_material_detail()
	_refresh_visible(true)
	_fire_demo_report("Подготавливаем исходный кадр у дерева %s" % cell)


func _fire_demo_ready() -> bool:
	# Снимки не делаем во время смены физической модели, а также
	# когда кадр содержит старые или ещё не загруженные чанки.
	return _day_task_id < 0 and _days_pending == 0 \
		and _chunk_jobs.is_empty() and _pending.is_empty() \
		and _rebuild_pending.is_empty() and not _active.is_empty() \
		and _active.size() >= _wanted_chunks.size() \
		and (_loading_layer == null or not _loading_layer.visible)


func _fire_demo_picture(path: String) -> bool:
	# Получаем фактический текущий viewport Godot, а не рисунок
	# на основе данных теста. Рендер должен быть готов заранее.
	var image: Image = get_viewport().get_texture().get_image()
	if image == null or image.get_width() < 64 or image.get_height() < 64:
		return false
	return image.save_png(path) == OK


func _advance_fire_demo() -> void:
	var stage := str(_fire_demo.get("stage", ""))
	if stage not in ["before", "ignition_frame", "after", "restored"]:
		return
	if not _fire_demo_ready():
		_fire_demo_stable_frames = 0
		return
	# Два кадра после полной загрузки требуются для реального
	# обновления GPU: не фотографируем предыдущую геометрию.
	_fire_demo_stable_frames += 1
	if _fire_demo_stable_frames < 3:
		return
	_fire_demo_stable_frames = 0
	if stage == "before":
		var initial: Dictionary = WorldSave.capture(_storage_models())
		if initial.is_empty() or not _fire_demo_picture(WorldFireDemo.BEFORE_PNG):
			_fire_demo_fail("Не удалось сохранить исходную физику или PNG")
			return
		_fire_demo["initial"] = initial
		_ensure_day_runner()
		_day_runner.test_fire_cell = _fire_demo["cell"]
		_fire_demo["stage"] = "running"
		# Только после настоящего кадра «до» запускаем один
		# обычный день через WorkerThreadPool, не имитируем огонь.
		_days_pending = 1
		_fire_demo_report("Кадр «до» записан · запускаем физический пожар")
	elif stage == "ignition_frame":
		# Само возгорание ещё не расходует топливо и не обжигает
		# грунт: сохраняем отдельный кадр с видимым пламенем,
		# затем считаем ещё один настоящий день для последствий.
		if not _fire_demo_picture(WorldFireDemo.IGNITION_PNG):
			_fire_demo_fail("Не удалось снять кадр реального возгорания")
			return
		_fire_demo["stage"] = "burning"
		_days_pending = 1
		_fire_demo_report("Возгорание снято · рассчитываем выгорание и следы почвы")
	elif stage == "after":
		var result: Dictionary = WorldSave.capture(_storage_models())
		if result.is_empty() or result["fire"] == _fire_demo["initial"]["fire"] \
				or _fire.scorched_count() <= int(_fire_demo["scorched_before"]) \
				or not _fire_demo_picture(WorldFireDemo.AFTER_PNG):
			_fire_demo_fail("Отсутствуют подтверждённые последствия или PNG")
			return
		# Отдельное сохранение не перезаписывает файл игрока.
		if not WorldSave.write_file(_storage_models(), WorldFireDemo.SAVE_PATH):
			_fire_demo_fail("Не удалось записать испытание в отдельный файл")
			return
		var restored: Dictionary = WorldSave.read_file(WorldFireDemo.SAVE_PATH)
		var actual: Dictionary = WorldSave.capture(restored) \
			if not restored.is_empty() else {}
		if not WorldFireDemo.physical_equal(result, actual):
			_fire_demo_fail("WorldSave не восстановил всё физическое состояние")
			return
		_fire_demo["after_snapshot"] = result
		# Все воркеры уже завершены, поэтому установка новых
		# реестров и сброс старых GPU-чанков безопасны.
		_install_loaded_world(restored)
		_fire_demo["stage"] = "restored"
		_fire_demo_report("Кадр «после» записан · проверяем вид после загрузки")
	elif stage == "restored":
		var saved: Dictionary = _fire_demo["after_snapshot"]
		if not WorldFireDemo.physical_equal(
				saved, WorldSave.capture(_storage_models())) \
				or not _fire_demo_picture(WorldFireDemo.RESTORED_PNG):
			_fire_demo_fail("Повторная проверка восстановленного мира не прошла")
			return
		_fire_demo["stage"] = "complete"
		# Игрок получает три настоящих кадра и отдельный JSON.
		_fire_demo_report(
			"Готово: пожар, выгорание и WorldSave проверены. Файлы " +
			"fire-demo-before.png, fire-demo-ignition.png, " +
			"fire-demo-after.png, fire-demo-restored.png и fire-demo-world.json")
		_update_hud()


func _debug_test_fire() -> void:
	# Испытание выбирает настоящий объект; сухость в следующем
	# физическом дне проверяется тем же FireRegistry, что у молний.
	if _nature == null or _fire == null or _benchmark_running \
			or _day_task_id >= 0 or _days_pending > 0 \
			or _view_mode != 0 or not _storage_request.is_empty():
		_storage_status = "Испытание огня доступно после расчёта дня"
		_update_hud()
		return
	var selected := Vector2i(-1, -1)
	var nearest := INF
	for chunk in _active.keys():
		for item in _nature.objects_in_chunk(chunk):
			if item["kind"] != "дерево" or item["state"] != "целое":
				continue
			var cell := Vector2i(int(item["x"]), int(item["y"]))
			var distance := (Vector2(cell) + Vector2(0.5, 0.5)) \
				.distance_squared_to(_center)
			if distance < nearest:
				selected = cell
				nearest = distance
	if selected.x < 0:
		_storage_status = "В видимой области нет дерева для испытания"
		_update_hud()
		return
	_ensure_day_runner()
	_day_runner.test_fire_cell = selected
	_queue_days(1)
	_storage_status = "Пробное возгорание ждёт следующего дня · %s" % selected
	_update_hud()


func _debug_test_storm() -> void:
	# Старое испытание шторма сохраняет прежний сценарий и вероятность.
	_debug_test_wind_event("шторм")


func _debug_test_squall() -> void:
	# Новый отдельный сценарий запускает локальный шквал на карте.
	_debug_test_wind_event("шквал")


func _debug_test_hurricane() -> void:
	# Массовое падение деревьев и широкая зона ущерба в обычном мире.
	_debug_test_wind_event("ураган")


func _debug_test_shrub_damage() -> void:
	# Выбираем живой куст, но ущерб наносит только суточная физика.
	_debug_test_wind_event("ураган", "кустарник")


func _debug_test_tornado() -> void:
	# Физический вихрь оставляет узкую трассу, а не круглый урон.
	_debug_test_wind_event("смерч")


func _debug_test_dust_storm() -> void:
	# Находим именно сухую открытую поверхность в загруженных
	# чанках; деревья и камни не подменяют источник пыли.
	if _nature == null or _view_mode != 0 or _benchmark_running \
			or _day_task_id >= 0 or _days_pending > 0 \
			or not _storage_request.is_empty():
		_storage_status = "Пробная пыльная буря доступна после расчёта дня"
		_update_hud()
		return
	var selected := Vector2i(-1, -1)
	var nearest := INF
	for chunk in _active.keys():
		var rect: Rect2i = _world_model.config.chunk_rect(chunk)
		for y in range(rect.position.y, rect.end.y):
			for x in range(rect.position.x, rect.end.x):
				var cell := Vector2i(x, y)
				if not _natural_disasters.dust_source_ready(cell):
					continue
				# Предпочитаем тепло и мало осадков — выбранный
				# участок с меньшей вероятностью намокнет за сутки.
				var index: int = _hydro.cell_index(cell)
				if _climate.temperature_at_index(index) < 5.0 \
						or _climate.precipitation_at_index(index) > 0.25:
					continue
				var wind: Vector2 = _climate.wind_direction_at_index(
					_hydro.cell_index(cell))
				var downwind := cell + Vector2i(
					roundi(wind.x * 3.0), roundi(wind.y * 3.0))
				if not _world_model.config.contains_cell(downwind) \
						or _hydro.has_water(_hydro.cell_index(downwind)):
					continue
				var distance := (Vector2(cell) + Vector2(0.5, 0.5)) \
					.distance_squared_to(_center)
				if distance < nearest:
					nearest = distance
					selected = cell
	if selected.x < 0:
		_storage_status = "В видимой области нет сухого рыхлого грунта для бури"
		_update_hud()
		return
	# Визуал появится только после настоящего переноса земли в
	# следующем суточном расчёте, а не непосредственно от кнопки.
	_ensure_day_runner()
	_day_runner.test_dust_cell = selected
	_queue_days(1)
	_storage_status = "Пробная пыльная буря: ждём расчёта · %s" % selected
	_update_hud()


func _debug_test_wind_event(kind: String,
		target_kind: String = "дерево") -> void:
	# Диагностика использует тот же суточный физический цикл, что
	# и естественное событие; GUI не меняет ресурс дерева напрямую.
	if _nature == null or _view_mode != 0 or _benchmark_running \
			or _day_task_id >= 0 or _days_pending > 0 \
			or not _storage_request.is_empty():
		_storage_status = "Испытание ветра доступно после расчёта дня"
		return
	var selected := Vector2i(-1, -1)
	var distance := INF
	var next_day: int = _climate.day + 1
	# Для каждого типа выбираем дерево с гарантированным падением
	# при интенсивности 1.0, без обхода всей карты вне камеры.
	var probability_limit := 0.99 if kind == "смерч" else (
		0.98 if kind == "ураган" else (0.95 if kind == "шквал" else 0.85))
	for chunk in _active.keys():
		for item in _nature.objects_in_chunk(chunk):
			if item["kind"] != target_kind or item["state"] != "целое":
				continue
			var cell := Vector2i(int(item["x"]), int(item["y"]))
			var point := Vector2(cell) + Vector2(0.5, 0.5)
			# Выбираем дерево с воспроизводимым падением по seed и
			# приближаем эпицентр к камере для видимого результата.
			if point.distance_to(_center) > _camera.size * 0.48:
				continue
			if target_kind == "дерево" and Terrain.hash2(cell.x, cell.y,
					_world_model.config.world_seed +
					next_day * 31 + 3173) >= probability_limit:
				continue
			var square := point.distance_squared_to(_center)
			if square < distance:
				distance = square
				selected = cell
	if selected.x < 0:
		_storage_status = "В видимой области нет %s для испытания" % (
			"живого кустарника" if target_kind == "кустарник" else "дерева")
		_update_hud()
		return
	_ensure_day_runner()
	if target_kind == "кустарник":
		# Специальный маркер позволит показать честный результат,
		# а не количество поваленных деревьев у соседнего эпицентра.
		_day_runner.test_shrub_cell = selected
	elif kind == "шквал":
		_day_runner.test_squall_cell = selected
	elif kind == "ураган":
		_day_runner.test_hurricane_cell = selected
	elif kind == "смерч":
		_day_runner.test_tornado_cell = selected
	else:
		_day_runner.test_storm_cell = selected
	# Физика действует ровно один день: изменения можно сохранить.
	_queue_days(1)
	_storage_status = "Пробный %s ожидает расчёта · %s" % [kind, selected]
	_update_hud()


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
			var tree_position := Vector2(float(item["x"]) + 0.5,
				float(item["y"]) + 0.5)
			var length: float = tree_position.distance_squared_to(_center)
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
		_nature, _fire)


func _flush_world_changes() -> void:
	if _day_task_id >= 0:
		return
	_ensure_day_runner()
	var changed: bool = _day_runner.synchronize_world()
	_terrain_dirty.clear()
	_last_synchronized_world_revision = _world_model.revision
	if changed and _days_pending == 0:
		_refresh_visible(true)



func _begin_first_economy() -> void:
	# Нельзя выбирать дерево, когда фоновая физика меняет его запасы.
	if _economy == null or _day_task_id >= 0 or _days_pending > 0 \
			or _benchmark_running or _fire_demo_active():
		_storage_status = "Хозяйство доступно после завершения расчёта дня"
		_update_hud()
		return
	if _economy.start():
		_storage_status = "Заказ принят: добыча, доставка, обжиг, постройка"
	else:
		_storage_status = _economy.last_event
	_sync_first_economy_visual()
	_update_hud()


func _sync_first_economy_visual() -> void:
	# У работы нет Node3D на каждую единицу груза: отображаем лишь
	# одного перевозчика и завершённый объект, физика живёт в реестре.
	if _economy_visual == null:
		_economy_visual = Node3D.new()
		_economy_visual.name = "Хозяйство · первый рабочий цикл"
		add_child(_economy_visual)
	for child in _economy_visual.get_children():
		child.queue_free()
	if _economy == null or _economy.phase == "ожидание":
		return
	var point: Vector2i = _economy.worker
	if _world_model.config.contains_cell(point):
		var carrier := MeshInstance3D.new()
		carrier.name = "Рабочий и груз"
		var sphere := SphereMesh.new()
		sphere.radius = 0.24
		sphere.height = 0.48
		carrier.mesh = sphere
		var carrier_mat := StandardMaterial3D.new()
		carrier_mat.albedo_color = Color(0.89, 0.72, 0.30)
		carrier.material_override = carrier_mat
		var center := Vector2(point) + Vector2(0.5, 0.5)
		carrier.position = _world_model.config.to_scene(
			center, _world_model.height_at(center) + 0.40)
		_economy_visual.add_child(carrier)
	if not _economy.built:
		return
	var site_cell: Vector2i = _economy.site
	var site_center := Vector2(site_cell) + Vector2(0.5, 0.5)
	var building := MeshInstance3D.new()
	building.name = "Кирпичная мастерская"
	var box := BoxMesh.new()
	box.size = Vector3(1.25, 1.15, 1.25)
	building.mesh = box
	var brick := StandardMaterial3D.new()
	brick.albedo_color = Color(0.64, 0.33, 0.22)
	building.material_override = brick
	building.position = _world_model.config.to_scene(
		site_center, _world_model.height_at(site_center) + 0.575)
	_economy_visual.add_child(building)



func _industry_action_allowed() -> bool:
	# Природные записи меняются только между фоновыми сутками;
	# во время перемотки или бенчмарка действия блокируются.
	return _industry != null and _industry.site.x >= 0 \
		and _day_task_id < 0 and _days_pending == 0 \
		and not _benchmark_running and not _fire_demo_active()


func _industry_order() -> void:
	# Перевозчик выбирает ближайшую достижимую залежь, а древесину
	# забирает из исходного реестра поваленных деревьев.
	if not _industry_action_allowed():
		_storage_status = "Сначала завершите кирпичную мастерскую"
	elif _industry_kind == "древесина":
		if not _industry.order_wood(3):
			_storage_status = _industry.last_event
	else:
		if not _industry.order_deposit(_industry_kind, 3):
			_storage_status = _industry.last_event
	_update_hud()


func _industry_produce() -> void:
	# Необеспеченные рецепты не меняют запасы; статус поясняет
	# необходимость доставить сырьё или повысить технологию.
	if not _industry_action_allowed():
		_storage_status = "Хозяйственный участок ещё не активен"
	elif not _industry.produce(_industry_recipe):
		_storage_status = "Недостаточно сырья или технологии: " + _industry_recipe
	_update_hud()


func _industry_build() -> void:
	# Потребитель получает лишь реально изготовленную продукцию;
	# новый объект не создаёт металлы, камень или древесину.
	if not _industry_action_allowed():
		_storage_status = "Хозяйственный участок ещё не активен"
	elif not _industry.construct(_industry_building):
		_storage_status = "Не хватает продукции: " + _industry_building
	_update_hud()


func _industry_research() -> void:
	# Стоимость технологии списывается со склада; прямой выбор
	# следующего уровня без материалов не предусмотрен.
	if not _industry_action_allowed():
		_storage_status = "Хозяйственный участок ещё не активен"
	elif not _industry.research_next():
		_storage_status = "Для развития нужны изделия текущего уровня"
	_update_hud()



func _animal_actions_allowed() -> bool:
	# Нельзя охотиться или отлавливать животных во время фонового
	# изменения популяций, иначе возникнет гонка между потоками.
	return _harvest != null and _domestic != null \
		and _harvest.site.x >= 0 and _domestic.site.x >= 0 \
		and _day_task_id < 0 and _days_pending == 0 \
		and not _benchmark_running and not _fire_demo_active()


func _find_animal_region(species: String, predators: bool) -> Vector2i:
	# Выбираем ближайшую по реальному маршруту территорию
	# с живыми животными, а не просто ближайшую по координатам.
	var best := Vector2i(-1, -1)
	var min_steps := 100000000
	var size: Vector2i = _world_model.config.region_count()
	for y in range(size.y):
		for x in range(size.x):
			var region := Vector2i(x, y)
			var available: int = _food_web.count_at(region, species) \
				if predators else _wildlife.population_at(region, species)
			if available < 1:
				continue
			var route: Dictionary = WildlifeAccess.entry(
				_world_model, _hydro, _surface, _harvest.site, region)
			if route.is_empty() or int(route["steps"]) >= min_steps:
				continue
			best = region
			min_steps = int(route["steps"])
	return best


func _order_hunting() -> void:
	# Туша появится только после вычета дикого животного и
	# обратного пути охотника до хозяйственной площадки.
	if not _animal_actions_allowed():
		_storage_status = "Сначала завершите мастерскую и расчёт дня"
	else:
		var region := _find_animal_region(_hunt_species, false)
		if not _harvest.order_hunt(region, _hunt_species, 1):
			_storage_status = "Не найден доступный живой источник: " + _hunt_species
	_update_hud()


func _butcher_animal() -> void:
	# Разделываем только тушу из завершённого охотничьего рейса.
	if not _animal_actions_allowed():
		return
	var carcasses: Dictionary = _harvest.summary()["carcasses"]
	for species in carcasses:
		if _harvest.butcher(str(species), 1):
			break
	_update_hud()


func _consume_animal_food() -> void:
	# Потребление уменьшает реальный склад, не выдавая новую еду.
	if _animal_actions_allowed():
		_harvest.consume_food(1)
	_update_hud()


func _craft_animal_gear(kind: String) -> void:
	# Используем физические продукты из доставленных туш;
	# готовое снаряжение затем меняет поведение охотников.
	if not _animal_actions_allowed():
		_storage_status = "Нужен действующий охотничий участок"
	elif not _harvest.craft_tool(kind):
		_storage_status = "Не хватает материалов или предмет уже готов: " + kind
	_update_hud()


func _order_capture() -> void:
	# Отлов не создаёт домашнего животного мгновенно: сперва
	# доставляются дикие основатели, затем требуются поколения.
	if not _animal_actions_allowed():
		_storage_status = "Для отлова нужен действующий природный участок"
		_update_hud()
		return
	var rule: Dictionary = WildlifeDomestic.LINEAGES[_capture_species]
	var region := _find_animal_region(
		str(rule["ancestor"]), bool(rule["predator"]))
	var source_count: int = _food_web.count_at(
		region, str(rule["ancestor"])) if bool(rule["predator"]) \
		else _wildlife.population_at(region, str(rule["ancestor"]))
	var amount := mini(2, source_count)
	if not _domestic.order_capture(region, _capture_species, amount):
		_storage_status = "Нет доступных диких предков: " + _capture_species
	_update_hud()


func _storage_models() -> Dictionary:
	return {
		"world": _world_model, "hydro": _hydro,
		"surface": _surface, "climate": _climate,
		"weather": _weather_events, "natural": _natural_processes,
		"disasters": _natural_disasters, "nature": _nature,
		"resources": _resources, "economy": _economy,
		"industry": _industry, "wildlife": _wildlife,
		"food_web": _food_web, "harvest": _harvest,
		"domestic": _domestic, "fire": _fire
	}


func _request_storage(action: String) -> void:
	if _benchmark_running or _fire_demo_active() \
			or action not in ["save", "load"]:
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
	_resources = models["resources"]
	_economy = models["economy"]
	_industry = models["industry"]
	_wildlife = models["wildlife"]
	_food_web = models["food_web"]
	_harvest = models["harvest"]
	_domestic = models["domestic"]
	if _wildlife_visuals != null:
		_wildlife_visuals.configure(_world_model, _hydro, _surface,
			_wildlife, _food_web, _domestic)
	_fire = models["fire"]
	# В новом сохранении или seed видовые точки могут сместиться:
	# пересчитываем маршрут только при следующем выборе игрока.
	_showcase_views.clear()
	_showcase_index = -1
	if _main_panel != null:
		_main_panel.visible = true
	if _showcase_overlay != null:
		_showcase_overlay.visible = false
	if _showcase_text != null:
		_showcase_text.text = "Лес · река · горы · побережье"
	# Сохранённый реестр — единственный источник будущего звука.
	# Не продолжаем старый треск и свет из прежней сцены.
	if _fire_presentation != null:
		_fire_presentation.clear_visuals()
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
	# При загрузке история физических ударов остаётся в WeatherEvents,
	# но визуальные кадры и гром прошлого дня не воспроизводятся.
	if _atmosphere != null:
		_atmosphere.clear_after_load(_weather_events.last_day)
	_weather_status = "Молний всего %d" % _weather_events.total_strikes
	_disaster_status = "Стихийных событий всего %d" % _natural_disasters.total_events
	_process_status = "Природные процессы восстановлены до дня %d" % \
		_natural_processes.last_day
	_last_event = "Мир успешно загружен"
	_weather_fx_cooldown = 0.0
	# После загрузки климат даст новую цель: не переносим свет старого мира.
	_weather_light_target.clear()
	_weather_light_current.clear()
	_center = _world_model.config.clamp_point(_center)
	_update_camera()
	_sync_first_economy_visual()
	for chunk in _active.keys():
		_active[chunk].queue_free()
	_active.clear()
	_collider_plan_dirty = true
	_pending.clear()
	_wanted_chunks.clear()
	_display_chunks.clear()
	_target_view_valid = false
	if _loading_layer != null:
		_loading_label.text = "Собираем вид карты"
		_loading_layer.show()
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
	if _startup_task_id >= 0:
		WorkerThreadPool.wait_for_task_completion(_startup_task_id)
		_startup_task_id = -1
	_wait_chunk_jobs()
	if _day_task_id >= 0:
		WorkerThreadPool.wait_for_task_completion(_day_task_id)
		_day_task_id = -1


func _apply_landscape_event(kind: String) -> void:
	if _day_task_id >= 0 or _benchmark_running:
		return
	_wait_chunk_jobs()
	var result: Dictionary = _landscape_events.apply(kind, _center, 18.0, 3.0)
	if not result.is_empty() and _nature != null and _nature.generated \
			and kind in ["оползень", "обвал", "кратер", "поднятие", "просадка"]:
		# Ручное испытание воздействует на те же физические объекты,
		# что и суточные бедствия. Рендер и коллизии перечитают высоты
		# после синхронизации, не создавая вторых копий камней и леса.
		_nature.apply_landscape_impact(
			kind, _center, 18.0, 1.0, _climate.day)
	_last_event = "%s: %d вершин" % [kind, result["vertices"]] \
		if not result.is_empty() else "%s: нет подходящего участка" % kind
	_flush_world_changes()
	if not result.is_empty() and kind in [
			"оползень", "обвал", "кратер", "поднятие", "просадка"]:
		# След остаётся в физическом Surface после перестройки земли
		# и переживает уход камеры. Цвет почвы перечитываем из новой
		# ревизии, не меняя геометрию повторно.
		if _surface.register_geological_scar(kind, _center, 18.0, 1.0):
			_refresh_visible(true)
	_update_hud()


func _queue_days(number: int) -> void:
	if _benchmark_running or _fire_demo_active():
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
	# Рабочая бригада использует только окончательное состояние природы
	# после фонового расчёта, не создавая гонку с WorkerThreadPool.
	if _economy != null:
		_economy.advance_day(_last_completed_day)
		_sync_first_economy_visual()
	# Второй участок появляется только после строительства первой
	# мастерской: до этого он не является источником материалов.
	if _industry != null and _economy != null:
		if _economy.built and _industry.site.x < 0:
			_industry.activate(_economy.site)
		_industry.advance_day(_last_completed_day)
	# Популяции пересчитываются после полной природной физики суток:
	# они получают фактический снег, паводки и состояние растительности.
	if _wildlife != null and _wildlife.generated:
		_wildlife.advance_day(_last_completed_day)
	# Пищевые отношения и реакция на настоящие бедствия происходят
	# после размножения и миграции травоядных в этом же дне.
	if _food_web != null and _food_web.generated:
		_food_web.advance_day(_last_completed_day, result["hazards"])
	# Только законченная физика суток может запустить бегство
	# видимых моделей. Это графическая реакция без повторного
	# пересчёта численности и без запуска фальшивой охоты.
	if _wildlife_visuals != null and _day_task_id < 0:
		_wildlife_visuals.react_hazards(result["hazards"])
	# Отлов и охота обновляются лишь после природного дня и охоты
	# хищников. При постройке цеха животных не выдаём.
	if _economy != null and _economy.built \
			and _wildlife != null and _wildlife.generated \
			and _food_web != null and _food_web.generated:
		if _harvest != null and _harvest.site.x < 0:
			_harvest.activate(_economy.site)
		if _domestic != null and _domestic.site.x < 0:
			_domestic.activate(_economy.site)
	if _harvest != null:
		_harvest.advance_day(_last_completed_day)
	if _domestic != null:
		_domestic.advance_day(_last_completed_day)
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
		_weather_status = "Молний сегодня %d · всего %d · удар %s" % [
			strikes.size(), _weather_events.total_strikes, hit]
		# И при быстром ходе календаря, и вне поля зрения
		# физический удар существует, но GPU/звук не проигрываем.
		var visible_camera := _display_center if _display_camera != null else _center
		var visible_zoom: float = _display_camera.size \
			if _display_camera != null else _camera.size
		var allow_fx := _view_mode == 0 and _days_pending <= 1
		if _atmosphere != null:
			# Единственный путь к графике разряда: координирующий узел.
			# Не включаем старый дополнительный свет для первого
			# удара — он мог находиться далеко от видимой камеры.
			_atmosphere.show_lightning(strikes, _world_model,
				visible_camera, visible_zoom, int(result["day"]), allow_fx)
	var fire_events: Array[Dictionary] = result.get("fire_events", [])
	# Не верим одной команде теста: нужны реальные события
	# FireRegistry после завершения фонового физического дня.
	if str(_fire_demo.get("stage", "")) == "running":
		var target: Vector2i = _fire_demo["cell"]
		if WorldFireDemo.ignition_confirmed(fire_events, target):
			_fire_demo["stage"] = "ignition_frame"
			_fire_demo_stable_frames = 0
			_fire_demo_report("Пожар подтверждён · снимаем пламя, затем следы")
		else:
			_fire_demo_fail("Дерево не загорелось: изменились влажность или условия дня")
	elif str(_fire_demo.get("stage", "")) == "burning":
		# Второй день не считаем успехом, пока настоящий огонь
		# не повредил землю. Просто появившаяся FX-анимация
		# не является долговременным последствием пожара.
		if _fire.scorched_count() > int(_fire_demo["scorched_before"]):
			_fire_demo["stage"] = "after"
			_fire_demo_stable_frames = 0
			_fire_demo_report("Грунт обожжён · снимаем последствия и сохраняем")
		else:
			_fire_demo_fail("Пожар потух без обжига грунта; условия были слишком влажными")
	if not fire_events.is_empty():
		var fire_last: Dictionary = fire_events[fire_events.size() - 1]
		_storage_status = "Огонь: %s · %s · очагов %d" % [
			fire_last["kind"], fire_last["cell"],
			int(result.get("fires_active", 0))]
	var event: Dictionary = result["erosion"]
	if not event.is_empty():
		_process_status = "%s, день %d: %s" % [
			event["process"], event["day"], event["cell"]]
	# Создаём эффекты только на главном потоке после фоновой физики.
	# Ограничиваем число анимаций и не проигрываем 96 прошлых дней.
	var falls: Array = result.get("windfalls", [])
	var animated := 0
	if _view_mode == 0 and _days_pending <= 1:
		for entry in falls:
			if animated >= MAX_STORM_FALL_ANIMATIONS:
				break
			var before: Dictionary = entry["before"]
			var cell := Vector2i(int(before["x"]), int(before["y"]))
			var chunk: Vector2i = _world_model.config.chunk_of(cell)
			if not _active.has(chunk):
				continue
			_refresh_nature_chunk(chunk)
			var winter: bool = _climate.weather_at(cell).get("season") == "зима"
			var visual: Node3D = NatureFelling.make_visual(
				_world_model, before, _detail_for_zoom(_camera.size),
				winter, int(entry["fall_angle_deg"]))
			if visual == null:
				continue
			_active[chunk].add_child(visual)
			NatureFelling.animate(visual)
			animated += 1
	var hazards: Array[Dictionary] = result["hazards"]
	for hazard in hazards:
		var wind_kind := str(hazard.get("kind", ""))
		if wind_kind not in [
				"шторм", "шквал", "ураган", "смерч", "пыльная буря"] \
				or _weather_fx == null or _view_mode != 0 \
				or _days_pending > 1:
			continue
		var storm_cell: Vector2i = hazard["cell"]
		if (Vector2(storm_cell) + Vector2(0.5, 0.5)).distance_to(_center) \
				> _camera.size * 0.65:
			continue
		var direction: Vector2 = _climate.wind_direction_at_index(
			_hydro.cell_index(storm_cell))
		if _atmosphere != null:
			_atmosphere.show_hazard(hazard, direction, _world_model)
	if bool(result.get("dust_test_failed", false)):
		# Фактический снег и дождь имеют приоритет над кнопкой
		# испытания; пользователь видит, почему грунт не перенесён.
		_storage_status = "Пыльная буря отменена: грунт намок или покрыт снегом"
	if not hazards.is_empty():
		var latest: Dictionary = hazards[hazards.size() - 1]
		_disaster_status = "%s · день %d · %s · интенсивность %.0f%%" % [
			latest["kind"], latest["day"], latest["cell"],
			float(latest["severity"]) * 100.0]
		if latest.get("source", "") == "диагностика":
			if str(latest.get("target", "")) == "кустарник":
				_storage_status = "Пробный порыв по кустарнику: физический расчёт завершён"
			elif str(latest["kind"]) == "пыльная буря":
				_storage_status = "Пыльная буря: перенесено %.3f грунта" % \
					float(latest.get("sediment_volume", 0.0))
			else:
				_storage_status = "Пробный %s: повалено %d деревьев" % [
					str(latest["kind"]), falls.size()]


func _cycle_view() -> void:
	if _benchmark_running:
		return
	_view_mode = (_view_mode + 1) % 8
	_weather_fx_cooldown = 0.0
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
	_display_chunks.clear()
	_target_view_valid = false
	if _loading_layer != null:
		_loading_label.text = "Собираем вид карты"
		_loading_layer.show()
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




func _run_relief_benchmark() -> void:
	# Отдельный маршрут R6 доступен непосредственно в игровом HUD
	# на ПК и Android. Не смешиваем измерения с фоновыми сутками
	# и не допускаем повторного запуска, пока идут замеры.
	if _benchmark_running:
		return
	if _days_pending > 0 or _day_task_id >= 0 or not _storage_request.is_empty():
		_benchmark_status = "R6: дождитесь окончания расчёта и сохранения"
		_update_hud()
		return
	_benchmark_running = true
	_benchmark_status = "R6: два одинаковых маршрута камеры, 740 кадров"
	_update_hud()
	var saved_center := _center
	var saved_zoom := _camera.size
	var report: Dictionary = await BenchmarkRunner.new().run_relief(self)

	# Отчёт сохраняется в пользовательский путь платформы, а его
	# полный JSON копируется, чтобы можно было прислать результаты
	# с телефона без доступа к файловому менеджеру Godot.
	var path := "user://world-relief-r6-device.json"
	var file := FileAccess.open(path, FileAccess.WRITE)
	var saved := file != null
	if saved:
		file.store_string(JSON.stringify(report, "\t") + "\n")
		file.close()
	if DisplayServer.get_name() != "headless":
		DisplayServer.clipboard_set(JSON.stringify(report))
	var passes: Array = report["passes"]
	var initial: Dictionary = passes[0]["summary"]
	var current: Dictionary = passes[1]["summary"]
	_benchmark_status = "R6: p95 %.1f → %.1f мс; физика %s. %s" % [
		float(initial["interval_ms_p95"]),
		float(current["interval_ms_p95"]),
		"без изменений" if report["physics_unchanged"] else "ИЗМЕНИЛАСЬ",
		"JSON сохранён и скопирован" if saved
		else "JSON скопирован; запись не удалась"
	]
	# После теста восстанавливаем исходный вид камеры. Повторная
	# синхронизация затрагивает только графические чанки, не модель.
	_center = saved_center
	_camera.size = saved_zoom
	_update_material_detail()
	_update_camera()
	_refresh_visible(false)
	_benchmark_running = false
	_update_hud()


func _run_landscape_benchmark() -> void:
	# Протокол RF4 работает только в живой сцене, без фоновых
	# расчётов дней и сохранений. Во время замера ввод отключён,
	# а после него результат остаётся в пользовательском JSON.
	if _benchmark_running:
		return
	if _days_pending > 0 or _day_task_id >= 0 or not _storage_request.is_empty():
		_benchmark_status = "Сначала завершите расчёт дней и сохранение"
		_update_hud()
		return
	_benchmark_running = true
	_benchmark_status = "RF4: три физических события и перестройка мешей"
	_update_hud()
	var report: Dictionary = await BenchmarkRunner.new().run_landscape(self)
	var path := "user://world-landscape-11-7-rf4-device.json"
	var file := FileAccess.open(path, FileAccess.WRITE)
	var saved := file != null
	if saved:
		file.store_string(JSON.stringify(report, "\t") + "\n")
		file.close()
	if DisplayServer.get_name() != "headless":
		DisplayServer.clipboard_set(JSON.stringify(report))
	var events: Array = report["events"]
	var completed := 0
	for event in events:
		if event.get("applied", false) and not event.get("queue_timeout", true):
			completed += 1
	_benchmark_status = "RF4: %d/3 перестроек. %s" % [
		completed, "JSON сохранён и скопирован: " + path
		if saved else "JSON скопирован; запись файла не удалась"]
	_benchmark_running = false
	_update_hud()


func _update_hud() -> void:
	if _summary == null:
		return
	if _animal_status != null and _harvest != null and _domestic != null:
		var hunt: Dictionary = _harvest.summary()
		var farm: Dictionary = _domestic.summary()
		_animal_status.text = "Охота: %s · туши: %s · продукты: %s\nПредки и потомство: %s" % [
			str(hunt["event"]), JSON.stringify(hunt["carcasses"]),
			JSON.stringify(hunt["products"]), JSON.stringify(farm["herds"])]
		_animal_status.text += "\nСнаряжение: " + JSON.stringify(hunt["equipment"])
	if _wildlife_status != null and _wildlife != null:
		var fauna: Dictionary = _wildlife.summary()
		_wildlife_status.text = "Дикие животные · %s · события %s" % [
			JSON.stringify(fauna["population"]), JSON.stringify(fauna["events"])]
		if _wildlife_visuals != null:
			var visuals: Dictionary = _wildlife_visuals.stats()
			_wildlife_status.text += " · реальные модели %d/%d; видимых %d/%d" % [
				int(visuals["installed"]), int(visuals["catalog"]),
				int(visuals["visible"]), int(visuals["limit"])]
		if _food_web != null:
			var predators: Dictionary = _food_web.summary()
			_wildlife_status.text += " · хищники: %d волков, %d лис; %s" % [
				int(predators["wolf"]), int(predators["fox"]),
				JSON.stringify(predators["events"])]
	if _industry_status != null and _industry != null:
		if _industry.site.x < 0:
			_industry_status.text = "Склад: нужен первый кирпичный цех"
		else:
			var warehouse: Dictionary = _industry.state()
			_industry_status.text = "Технология %d · склад %s · объекты %s · %s" % [
				int(warehouse["technology"]), JSON.stringify(warehouse["stock"]),
				JSON.stringify(warehouse["completed"]), str(warehouse["event"])]
	if _economy_status != null and _economy != null:
		var info: Dictionary = _economy.summary()
		_economy_status.text = "Хозяйство: %s · %s · кирпичи %d" % [
			str(info["phase"]), str(info["event"]), int(info["bricks"])]
	var phase := " · расчёт в фоне" if _day_task_id >= 0 else ""
	var slowest: Dictionary = WorldFireDemo.slowest_phase(_last_day_profile_us)
	var slow_text := " · медленнее всего: %s %.1f мс" % [
		slowest["name"], float(slowest["us"]) / 1000.0] \
		if not str(slowest["name"]).is_empty() else ""
	_summary.text = "День %d · FPS %d · чанки %d/%d%s\nОчередь дней %d · физика: последний %.1f мс / пик %.1f мс%s\nВид: %s\n%s" % [
		_last_completed_day, Engine.get_frames_per_second(), _active.size(),
		_active.size() + _pending.size(), phase, _days_pending,
		float(_last_day_step_us) / 1000.0,
		float(_peak_day_step_us) / 1000.0, slow_text,
		VIEW_NAMES[_view_mode], _storage_status]
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
		_world_model.config.world_seed]
	_status.text += "%s · высота %.2f · уклон %.1f°\n" % [
		profile["form"], profile["height"], profile["slope_degrees"]]
	_status.text += "Водосбор %.0f · вода %.2f · осадки %.2f\n" % [
		water["catchment"], water["depth"], weather["precipitation"]]
	_status.text += "Море %d · озёра %d · реки %d · паводок %d\n" % [
		amounts["ocean"], amounts["lakes"], amounts["rivers"], amounts["flooded"]]
	var edge := Boundary.geography_at(_center.x, _center.y,
		_world_model.config.width, _world_model.config.height, _world_model.config.world_seed)
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
	# Диагностика читает ровно те же физические реестры, что
	# движение природы и сохранение. Ни выбор камеры, ни открытие
	# панели не создают и не удаляют последствия бедствий.
	var aftermath: Dictionary = WorldAftermath.at(cell, _world_model,
		_surface, _nature, _fire, _hydro)
	_status.text += "Следы: геология %.0f%% · ожог %.0f%% · гарь %.0f%%\n" % [
		float(aftermath["geological_scar"]) * 100.0,
		float(aftermath["fire_damage"]) * 100.0,
		float(aftermath["scorched"]) * 100.0]
	_status.text += "Ресурсы здесь: лежащая древесина %d · уголь %d · взвесь %d\n" % [
		int(aftermath["fallen_wood"]), int(aftermath["charcoal"]),
		int(aftermath["suspended_ash"])]
	_status.text += "Ветер %.1f · изменённых вершин %d\n" % [
		float(weather["wind_speed"]), _world_model.changed_vertex_count()]
	_status.text += "%s\n" % _weather_status
	if _fire != null:
		# Тление живёт отдельно от пламени: после выгорания дерева
		# остаточный жар подстилки остаётся на карте до тушения.
		_status.text += "Огонь: очагов %d · тлеет %d · возгораний %d\n" % [
			_fire.burning_count(), _fire.smolder_count(),
			_fire.total_ignitions]
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
	_status.text += "Коллизии: обходов %d · пропусков %d · создано чанков %d\n" % [
		_collider_sweeps, _collider_idle_skips, _collider_chunks_created]
	if _fire_presentation != null:
		var fire_fx: Dictionary = _fire_presentation.debug_budget()
		_status.text += "Огонь FX: свет %d · звук %d · очаг %d · опросов %d\n" % [
			int(fire_fx["lights"]), int(fire_fx["audio_players"]),
			int(fire_fx["source_id"]), int(fire_fx["scans"])]
	if _atmosphere != null:
		var gpu: Dictionary = _atmosphere.debug_budget()
		_status.text += "Графика: автор %d · действующий %d · эмиттеры %d/%d · частицы %d/%d\n" % [
			_atmosphere_quality, _applied_visual_quality,
			int(gpu["gpu_emitters"]), VisualBudget.MAX_GPU_EMITTERS,
			int(gpu["gpu_max_particles"]), VisualBudget.MAX_GPU_PARTICLES]
		_status.text += "LOD: природа %d чанков/кадр · интервал погоды %.2f с\n" % [
			VisualBudget.nature_refresh_limit(_mesh_budget_p95),
			VisualBudget.weather_sync_interval(_render_zoom(), _mesh_budget_p95)]
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
