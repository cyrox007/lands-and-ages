extends SceneTree
## Этап 11.3/V2: физическое поле ветра и зависимый от него рендер.

const Config = preload("res://scripts/world_config.gd")
const Map = preload("res://scripts/world_map.gd")
const Hydro = preload("res://scripts/hydrology.gd")
const Climate = preload("res://scripts/climate.gd")
const Surface = preload("res://scripts/surface.gd")
const Disasters = preload("res://scripts/natural_disasters.gd")
const Visual = preload("res://scripts/weather_visual_state.gd")
const Effects = preload("res://scripts/weather_fx_controller.gd")

var failures: Array[String] = []


func _check(condition: bool, message: String) -> void:
	# Проверяем все независимые инварианты до завершения теста.
	if not condition:
		failures.append(message)


func _run() -> void:
	# Две физические модели одного seed должны иметь одинаковый ветер,
	# независимо от частоты кадров и последовательности чтений.
	var world := Map.new(Config.new(96, 80, 1729, 16, 32))
	var hydro := Hydro.new(world)
	hydro.rebuild()
	var climate := Climate.new(world, hydro)
	var clone := Climate.new(world, hydro)
	climate.rebuild()
	clone.rebuild()
	climate.set_day(11)
	clone.set_day(11)
	var before_world := JSON.stringify(world.to_data())
	var before_hydro := JSON.stringify(hydro.to_data())
	var points := [Vector2i(10, 12), Vector2i(11, 12),
		Vector2i(37, 45), Vector2i(75, 60)]
	for cell in points:
		var i: int = hydro.cell_index(cell)
		var direction: Vector2 = climate.wind_direction_at_index(i)
		var next: Vector2 = climate.wind_direction_at_index(
			hydro.cell_index(cell + Vector2i.RIGHT))
		var gust: float = climate.wind_gust_at_index(i)
		var wind: float = climate.wind_at_index(i)
		var weather: Dictionary = climate.weather_at(cell)
		_check(absf(direction.length() - 1.0) < 0.00001,
			"Действующий ветер имеет единичное направление")
		_check(direction.dot(next) > 0.95,
			"Ветровой фронт непрерывен между соседними клетками")
		_check(gust >= wind and gust <= 36.0,
			"Порыв не меньше средней скорости и ограничен")
		_check(is_equal_approx(float(weather["wind_direction_x"]), direction.x)
			and is_equal_approx(float(weather["wind_direction_y"]), direction.y)
			and is_equal_approx(float(weather["wind_gust"]), gust),
			"Погода публикует реальные компоненты вектора и порыв")
		_check(direction == clone.wind_direction_at_index(i)
			and gust == clone.wind_gust_at_index(i),
			"Поле воспроизводится для одинакового seed")
	_check(climate.wind_direction_at_index(-1) == Vector2.ZERO
		and climate.wind_gust_at_index(-1) == 0.0,
		"Вне физической карты нет ветрового поля")

	# Шторм должен учитывать максимальный порыв, не меняя дождевой
	# или грунтовой баланс. Сравниваем с законом риска из Disasters.
	var surface := Surface.new(world, hydro)
	surface.rebuild()
	surface.advance_climate_day(climate)
	var disasters := Disasters.new(world, hydro, surface, climate)
	for cell in points:
		var i: int = hydro.cell_index(cell)
		var strength: float = climate.storm_at_index(i)
		var gust: float = climate.wind_gust_at_index(i)
		var expected := clampf((gust - 10.0) / 12.0, 0.0, 1.0) \
			* clampf(strength * 1.85, 0.0, 1.0)
		var actual: Dictionary = disasters.conditions_at(cell, false)
		_check(absf(float(actual["шторм"]) - expected) < 0.00001,
			"Риск шторма связан с порывом текущего климата")

	# Смена суток передвигает фронты; загрузка JSON восстанавливает
	# направление, не сохраняя отдельный массив ветра в каждом сейве.
	var old_direction: Vector2 = climate.wind_direction_at_index(
		hydro.cell_index(points[2]))
	climate.set_day(64)
	var new_direction: Vector2 = climate.wind_direction_at_index(
		hydro.cell_index(points[2]))
	_check(old_direction.distance_to(new_direction) > 0.001,
		"Суточный ветер меняет направление при смене фронта")
	var saved: Dictionary = JSON.parse_string(
		JSON.stringify(climate.to_data()))
	_check(clone.load_data(saved),
		"Прежний формат климатических сохранений восстановлен")
	for cell in points:
		var i: int = hydro.cell_index(cell)
		_check(climate.weather_at(cell) == clone.weather_at(cell)
			and climate.wind_direction_at_index(i) ==
			clone.wind_direction_at_index(i),
			"После загрузки весь погодный вектор идентичен")

	# Неподвижная карта и климат не меняются от пяти проб камеры,
	# отображение направления зависит от скорости, не создаёт ветер.
	var snapshot: Dictionary = Visual.sample(
		climate, world.config, Vector2(35.0, 36.0), 50.0)
	_check(snapshot == Visual.sample(
		clone, world.config, Vector2(35.0, 36.0), 50.0),
		"Векторная интерполяция камеры воспроизводима")
	var wind2 := Vector2(float(snapshot["wind_x"]),
		float(snapshot["wind_y"]))
	_check(wind2.length() > 0.99 and wind2.length() < 1.01,
		"Пять точек камеры дают нормализованное направление")
	_check(float(snapshot["gust"]) >= float(snapshot["wind"]) * 0.6,
		"Графический порыв происходит из физической выборки")

	var fx := Effects.new()
	root.add_child(fx)
	fx.apply_snapshot(snapshot, Vector2(35.0, 36.0), 5.0, 50.0, 1729)
	var rain: GPUParticles3D = fx.get("_rain")
	var snow: GPUParticles3D = fx.get("_snow")
	var rain_motion: ParticleProcessMaterial = rain.process_material
	var snow_motion: ParticleProcessMaterial = snow.process_material
	_check(rain_motion.direction.x * wind2.x >= 0.0
		and rain_motion.direction.z * wind2.y >= 0.0,
		"Дождь отклоняется по направлению климатического потока")
	_check(snow_motion.direction.y < 0.0
		and absf(snow_motion.direction.x) >= absf(rain_motion.direction.x),
		"Снег сносит сильнее дождя из-за меньшей скорости падения")
	fx.set_effects_enabled(false)
	root.remove_child(fx)
	fx.free()
	_check(JSON.stringify(world.to_data()) == before_world
		and JSON.stringify(hydro.to_data()) == before_hydro,
		"Ветер не меняет физическую карту или гидрологию")

	if not failures.is_empty():
		for message in failures:
			push_error(message)
		quit(1)
		return
	print("Этап 11.3/V2: ветер, порывы, шторма, осадки и сохранения — успешно")
	quit(0)


func _initialize() -> void:
	# Начинаем тест после создания SceneTree для GPU-эмиттеров.
	call_deferred("_run")
