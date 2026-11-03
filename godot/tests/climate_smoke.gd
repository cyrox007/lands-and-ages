extends SceneTree
## Этап 5: климат связан с географией, водой, грунтом и временем.

const Config = preload("res://scripts/world_config.gd")
const WorldMap = preload("res://scripts/world_map.gd")
const Hydrology = preload("res://scripts/hydrology.gd")
const Surface = preload("res://scripts/surface.gd")
const Climate = preload("res://scripts/climate.gd")
const Chunk = preload("res://scripts/chunk.gd")

var failures: Array[String] = []


func _check(value: bool, message: String) -> void:
	if not value:
		failures.append(message)


func _initialize() -> void:
	_run()


func _run() -> void:
	var world := WorldMap.new(Config.new(96, 72, 1729))
	var hydro := Hydrology.new(world)
	hydro.rebuild()
	var surface := Surface.new(world, hydro)
	surface.rebuild()
	var climate := Climate.new(world, hydro)
	climate.rebuild()

	# Средние широтные температуры севернее должны быть ощутимо ниже.
	var cold_sum := 0.0
	var hot_sum := 0.0
	var biomes := {}
	var max_local_difference := 0.0
	for x in range(96):
		cold_sum += float(climate.weather_at(Vector2i(x, 3))["annual_temperature"])
		hot_sum += float(climate.weather_at(Vector2i(x, 68))["annual_temperature"])
	for y in range(72):
		for x in range(96):
			var cell := Vector2i(x, y)
			var weather: Dictionary = climate.weather_at(cell)
			var temp: float = weather["temperature"]
			_check(is_finite(temp) and absf(temp) <= 60.0,
				"Локальная температура физически ограничена")
			_check(float(weather["precipitation"]) >= 0.0
				and float(weather["precipitation"]) <= 3.0,
				"Осадки положительны и ограничены")
			if temp > 5.0:
				_check(weather["weather"] != "снег",
					"При положительной температуре снег не идёт")
			if x + 1 < 96:
				var next_temp: float = climate.weather_at(cell + Vector2i(1, 0))["temperature"]
				max_local_difference = maxf(max_local_difference, absf(temp - next_temp))
			if y + 1 < 72:
				var next_temp: float = climate.weather_at(cell + Vector2i(0, 1))["temperature"]
				max_local_difference = maxf(max_local_difference, absf(temp - next_temp))
			biomes[climate.biome_at(cell, surface)] = true
	_check(cold_sum / 96.0 + 14.0 < hot_sum / 96.0,
		"Климатические зоны плавно холодают к северу")
	_check(max_local_difference < 14.0,
		"Нет одинокой клетки с морозом внутри экстремальной жары")
	_check(biomes.size() >= 3, "Физическая география формирует разные биомы")
	_check(climate.weather_at(Vector2i(-1, 3)).is_empty(),
		"Погода за пределами карты не существует")

	# Второй мир с тем же seed имеет те же климатические поля.
	var other_world := WorldMap.new(Config.new(96, 72, 1729))
	var other_hydro := Hydrology.new(other_world)
	other_hydro.rebuild()
	var other_surface := Surface.new(other_world, other_hydro)
	other_surface.rebuild()
	var other_climate := Climate.new(other_world, other_hydro)
	other_climate.rebuild()
	for day in [0, 24, 48, 72, 96]:
		_check(climate.set_day(day) and other_climate.set_day(day),
			"Календарный день допустим")
		for cell in [Vector2i(6, 9), Vector2i(30, 30), Vector2i(88, 64)]:
			var weather: Dictionary = climate.weather_at(cell)
			_check(weather == other_climate.weather_at(cell),
				"Температура и фронты воспроизводимы по seed")
			if float(weather["temperature"]) > 10.0:
				_check(weather["weather"] != "снег",
					"Тёплая погода не превращается в снегопад")
	var baseline_biome: String = climate.biome_at(Vector2i(40, 40), surface)
	climate.set_day(10)
	_check(climate.biome_at(Vector2i(40, 40), surface) == baseline_biome,
		"Биом не заменяется другим каждую смену погоды")

	# Реальное суточное взаимодействие вместо ручного переключателя мороза.
	climate.set_day(1)
	_check(hydro.apply_rainfall_map(climate.rainfall_map()),
		"Речная сеть принимает распределённые осадки")
	_check(surface.advance_climate_day(climate), "Грунты принимают локальную погоду")
	_check(surface.day == climate.day, "Физический день синхронизирован")
	for cell in [Vector2i(7, 9), Vector2i(36, 34), Vector2i(75, 60)]:
		var profile: Dictionary = surface.profile_at(cell)
		var weather: Dictionary = climate.weather_at(cell)
		_check(absf(float(profile["temperature"]) - float(weather["temperature"])) < 0.001,
			"Температура почвы соответствует локальной погоде")
		_check(float(profile["growth_potential"]) >= 0.0
			and float(profile["growth_potential"]) <= 1.0,
			"Потенциал растительности не превышает возможностей почвы")

	var incorrect := PackedFloat32Array([0.5, 1.0])
	_check(not hydro.apply_rainfall_map(incorrect),
		"Гидрология отвергает чужой размер карты")
	var rain := climate.rainfall_map()
	rain[0] = -1.0
	_check(not hydro.apply_rainfall_map(rain),
		"Гидрология отвергает отрицательные осадки")
	_check(not climate.set_day(-1), "Отрицательный календарь запрещён")

	var saved_climate: Dictionary = JSON.parse_string(JSON.stringify(climate.to_data()))
	var saved_surface: Dictionary = JSON.parse_string(JSON.stringify(surface.to_data()))
	_check(other_climate.load_data(saved_climate), "Календарь восстанавливается")
	_check(other_hydro.apply_rainfall_map(other_climate.rainfall_map()),
		"Восстанавливается пространственное питание рек")
	_check(other_surface.load_data(saved_surface), "Грунты восстанавливаются с температурой")
	var checkpoint := Vector2i(36, 34)
	_check(absf(float(other_surface.profile_at(checkpoint)["temperature"])
		- float(surface.profile_at(checkpoint)["temperature"])) < 0.5,
		"После сохранения температура клетки не теряется")
	_check(not other_climate.load_data({"version": 99}),
		"Чужой формат климата отвергается")

	var mesh_temperature := Chunk.create_mesh(0, 0, 1, world, surface, 3, climate)
	var mesh_biome := Chunk.create_mesh(0, 0, 1, world, surface, 4, climate)
	_check(mesh_temperature.get_surface_count() == 1
		and mesh_biome.get_surface_count() == 1,
		"GPU показывает климат и биомы")
	_check(mesh_temperature.surface_get_arrays(0)[Mesh.ARRAY_COLOR]
		!= mesh_biome.surface_get_arrays(0)[Mesh.ARRAY_COLOR],
		"Отображение температуры и биома отличается")

	if not failures.is_empty():
		for message in failures:
			push_error("Климат: " + message)
		quit(1)
		return
	print("Этап 5: широты, биомы, местная погода, осадки, грунты и GPU — успешно.")
	quit(0)
