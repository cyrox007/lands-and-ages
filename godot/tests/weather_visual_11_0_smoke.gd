extends SceneTree
## Этап 11.0: рендер погоды только читает физический мир.
## Эти headless-проверки не подменяют художественную оценку осадков.

const Config = preload("res://scripts/world_config.gd")
const WorldMap = preload("res://scripts/world_map.gd")
const Hydrology = preload("res://scripts/hydrology.gd")
const Climate = preload("res://scripts/climate.gd")
const Visual = preload("res://scripts/weather_visual_state.gd")
const Effects = preload("res://scripts/weather_fx_controller.gd")

class SplitFront extends RefCounted:
	var revision := 1

	func weather_at(cell: Vector2i) -> Dictionary:
		return {
			"rainfall": 2.4 if cell.x >= 16 else 0.0,
			"snowfall": 1.2 if cell.x < 16 else 0.0
		}


var failures: Array[String] = []


func _check(condition: bool, reason: String) -> void:
	## Собираем все обнаруженные нарушения, чтобы CI показывал полный отчёт.
	if not condition:
		failures.append(reason)


func _initialize() -> void:
	## Узлы сцены и GPU-частиц создаём после запуска SceneTree.
	call_deferred("_run")


func _run() -> void:
	## Проверяем раздельное поведение дождя, снега и отсутствие
	## скрытых изменений физического состояния от графических обновлений.
	var dry: Dictionary = Visual.from_weather({
		"rainfall": 0.0, "snowfall": 0.0,
		"wind_speed": 8.0, "storm_intensity": 0.0
	})
	var rain: Dictionary = Visual.from_weather({
		"rainfall": 2.4, "snowfall": 0.0,
		"wind_speed": 14.0, "storm_intensity": 0.75
	})
	var snow: Dictionary = Visual.from_weather({
		"rainfall": 0.0, "snowfall": 1.2,
		"wind_speed": 10.0, "storm_intensity": 0.0
	})
	_check(float(dry["rain"]) == 0.0 and float(dry["snow"]) == 0.0,
		"Без физических осадков не возникает графических частиц")
	_check(is_equal_approx(float(rain["rain"]), 1.0)
		and float(rain["snow"]) == 0.0,
		"Дождь не создаёт снег")
	_check(is_equal_approx(float(snow["snow"]), 0.5)
		and float(snow["rain"]) == 0.0,
		"Снег не создаёт дождь")
	_check(float(rain["storm"]) == 0.75,
		"Грозовой параметр читается без нового случайного события")

	var world := WorldMap.new(Config.new(32, 24, 1729, 8, 16))
	var hydro := Hydrology.new(world)
	hydro.rebuild()
	var climate := Climate.new(world, hydro)
	climate.rebuild()
	climate.set_day(1)
	var original_map := JSON.stringify(world.to_data())
	var original_climate := JSON.stringify(climate.to_data())
	var original_hydro := JSON.stringify(hydro.to_data())

	var controller = Effects.new()
	root.add_child(controller)
	controller.set_quality(0)
	controller.apply_snapshot(rain, Vector2(16.0, 12.0), 4.0, 44.0, 1729)
	_check(controller.debug_state() == rain,
		"Графический узел принимает неизменяемый снимок")
	var rain_emitter: GPUParticles3D = controller.get("_rain")
	var snow_emitter: GPUParticles3D = controller.get("_snow")
	_check(rain_emitter != null and snow_emitter != null,
		"Оба эмиттера создаются один раз")
	_check(rain_emitter.emitting and not snow_emitter.emitting,
		"Дождь не запускает снежный эмиттер")
	controller.apply_snapshot(snow, Vector2(16.0, 12.0), 4.0, 44.0, 1729)
	_check(not rain_emitter.emitting and snow_emitter.emitting,
		"Смена физического типа осадков отключает старый эмиттер")
	controller.set_effects_enabled(false)
	_check(not rain_emitter.emitting and not snow_emitter.emitting,
		"Отключение эффектов не создаёт осадки")

	# Для карты с короткими сторонами проверяем и середину, и её края.
	var first: Dictionary = Visual.sample(
		climate, world.config, Vector2(16.0, 12.0), 44.0)
	var edge: Dictionary = Visual.sample(
		climate, world.config, Vector2(0.0, 0.0), 100.0)
	_check(first == Visual.sample(
		climate, world.config, Vector2(16.0, 12.0), 44.0),
		"Выбор погодных полей не зависит от FPS или порядка кадров")
	_check(float(edge["rain"]) >= 0.0 and float(edge["snow"]) >= 0.0,
		"На границе карты читаются только допустимые климатические клетки")
	controller.sync_world(climate, world, Vector2(16.0, 12.0), 44.0)
	_check(JSON.stringify(world.to_data()) == original_map
		and JSON.stringify(climate.to_data()) == original_climate
		and JSON.stringify(hydro.to_data()) == original_hydro,
		"Рендер не меняет карту, климат или гидрологию")

	controller.set_effects_enabled(true)
	var front := SplitFront.new()
	controller.sync_world(front, world, Vector2(16.0, 12.0), 44.0)
	var mask: Image = controller._mask_texture.get_image()
	var left := mask.get_pixel(7, 8)
	var right := mask.get_pixel(9, 8)
	_check(left.r == 0.0 and left.g > 0.0 and right.r > 0.0 and right.g == 0.0,
		"Дождь и снег имеют разные области в одном кадре")
	controller.sync_world(front, world, Vector2(16.0, 12.0), 110.0)
	_check(not rain_emitter.visible and not snow_emitter.visible,
		"На обзорном масштабе частицы отключаются")

	# Удаление эффекта не удаляет природные объекты и не требует
	# переинициализации климата, который существует независимо от сцены.
	root.remove_child(controller)
	controller.free()
	if failures.is_empty():
		print("Этап 11.0: снимки дождя и снега независимы от физики")
		quit(0)
		return
	for error in failures:
		printerr("Этап 11.0: ", error)
	quit(1)
