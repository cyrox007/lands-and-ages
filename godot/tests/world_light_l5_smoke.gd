extends SceneTree
## Этап 11.2/L5: плавные переходы теней и климатического света.
## Проверяем абсолютные масштабы камеры, разный FPS и исходную физику.

const Config = preload("res://scripts/world_config.gd")
const Map = preload("res://scripts/world_map.gd")
const Hydro = preload("res://scripts/hydrology.gd")
const Surface = preload("res://scripts/surface.gd")
const Climate = preload("res://scripts/climate.gd")
const View = preload("res://scripts/world.gd")
const Shadow = preload("res://scripts/world_shadow_lod.gd")
const Lighting = preload("res://scripts/weather_lighting_state.gd")
const GroundShader = preload("res://shaders/natural_ground.gdshader")

var failures: Array[String] = []


func _check(valid: bool, reason: String) -> void:
	## Выводим все нарушения L5 в одном результате CI.
	if not valid:
		failures.append(reason)


func _test_shadow_transitions(world: RefCounted) -> void:
	## Исследуем область перехода от настоящих ближних теней L2
	## к недорогим дальним формам L3, включая обе стороны отсечки.
	var view := View.new()
	view._world_model = world
	view._center = Vector2(12.0, 12.0)
	view._setup_environment()
	var camera := Camera3D.new()
	view.add_child(camera)
	view._camera = camera
	var previous := 1.01
	for zoom in [32.0, 49.0, 50.0, 54.0, 58.0, 61.0, 62.0, 66.0, 96.0]:
		camera.size = zoom
		view._update_shadow_lod()
		var opacity: float = view._world_light.shadow_opacity
		_check(opacity >= 0.0 and opacity <= 1.0 and
			opacity <= previous + 0.00001,
			"При удалении камеры геометрические тени не становятся сильнее")
		_check(is_equal_approx(opacity, Shadow.shadow_opacity_for_zoom(
			zoom, 0)), "Направленный свет читает тот же плавный LOD")
		_check(view._world_light.shadow_enabled == Shadow.active(zoom, 0),
			"Карты теней выключаются только после полного затухания")
		previous = opacity
	_check(is_equal_approx(Shadow.shadow_opacity_for_zoom(50.0, 0), 1.0)
		and is_equal_approx(Shadow.shadow_opacity_for_zoom(62.0, 0), 0.0),
		"На границах перехода непрерывны сила тени и дальний рельеф")
	_check(Shadow.shadow_opacity_for_zoom(62.0 - 0.001, 0) < 0.00001,
		"Перед выключением карты нет резкого тёмного скачка")
	_check(Shadow.shadow_opacity_for_zoom(48.0, 2) == 0.0,
		"Диагностическая палитра не получает геометрические тени")
	_check(Shadow.shadow_opacity_for_zoom(NAN, 0) == 0.0,
		"Некорректный масштаб не включает настоящие тени")

	# Поворот и перемещение камеры не должны изменить абсолютный
	# коэффициент тени без смены зума или режима представления.
	camera.size = 66.0
	view._set_shadow_quality(0)
	_check(not view._world_light.shadow_enabled,
		"Экономный пресет ограничивает дальность геометрических теней")
	view._set_shadow_quality(2)
	_check(view._world_light.shadow_enabled and camera.size == 66.0,
		"Подробный пресет увеличивает дальность, сохраняя масштаб камеры")
	view._set_shadow_quality(1)

	camera.size = 56.0
	view._center = Vector2(14.0, 12.0)
	view._update_shadow_lod()
	var first: float = view._world_light.shadow_opacity
	view._center = Vector2(15.9, 12.0)
	view._update_shadow_lod()
	_check(is_equal_approx(first, view._world_light.shadow_opacity),
		"Положение центра и граница чанка не меняют яркость общей тени")
	view.free()


func _test_framerate_independent_lighting() -> void:
	## Один физический фронт должен давать одинаковую итоговую яркость
	## при 30, 60 и 120 FPS. Интерполяция работает только с копиями.
	var clear: Dictionary = Lighting.from_snapshot({})
	var storm: Dictionary = Lighting.from_snapshot({
		"cloud": 0.92, "storm": 0.78, "wind": 0.65
	})
	var original: Dictionary = storm.duplicate(true)
	var results: Array[Dictionary] = []
	for frames in [30, 60, 120]:
		var state: Dictionary = clear.duplicate(true)
		for _frame in range(frames):
			state = Lighting.blend(state, storm, 1.0 / float(frames))
		results.append(state)
	for item in results:
		_check(float(item["sun_energy"]) < float(clear["sun_energy"])
			and float(item["sun_energy"]) > float(storm["sun_energy"]),
			"Смена грозового фронта плавная, без мгновенного скачка")
	_check(absf(float(results[0]["sun_energy"]) -
		float(results[2]["sun_energy"])) < 0.0001,
		"Плавность климатического света не зависит от FPS")
	_check(Lighting.blend(clear, storm, 0.0) == clear and
		Lighting.blend(clear, storm, -2.0) == clear,
		"Пауза и отрицательное delta не меняют визуальное состояние")
	_check(Lighting.blend(clear, storm, NAN) == clear,
		"Недопустимое delta не вызывает скачков освещения")
	_check(storm == original,
		"Интерполяция никогда не переписывает целевой климатический снимок")


func _test_scene_weather(world: RefCounted) -> void:
	## Проверяем штатные свойства одного источника солнца и PBR.
	## Новая цель не должна читаться из физики на каждом кадре.
	var view := View.new()
	view._world_model = world
	view._setup_environment()
	view._setup_materials()
	var clear: Dictionary = Lighting.from_snapshot({})
	var storm: Dictionary = Lighting.from_snapshot({
		"cloud": 0.9, "storm": 0.9, "wind": 0.8
	})
	view._weather_light_current = clear.duplicate(true)
	view._weather_light_target = storm.duplicate(true)
	view._advance_weather_lighting(0.016)
	var first: float = view._world_light.light_energy
	_check(first < float(clear["sun_energy"]) and
		first > float(storm["sun_energy"]),
		"Первая смена погоды не обрушивает яркость сразу")
	view._advance_weather_lighting(0.0)
	_check(is_equal_approx(first, view._world_light.light_energy),
		"При остановке игрового времени освещение не меняется")

	# После серии кадров общая палитра стремится только к новой цели.
	for frame in range(120):
		view._advance_weather_lighting(1.0 / 60.0)
	_check(view._world_light.light_energy < first and
		view._world_light.light_energy >= float(storm["sun_energy"]),
		"Грозовой свет достигает цели без перескока")
	_check(float(view._ground_material.get_shader_parameter(
		"cloud_coverage")) < float(storm["cloud_coverage"]),
		"Пятна облаков также проявляются без скачка")
	_check(view._weather_light_target == storm,
		"Переход не переписывает целевой климатический снимок")

	# При загрузке целевой мир должен обновить свет только
	# из собственного Climate; диагностический вид нейтрален.
	view._view_mode = 2
	view._apply_weather_lighting({"cloud": 0.9, "storm": 0.9})
	_check(is_equal_approx(view._world_light.light_energy, 1.38),
		"Диагностический режим немедленно возвращает ясный свет")
	view.free()


func _test_seams() -> void:
	## Один источник материала и мировое поле исключают независимый
	## шум, фазу и палитру для каждого чанка.
	var code: String = GroundShader.code
	_check(code.contains("ground_position.xz * 0.012") and
		code.contains("cloud_time") and code.contains("far_blend"),
		"Облака и дальние формы используют непрерывные мировые координаты")
	_check(not code.contains("VERTEX ="),
		"Светотень не подменяет физический рельеф")


func _run() -> void:
	## Снимки физики до и после смены света должны быть побитово
	## идентичны: время анимации не является климатическим временем.
	var world := Map.new(Config.new(32, 24, 1729, 8, 16))
	var hydro := Hydro.new(world)
	hydro.rebuild()
	var surface := Surface.new(world, hydro)
	surface.rebuild()
	hydro.apply_rainfall_map(surface.runoff_map())
	var climate := Climate.new(world, hydro)
	climate.rebuild()
	climate.set_day(18)
	var before_world: Dictionary = world.to_data()
	var before_hydro: Dictionary = hydro.to_snapshot()
	var before_surface: Dictionary = surface.to_snapshot()
	var before_climate: Dictionary = climate.to_data()

	_test_shadow_transitions(world)
	_test_framerate_independent_lighting()
	_test_scene_weather(world)
	_test_seams()
	_check(world.to_data() == before_world and
		hydro.to_snapshot() == before_hydro and
		surface.to_snapshot() == before_surface and
		climate.to_data() == before_climate,
		"Переходы освещения не меняют карту, климат и гидрологию")

	if failures.is_empty():
		print("Этап 11.2/L5: плавные переходы света и теней — успешно")
		quit(0)
		return
	for reason in failures:
		printerr("Этап 11.2/L5: ", reason)
	quit(1)


func _initialize() -> void:
	## Художественное сравнение и аппаратный FPS остаются в L1 и L6.
	_run()
