extends SceneTree
## Этап 11.2: климатический туман, световые окна и непрерывные тени.
## Художественный профиль проверяется математикой и настоящим World,
## но результат аппаратной оценки на Android не подменяется CI.

const Config = preload("res://scripts/world_config.gd")
const Map = preload("res://scripts/world_map.gd")
const Hydro = preload("res://scripts/hydrology.gd")
const Climate = preload("res://scripts/climate.gd")
const Visual = preload("res://scripts/weather_visual_state.gd")
const Light = preload("res://scripts/weather_lighting_state.gd")
const View = preload("res://scripts/world.gd")
const Ground = preload("res://shaders/natural_ground.gdshader")

var errors: Array[String] = []


func _check(ok: bool, reason: String) -> void:
	# Отмечаем каждый нарушенный критерий отдельно, чтобы
	# контроль освещения не скрывал ошибку смешения или камеры.
	if not ok:
		errors.append(reason)


func _weather(humidity: float, rain: float, snow: float,
		storm: float, wind: float) -> Dictionary:
	# Преобразование происходит тем же путём, что в игре:
	# сырые климатические поля → WeatherVisualState → освещение.
	return Light.from_snapshot(Visual.from_weather({
		"temperature": 10.0, "humidity": humidity,
		"rainfall": rain, "snowfall": snow,
		"storm_intensity": storm, "wind_speed": wind,
		"wind_gust": wind * 1.25,
		"wind_direction_x": 0.86, "wind_direction_y": 0.50
	}))


func _test_palette() -> void:
	# Настроения сцены различимы по тону и дальности:
	# ясная погода не получает густой туман, а гроза
	# гасит солнце и тёплые просветы.
	var clear := _weather(0.30, 0.0, 0.0, 0.0, 4.0)
	var clouds := _weather(0.78, 0.0, 0.0, 0.0, 8.0)
	var mist := _weather(0.94, 0.0, 0.0, 0.0, 2.0)
	var storm := _weather(0.98, 2.3, 0.0, 0.91, 20.0)

	_check(float(clear["fog_strength"]) < 0.01,
		"Ясная атмосфера не должна скрывать далёкий рельеф")
	_check(float(clouds["cloud_sunbreak"]) > 0.15,
		"Разорванная облачность создаёт читаемые солнечные окна")
	_check(float(mist["fog_density"]) > float(clouds["fog_density"])
		and float(mist["fog_height_density"]) > 0.0,
		"Тихая влажная погода усиливает низинную дымку")
	_check(float(storm["fog_density"]) > float(clear["fog_density"]) + 0.006
		and float(storm["sun_energy"]) < float(clear["sun_energy"]),
		"Грозовой фронт создаёт глубину и уменьшает свет")
	_check(float(storm["cloud_sunbreak"]) < 0.08,
		"В сплошной грозе нет фиктивных солнечных лучей")
	_check((storm["fog_color"] as Color).b > (storm["fog_color"] as Color).r,
		"Грозовая дымка холодная, без искусственного тёплого пятна")
	_check(float(mist["fog_density"]) < 0.027
		and float(storm["fog_density"]) < 0.028,
		"Графическая дымка ограничена и не скрывает всю карту")
	_check(float(storm["wind_x"]) > 0.0
		and float(storm["wind_y"]) > 0.0,
		"Облачный рисунок следует настоящему направлению ветра")

	var mix30 := clear.duplicate(true)
	var mix120 := clear.duplicate(true)
	for index in range(30):
		mix30 = Light.blend(mix30, storm, 1.0 / 30.0)
	for index in range(120):
		mix120 = Light.blend(mix120, storm, 1.0 / 120.0)
	_check(absf(float(mix30["fog_density"]) -
		float(mix120["fog_density"])) < 0.0002,
		"Дымка не зависит от FPS и частоты обновления кадров")
	_check(float(mix30["fog_density"]) < float(storm["fog_density"])
		and float(mix30["fog_density"]) > float(clear["fog_density"]),
		"Смена погоды плавно меняет дальнюю перспективу")


func _test_scene() -> void:
	# Используем настоящую карту, воду и климат, а не только
	# словарь чисел без реального Environment и шейдера.
	var world := Map.new(Config.new(32, 24, 1729, 8, 16))
	var hydro := Hydro.new(world)
	hydro.rebuild()
	var climate := Climate.new(world, hydro)
	climate.rebuild()
	climate.set_day(17)
	var original_world := JSON.stringify(world.to_data())
	var original_hydro := JSON.stringify(hydro.to_data())
	var original_climate := JSON.stringify(climate.to_data())

	var view := View.new()
	view._world_model = world
	view._center = Vector2(16.0, 12.0)
	view._setup_environment()
	view._setup_materials()
	var clear := _weather(0.23, 0.0, 0.0, 0.0, 4.0)
	var mist := _weather(0.96, 0.0, 0.0, 0.0, 2.0)
	var storm := _weather(0.98, 2.5, 0.0, 0.96, 20.0)
	view._write_weather_lighting(clear)
	_check(not view._sky_environment.fog_enabled,
		"Ясная сцена не использует сплошной серый фильтр")
	view._write_weather_lighting(mist)
	_check(view._sky_environment.fog_enabled
		and view._sky_environment.fog_density > 0.005,
		"Низинный туман включён в единый Environment")
	_check(float(view._ground_material.get_shader_parameter(
		"cloud_sunbreak")) > 0.0,
		"Солнечные окна управляются тем же климатическим светом")
	view._write_weather_lighting(storm)
	_check(view._sky_environment.fog_enabled
		and view._sky_environment.fog_light_color.b >
			view._sky_environment.fog_light_color.r,
		"Холодная гроза управляет туманом и небом вместе")
	var detailed_density: float = view._sky_environment.fog_density
	view._atmosphere_quality = 0
	view._write_weather_lighting(storm)
	_check(view._sky_environment.fog_density < detailed_density,
		"Экономный атмосферный пресет уменьшает нагрузку дымки")
	view._view_mode = 2
	view._apply_weather_lighting({"cloud": 1.0, "storm": 1.0, "rain": 1.0})
	_check(not view._sky_environment.fog_enabled
		and is_zero_approx(float(view._ground_material.get_shader_parameter(
			"cloud_coverage"))),
		"Диагностическая палитра не получает туман или облачные пятна")
	view.free()

	_check(Ground.code.contains("cloud_direction")
		and Ground.code.contains("cloud_sunbreak")
		and Ground.code.contains("ground_position.xz * 0.012"),
		"Художественные облака непрерывны на границах чанков")
	_check(not Ground.code.contains("VERTEX ="),
		"Световая полутень не подменяет физический рельеф")
	_check(JSON.stringify(world.to_data()) == original_world
		and JSON.stringify(hydro.to_data()) == original_hydro
		and JSON.stringify(climate.to_data()) == original_climate,
		"Туман, облака и пресеты не изменяют карту, воду и климат")


func _run() -> void:
	# Проверяем художественную палитру, плавность и реальный
	# контур использования Godot. Результат не заменяет просмотр PNG.
	_test_palette()
	_test_scene()
	if errors.is_empty():
		print("Этап 11.2/ART: туман, солнечные окна и физическая неизменность — успешно")
		quit(0)
		return
	for reason in errors:
		printerr("Этап 11.2/ART: ", reason)
	quit(1)


func _initialize() -> void:
	# Без GPU тестирует модель и назначение параметров в сцене.
	call_deferred("_run")
