extends SceneTree
## Этап 11.0: интеграционный контракт всего атмосферного контроллера.
## Здесь не возникают собственные физические события; каждый эффект
## создаётся только из физического снимка или готового дневного результата.

const Config = preload("res://scripts/world_config.gd")
const Map = preload("res://scripts/world_map.gd")
const Hydro = preload("res://scripts/hydrology.gd")
const Climate = preload("res://scripts/climate.gd")
const Visual = preload("res://scripts/weather_visual_state.gd")
const Atmosphere = preload("res://scripts/weather_atmosphere_controller.gd")

var failures: Array[String] = []


func _check(ok: bool, message: String) -> void:
	# Накопление ошибок позволяет увидеть проблемы разных видов
	# погодной графики одним запуском, без создания новых тестовых задач.
	if not ok:
		failures.append(message)


func _weather_snapshot() -> Dictionary:
	# Проверяем профили на одном и том же физическом снимке:
	# разница между ними может быть только графической.
	return Visual.from_weather({
		"temperature": 14.0, "rainfall": 2.1, "snowfall": 0.0,
		"humidity": 0.91, "wind_speed": 18.0, "wind_gust": 25.0,
		"wind_direction_x": 1.0, "wind_direction_y": 0.0,
		"storm_intensity": 0.82
	})


func _check_catalog(atmosphere: Node3D) -> void:
	# Каталог должен перечислять поставляемые источники эффекта,
	# а не ссылки на несуществующие или нелицензированные модели.
	var catalog: Array[Dictionary] = atmosphere.effect_catalog()
	var ids := {}
	var required := [
		"rain", "snow", "wet_snow", "hail", "splashes",
		"snowdrift", "gusts", "dust", "clouds", "lightning", "thunder"
	]
	_check(catalog.size() == required.size(),
		"Каталог содержит одиннадцать используемых атмосферных ресурсов")
	for entry in catalog:
		var id: String = str(entry.get("id", ""))
		_check(not ids.has(id) and required.has(id),
			"Ресурс каталога имеет уникальный известный идентификатор")
		ids[id] = true
		_check(ResourceLoader.exists(str(entry.get("file", ""))),
			"Ресурс действительно существует: " + id)
		_check(str(entry.get("license", "")).contains("собственная")
			and not str(entry.get("physical_source", "")).is_empty(),
			"Происхождение и физический источник документированы: " + id)
	# Экспортируемая копия не должна разрешать изменения
	# атрибутов, используемых в следующем запросе.
	catalog[0]["id"] = "подмена"
	_check(str(atmosphere.effect_catalog()[0]["id"]) == "rain",
		"Каталог нельзя изменить через отладочное API")


func _test_controller(atmosphere: Node3D, state: Dictionary) -> void:
	# Восемь существующих эмиттеров принадлежат только подсистеме
	# осадков/ветра; молнии и звук выделяются фиксированными слотами.
	var budget: Dictionary = atmosphere.debug_budget()
	_check(atmosphere.get_child_count() == 2,
		"В одном атмосферном контроллере ровно два переиспользуемых семейства")
	_check(int(budget["gpu_emitters"]) == 8
		and int(budget["gpu_max_particles"]) == 2300
		and int(budget["lightning_slots"]) == 4,
		"GPU и звуковой бюджет ограничен, независимо от размера карты")
	var precipitation: Node3D = atmosphere.precipitation
	var lightning: Node3D = atmosphere.lightning

	atmosphere.set_quality(-100)
	_check(int(atmosphere.debug_budget()["quality"]) == 0
		and int(lightning.debug_state()["active_slot_limit"]) == 1,
		"Экономный профиль ограничивает и осадки, и молнии")
	precipitation.apply_snapshot(state, Vector2(24, 24), 3.0, 44.0, 1729)
	var rain: GPUParticles3D = precipitation._rain
	var low: float = rain.amount_ratio
	atmosphere.set_quality(2)
	precipitation.apply_snapshot(state, Vector2(24, 24), 3.0, 44.0, 1729)
	_check(rain.amount_ratio > low
		and int(lightning.debug_state()["active_slot_limit"]) == 4,
		"Подробный профиль увеличивает только визуальный бюджет")
	_check(atmosphere.get_child_count() == 2,
		"Смена профиля не создаёт новые узлы погодных эффектов")

	atmosphere.show_hazard({"kind": "шквал", "severity": 0.8},
		Vector2.RIGHT)
	_check(float(precipitation._event_life) > 0.0,
		"Шквал запускается исключительно от готового события")
	var event_life: float = precipitation._event_life
	paused = true
	precipitation._process(1.3)
	paused = false
	_check(is_equal_approx(float(precipitation._event_life), event_life),
		"Пауза останавливает часы визуального события")

	atmosphere.set_effects_enabled(false)
	_check(not bool(atmosphere.debug_budget()["enabled"])
		and is_zero_approx(float(precipitation._event_life)),
		"Скрытый слой останавливает и сбрасывает старый порыв")
	for node in precipitation.get_children():
		if node is GPUParticles3D:
			_check(not node.emitting and not node.visible,
				"При отключении нет висящих в сцене частиц")
	atmosphere.show_hazard({"kind": "ураган", "severity": 1.0},
		Vector2.RIGHT)
	_check(is_zero_approx(float(precipitation._event_life)),
		"Скрытый слой не начинает новое визуальное событие")
	atmosphere.set_effects_enabled(true)

	# Разрешённое количество *видимых* ударов зависит от качества,
	# но физический список из четырёх событий не сокращается.
	var events: Array[Dictionary] = []
	for i in range(4):
		events.append({
			"day": 3, "cell": Vector2i(20 + i, 20),
			"cause": "молния", "strength": 0.85,
			"ignition_potential": 0.0
		})
	var map := Map.new(Config.new(64, 48, 1729, 8, 16))
	atmosphere.set_quality(0)
	_check(atmosphere.show_lightning(events, map,
		Vector2(22, 20), 44.0, 3) == 1,
		"Экономный профиль показывает не более одной молнии")
	for e in events:
		e["day"] = 4
	atmosphere.set_quality(2)
	_check(atmosphere.show_lightning(events, map,
		Vector2(22, 20), 44.0, 4) == 4,
		"Подробный профиль использует четыре уже выделенных слота")
	atmosphere.set_effects_enabled(false)
	_check(int(lightning.debug_state()["visible"]) == 0
		and int(lightning.debug_state()["pending_thunder"]) == 0,
		"Переключение диагностического слоя убирает свет и гром")
	_check(atmosphere.show_lightning(events, map,
		Vector2(22, 20), 44.0, 5) == 0,
		"Скрытая атмосфера не воспроизводит физическую молнию")
	atmosphere.set_effects_enabled(true)
	_check(atmosphere.show_lightning(events, map,
		Vector2(22, 20), 44.0, 5) == 0,
		"Возвращение на карту не воспроизводит уже обработанные сутки")


func _test_camera_and_load(atmosphere: Node3D) -> void:
	# Используем настоящую карту, гидрологию и климат; ни один
	# вызов камеры, пресета или сброса не должен менять их JSON.
	var world := Map.new(Config.new(64, 48, 1729, 8, 16))
	var hydro := Hydro.new(world)
	hydro.rebuild()
	var climate := Climate.new(world, hydro)
	climate.rebuild()
	climate.set_day(6)
	var before_world := JSON.stringify(world.to_data())
	var before_hydro := JSON.stringify(hydro.to_data())
	var before_climate := JSON.stringify(climate.to_data())

	atmosphere.sync_world(climate, world, Vector2(16, 16), 38.0)
	var mask_origin: Vector2 = atmosphere.precipitation._mask_origin
	atmosphere.sync_world(climate, world, Vector2(42, 32), 38.0)
	_check(mask_origin != atmosphere.precipitation._mask_origin,
		"Локальная маска следует за камерой без дублирования эмиттеров")
	atmosphere.sync_world(climate, world, Vector2(42, 32), 110.0)
	for node in atmosphere.precipitation.get_children():
		if node is GPUParticles3D:
			_check(not node.emitting and not node.visible,
				"На обзорном масштабе отключены также ветер и пыль")
	# Сброс после загрузки удаляет старый климатический снимок,
	# но удерживает режим качества и запрет переигрывания грома.
	atmosphere.set_effects_enabled(false)
	atmosphere.clear_after_load(6)
	_check(atmosphere.precipitation.debug_state().is_empty()
		and int(atmosphere.lightning.debug_state()["last_played_day"]) == 6,
		"Загрузка сбрасывает маску и удерживает номер дня молний")
	_check(not bool(atmosphere.debug_budget()["enabled"])
		and not atmosphere.precipitation._enabled,
		"При загрузке скрытого слоя частицы не включаются самопроизвольно")
	atmosphere.set_effects_enabled(true)
	atmosphere.sync_world(climate, world, Vector2(24, 24), 42.0)
	_check(not atmosphere.precipitation.debug_state().is_empty(),
		"После загрузки контроллер читает климат заново")
	_check(JSON.stringify(world.to_data()) == before_world
		and JSON.stringify(hydro.to_data()) == before_hydro
		and JSON.stringify(climate.to_data()) == before_climate,
		"Полный атмосферный цикл не изменяет физическую карту и климат")


func _run() -> void:
	# Сценарий закрывает именно исходные критерии 11.0:
	# общий контроллер, каталог, LOD, качество, камеры, пауза,
	# загрузка и неизменность физических моделей.
	var atmosphere := Atmosphere.new()
	root.add_child(atmosphere)
	_check_catalog(atmosphere)
	_test_controller(atmosphere, _weather_snapshot())
	_test_camera_and_load(atmosphere)
	root.remove_child(atmosphere)
	atmosphere.free()
	if failures.is_empty():
		print("Этап 11.0: атмосфера, каталог, LOD, пауза и загрузка — успешно")
		quit(0)
		return
	for reason in failures:
		printerr("Этап 11.0: ", reason)
	quit(1)


func _initialize() -> void:
	# Эмиттеры и слоты должны создаться через готовое дерево Godot;
	# запуск из _initialize до добавления узла давал бы ложный сбой.
	call_deferred("_run")
