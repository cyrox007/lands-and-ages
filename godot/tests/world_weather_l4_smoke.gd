extends SceneTree
## Этап 11.2/L4: свет и облачные пятна реагируют на реальный Climate.
## Рендер не создаёт новые физические облака, грозы или разряды.

const Config = preload("res://scripts/world_config.gd")
const Map = preload("res://scripts/world_map.gd")
const Hydro = preload("res://scripts/hydrology.gd")
const Surface = preload("res://scripts/surface.gd")
const Climate = preload("res://scripts/climate.gd")
const View = preload("res://scripts/world.gd")
const Visual = preload("res://scripts/weather_visual_state.gd")
const Effects = preload("res://scripts/weather_fx_controller.gd")
const Lighting = preload("res://scripts/weather_lighting_state.gd")
const GroundShader = preload("res://shaders/natural_ground.gdshader")

var failures: Array[String] = []


func _check(ok: bool, reason: String) -> void:
	## Собираем полный список нарушений, а не только первую ошибку.
	if not ok:
		failures.append(reason)


func _test_mapping() -> void:
	## Одни и те же физические поля должны давать устойчивое освещение.
	## Синтетические условия проверяют границы, а не подменяют Climate.
	var clear: Dictionary = Lighting.from_snapshot({})
	var cloud: Dictionary = Lighting.from_snapshot({
		"cloud": 0.75, "storm": 0.0, "wind": 0.4})
	var thunder: Dictionary = Lighting.from_snapshot({
		"cloud": 0.9, "storm": 0.95, "wind": 0.8})
	_check(is_equal_approx(float(clear["sun_energy"]), 1.25) and
		is_equal_approx(float(clear["ambient_energy"]), 0.61),
		"Ясная погода сохраняет исходное солнце и окружающий свет")
	_check(float(clear["cloud_coverage"]) == 0.0,
		"При ясном небе отсутствуют декоративные облачные пятна")
	_check(float(clear["sun_energy"]) > float(cloud["sun_energy"]) and
		float(cloud["sun_energy"]) > float(thunder["sun_energy"]),
		"Физические облака и грозы монотонно затемняют солнце")
	_check(float(thunder["ambient_energy"]) < float(clear["ambient_energy"]),
		"Грозовой фронт снижает освещение всей сцены")
	_check((thunder["sun_color"] as Color).b >
		(thunder["sun_color"] as Color).r,
		"Грозовая температура света холоднее ясного солнечного дня")
	_check(Lighting.from_snapshot({"storm": 10.0, "cloud": -1.0})[
		"cloud_coverage"] <= 1.0,
		"Даже повреждённый снимок не создаёт сверхяркие облака")


func _test_renderer(world: RefCounted, climate: RefCounted) -> void:
	## Поднимаем штатный материал и освещение без загрузки всей карты.
	## Контроллер получает настоящий снимок пяти климатических клеток.
	var view := View.new()
	view._world_model = world
	view._center = Vector2(16.0, 12.0)
	view._setup_environment()
	view._setup_materials()
	var effects := Effects.new()
	view._weather_fx = effects

	var dry: Dictionary = Visual.from_weather({
		"humidity": 0.16, "rainfall": 0.0, "snowfall": 0.0,
		"wind_speed": 6.0, "storm_intensity": 0.0})
	var rain: Dictionary = Visual.from_weather({
		"humidity": 0.94, "rainfall": 1.8, "snowfall": 0.0,
		"wind_speed": 18.0, "storm_intensity": 0.75})
	effects.apply_snapshot(dry, Vector2.ZERO, 0.0, 44.0, 1729)
	view._sync_water_weather()
	var bright: float = view._world_light.light_energy
	_check(view._ground_material.get_shader_parameter("cloud_coverage") == 0.0,
		"На сухой ясной карте облачная текстура не затемняет грунт")

	effects.apply_snapshot(rain, Vector2.ZERO, 0.0, 44.0, 1729)
	view._sync_water_weather()
	var storm_energy: float = view._world_light.light_energy
	_check(storm_energy < bright and storm_energy >= 0.62,
		"Свет реальной грозы ослаблен без новых DirectionalLight3D")
	_check(float(view._ground_material.get_shader_parameter(
		"cloud_coverage")) > 0.6,
		"Только физический влажный фронт включает облачные пятна")
	_check(view._sky_environment.ambient_light_energy < 0.61,
		"Физический фронт ослабляет также окружающий свет")
	_check(is_equal_approx(float(view._water_material.get_shader_parameter(
		"storm_strength")), 0.75),
		"Рендер воды и свет используют один и тот же снимок грозы")

	# Счётчик визуального времени общий с волнами, но в климат не пишет.
	view._advance_water_animation(0.5)
	_check(is_equal_approx(float(view._ground_material.get_shader_parameter(
		"cloud_time")), 0.5),
		"Облачные пятна движутся по общим игровым часам")

	# Служебная палитра не должна зависеть от грозы или количества кадров.
	view._view_mode = 2
	view._sync_water_weather()
	_check(is_equal_approx(view._world_light.light_energy, bright) and
		float(view._ground_material.get_shader_parameter("cloud_coverage")) == 0.0,
		"Диагностический режим отключает атмосферную тонировку")

	# Обычный климат можно прочитать после суточного расчёта,
	# без новых событий и случайных источников света.
	var physical: Dictionary = Visual.sample(climate, world.config,
		Vector2(16.0, 12.0), 44.0)
	_check(physical.has("cloud") and float(physical["cloud"]) >= 0.0 and
		float(physical["cloud"]) <= 1.0,
		"Облачность реально доступна из пяти климатических проб")
	view._view_mode = 0
	effects.apply_snapshot(physical, Vector2.ZERO, 0.0, 44.0, 1729)
	view._sync_water_weather()
	_check(view._world_light.light_energy >= 0.62 and
		view._world_light.light_energy <= 1.25,
		"Естественное освещение ограничено при любых климатических полях")

	# Реальные молнии уже принадлежат WeatherEvents: свет здесь
	# не должен включать узел удара, если не было физического события.
	_check(not view._lightning_light.visible,
		"Грозовое затемнение не порождает фиктивный разряд")
	view.free()
	effects.free()


func _test_shader() -> void:
	## Маска облаков читает мировые координаты и единые часы,
	## а мокрая поверхность сохраняет расчёт по физической Surface.
	var code: String = GroundShader.code
	_check(code.contains("cloud_coverage") and
		code.contains("cloud_wind") and code.contains("cloud_time"),
		"В графическом материале есть облачный фронт из Climate")
	_check(code.contains("ground_position.xz * 0.012") and
		code.contains("terrain_noise") and code.contains("cloud_dimming"),
		"Облачный рисунок не повторяет квадратные границы чанков")
	_check(code.contains("wet_material") and code.contains("ground_conditions"),
		"Мокрый PBR остаётся связан с физическим грунтом")
	_check(not code.contains("VERTEX ="),
		"Атмосферный свет не меняет геометрию высот")


func _run() -> void:
	## Проверяем физическую неизменность при ясном, облачном и грозовом
	## освещении, затем при возвращении к климату настоящего мира.
	var world := Map.new(Config.new(32, 24, 1729, 8, 16))
	var hydro := Hydro.new(world)
	hydro.rebuild()
	var surface := Surface.new(world, hydro)
	surface.rebuild()
	hydro.apply_rainfall_map(surface.runoff_map())
	var climate := Climate.new(world, hydro)
	climate.rebuild()
	climate.set_day(17)
	var before_world: Dictionary = world.to_data()
	var before_hydro: Dictionary = hydro.to_snapshot()
	var before_surface: Dictionary = surface.to_snapshot()
	var before_climate: Dictionary = climate.to_data()

	_test_mapping()
	_test_renderer(world, climate)
	_test_shader()
	_check(world.to_data() == before_world and
		hydro.to_snapshot() == before_hydro and
		surface.to_snapshot() == before_surface and
		climate.to_data() == before_climate,
		"Погодный свет не меняет рельеф, воду, грунт или климат")

	if failures.is_empty():
		print("Этап 11.2/L4: свет и облачность по реальному климату — успешно")
		quit(0)
		return
	for reason in failures:
		printerr("Этап 11.2/L4: ", reason)
	quit(1)


func _initialize() -> void:
	## CI выполняет физические контракты без имитации аппаратных FPS.
	_run()
