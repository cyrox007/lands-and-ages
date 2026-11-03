extends SceneTree
## Этап 7.1: сезонные шаги физики не пересоздают GPU-меши ежедневно.

const Config = preload("res://scripts/world_config.gd")
const Map = preload("res://scripts/world_map.gd")
const Hydro = preload("res://scripts/hydrology.gd")
const Surface = preload("res://scripts/surface.gd")
const Climate = preload("res://scripts/climate.gd")
const Landscape = preload("res://scripts/landscape_events.gd")
const Natural = preload("res://scripts/natural_processes.gd")
const Disasters = preload("res://scripts/natural_disasters.gd")
const Weather = preload("res://scripts/weather_events.gd")
const Scene = preload("res://scripts/world.gd")

var failures: Array[String] = []


func _check(ok: bool, reason: String) -> void:
	if not ok:
		failures.append(reason)


func _make_scene() -> Node3D:
	var scene := Scene.new()
	var world := Map.new(Config.new(48, 32, 1729, 16, 32))
	world.vertices_changed.connect(scene._on_world_changed)
	scene._world_model = world
	scene._hydro = Hydro.new(world)
	scene._hydro.rebuild()
	scene._surface = Surface.new(world, scene._hydro)
	scene._surface.rebuild()
	scene._climate = Climate.new(world, scene._hydro)
	scene._climate.rebuild()
	scene._climate.set_day(1)
	scene._surface.advance_climate_day(scene._climate)
	scene._hydro.apply_rainfall_map(scene._surface.runoff_map())
	scene._landscape_events = Landscape.new(world)
	scene._natural_processes = Natural.new(
		world, scene._hydro, scene._surface, scene._climate)
	scene._natural_disasters = Disasters.new(
		world, scene._hydro, scene._surface, scene._climate)
	scene._weather_events = Weather.new(
		world, scene._climate, scene._surface, scene._hydro)
	scene._lightning_light = OmniLight3D.new()
	scene.add_child(scene._lightning_light)
	scene._terrain_holder = Node3D.new()
	scene.add_child(scene._terrain_holder)
	scene._center = Vector2(24, 16)
	scene._setup_materials()
	scene._refresh_visible(true)
	return scene


func _compare_physics(a: Node3D, b: Node3D) -> void:
	_check(JSON.stringify(a._world_model.to_data())
		== JSON.stringify(b._world_model.to_data()),
		"Ускоренная перемотка сохраняет те же высоты, что ежедневная")
	_check(JSON.stringify(a._surface.to_data())
		== JSON.stringify(b._surface.to_data()),
		"Снег, влажность и наносы не зависят от частоты отрисовки")
	_check(a._natural_disasters.to_data() == b._natural_disasters.to_data(),
		"Стихийные события и напряжение одинаковы")
	_check(a._weather_events.to_data() == b._weather_events.to_data(),
		"Все удары молний произошли в те же дни")
	_check(a._natural_processes.to_data() == b._natural_processes.to_data(),
		"Эрозия не пропускает природные дни")
	_check(a._hydro.water_count() == b._hydro.water_count(),
		"Водосборы одинаковы после перемотки")


func _test_season() -> void:
	var accelerated := _make_scene()
	var reference := _make_scene()
	var expected_chunks: int = accelerated._pending.size()
	_check(expected_chunks > 0, "Существуют видимые GPU-чанки")
	accelerated._queue_days(Climate.SEASON_DAYS)
	for step in range(Climate.SEASON_DAYS):
		accelerated._process(1.0 / 60.0)
		reference._simulate_one_day()
		_check(accelerated._climate.day == reference._climate.day,
			"Каждый день сезона физически симулируется")
		if step < Climate.SEASON_DAYS - 1:
			_check(accelerated._chunk_rebuilds == 0,
				"До последнего дня сезон не строит меши")
			_check(accelerated._visual_refreshes == 0,
				"До конца сезона нет промежуточного полного обновления GPU")
	_check(accelerated._days_pending == 0, "Календарь завершил сезон")
	_check(accelerated._visual_refreshes == 1,
		"За сезон запланирована только одна полная перерисовка")
	_check(accelerated._chunk_rebuilds <= expected_chunks,
		"Финальный кадр не создаёт лишних мешей")
	_check(accelerated._peak_day_step_us >= accelerated._last_day_step_us,
		"Пиковое время физического шага измерено")
	_compare_physics(accelerated, reference)
	# Очередь строится только после завершения физических шагов.
	for i in range(expected_chunks + 2):
		if accelerated._pending.is_empty():
			break
		accelerated._process(1.0 / 60.0)
	_check(accelerated._pending.is_empty(), "Финальная очередь мешей опустела")
	_check(accelerated._chunk_rebuilds == expected_chunks,
		"Каждый видимый чанк построен ровно один раз за сезон")
	print("Этап 7.1: дней ", Climate.SEASON_DAYS,
		", мешей ", accelerated._chunk_rebuilds,
		", обновлений карты ", accelerated._visual_refreshes,
		", пик шага ", accelerated._peak_day_step_us, " мкс")
	accelerated.free()
	reference.free()


func _test_four_seasons() -> void:
	var scene := _make_scene()
	var initial_day: int = scene._climate.day
	var chunks: int = scene._pending.size()
	for i in range(4):
		scene._queue_days(Climate.SEASON_DAYS)
	_check(scene._days_pending == Climate.YEAR_DAYS,
		"Несколько быстрых нажатий объединяются в одну очередь времени")
	for day in range(Climate.YEAR_DAYS):
		scene._process(1.0 / 60.0)
		if day < Climate.YEAR_DAYS - 1:
			_check(scene._chunk_rebuilds == 0,
				"Несколько сезонов не запускают промежуточный рендер")
	_check(scene._climate.day == initial_day + Climate.YEAR_DAYS,
		"За год пройдены все дни по порядку")
	_check(scene._visual_refreshes == 1,
		"Четыре сезона дают одну итоговую перестройку карты")
	_check(scene._chunk_rebuilds <= chunks,
		"Годовая перемотка не создаёт избыточных GPU-мешей")
	print("Этап 7.1: год 96 дней, GPU-обновлений ",
		scene._visual_refreshes, ", построено мешей ", scene._chunk_rebuilds)
	scene.free()


func _test_compact_hud() -> void:
	var scene := _make_scene()
	scene._setup_interface()
	_check(scene._summary != null and scene._status != null,
		"Сводка и подробная диагностика существуют")
	_check(not scene._debug_details.visible,
		"По умолчанию технические подробности скрыты")
	scene._toggle_debug()
	_check(scene._debug_details.visible,
		"Техническую диагностику можно открыть")
	scene._toggle_debug()
	_check(not scene._debug_details.visible,
		"Техническую диагностику можно снова свернуть")
	scene.free()


func _initialize() -> void:
	_test_season()
	_test_four_seasons()
	_test_compact_hud()
	if not failures.is_empty():
		for reason in failures:
			push_error("Этап 7.1: " + reason)
		quit(1)
		return
	print("Этап 7.1: быстрая перемотка без ежедневного GPU-рендера — успешно.")
	quit(0)
