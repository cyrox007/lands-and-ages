extends SceneTree
## Этап 11.4: реальная гроза, повреждение растительности и
## визуальная реакция с громом без повторных физических ударов.

const Config = preload("res://scripts/world_config.gd")
const WorldMap = preload("res://scripts/world_map.gd")
const Hydrology = preload("res://scripts/hydrology.gd")
const Surface = preload("res://scripts/surface.gd")
const Climate = preload("res://scripts/climate.gd")
const Weather = preload("res://scripts/weather_events.gd")
const Nature = preload("res://scripts/nature_registry.gd")
const LightningFX = preload("res://scripts/lightning_fx_controller.gd")

var failures: Array[String] = []


func _check(condition: bool, reason: String) -> void:
	# Сообщаем обо всех нарушениях, а не только о первом;
	# поэтому одно неверное состояние не скрывает остальные.
	if not condition:
		failures.append(reason)


func _make_world() -> Dictionary:
	# Тот же seed и масштаб, что в существующей погодной
	# регрессии: здесь требуется физический удар из WeatherEvents.
	var map := WorldMap.new(Config.new(96, 64, 1729, 16, 32))
	var hydro := Hydrology.new(map)
	hydro.rebuild()
	var surface := Surface.new(map, hydro)
	surface.rebuild()
	var climate := Climate.new(map, hydro)
	climate.rebuild()
	var weather := Weather.new(map, climate, surface, hydro)
	var nature := Nature.new(map, hydro, surface, climate)
	nature.generate()
	return {"map": map, "hydro": hydro, "surface": surface,
		"climate": climate, "weather": weather, "nature": nature}


func _natural_lightning(state: Dictionary) -> Dictionary:
	# Не подбираем случайный экранный разряд: ждём настоящий
	# результат суточной физики и передаём его визуализатору.
	var climate: RefCounted = state["climate"]
	var surface: RefCounted = state["surface"]
	var hydro: RefCounted = state["hydro"]
	var weather: RefCounted = state["weather"]
	for day in range(1, 97):
		climate.set_day(day)
		surface.advance_climate_day(climate)
		hydro.apply_rainfall_map(surface.runoff_map())
		var hits: Array[Dictionary] = weather.advance_day(day)
		if not hits.is_empty():
			_check(weather.advance_day(day).is_empty(),
				"Повтор суток не создаёт электрический удар")
			_check(hits[0]["cause"] == "молния" and hits[0]["day"] == day,
				"Эффект привязан к зарегистрированному удару")
			return hits[0]
	return {}


func _test_physical_effect(state: Dictionary, hit: Dictionary) -> void:
	# Растение должно получать электрический ущерб даже в дождь;
	# возгорание остаётся отдельным физическим вопросом.
	var nature: RefCounted = state["nature"]
	var target: Dictionary = {}
	for item in nature._objects.values():
		if item["kind"] == "дерево" and item["state"] == "целое":
			target = item
			break
	_check(not target.is_empty(), "В физическом мире есть дерево для удара")
	if target.is_empty():
		return
	var target_cell := Vector2i(int(target["x"]), int(target["y"]))
	var wet_hit: Dictionary = {
		"day": state["climate"].day, "cell": target_cell,
		"cause": "молния", "strength": 0.9, "ignition_potential": 0.0
	}
	var strikes: Array[Dictionary] = [wet_hit]
	var hazards: Array[Dictionary] = []
	var changed := {}
	var before: int = int(nature.object_at(int(target["id"]))["health"])
	nature._damage_from_events(hazards, strikes, changed)
	var after: int = int(nature.object_at(int(target["id"]))["health"])
	_check(after < before and after >= 0,
		"Электрический разряд повреждает дерево даже без риска пожара")
	_check(not changed.is_empty(),
		"Физическое повреждение помечает чанк для обновления")
	var saved: Dictionary = JSON.parse_string(JSON.stringify(nature.to_data()))
	var loaded := Nature.new(state["map"], state["hydro"],
		state["surface"], state["climate"])
	_check(loaded.load_data(saved),
		"Повреждения растительности сохраняются в существующем JSON")
	_check(int(loaded.object_at(int(target["id"]))["health"]) == after,
		"После загрузки повреждение не исчезает и не удваивается")
	_check(int(hit["day"]) <= state["climate"].day,
		"Физический день удара не находится в будущем")


func _test_visual(state: Dictionary, hit: Dictionary) -> void:
	# Аудио и треугольные каналы создаются только после того,
	# как WeatherEvents реально зарегистрировал удар.
	var fx := LightningFX.new()
	root.add_child(fx)
	var point := Vector2(hit["cell"]) + Vector2(0.5, 0.5)
	var day: int = hit["day"]
	var strikes: Array[Dictionary] = [hit]
	var original_map := JSON.stringify(state["map"].to_data())
	var original_weather := JSON.stringify(state["weather"].to_snapshot())
	var original_surface := JSON.stringify(state["surface"].to_data())
	var original_nature := JSON.stringify(state["nature"].to_data())
	var audio: AudioStreamWAV = fx._thunder_stream
	_check(audio.mix_rate == LightningFX.SOUND_RATE
		and audio.data.size() == roundi(float(LightningFX.SOUND_RATE)
			* LightningFX.SOUND_DURATION) * 2,
		"Гром создаётся один раз как настоящий 16-битный PCM")
	_check(fx._slots.size() == LightningFX.MAX_VISIBLE_BOLTS,
		"GPU и аудио ограничены четырьмя постоянными слотами")
	_check(fx.show_strikes(strikes, state["map"], point, 40.0, day) == 1,
		"Реальное физическое событие запускает видимый разряд")
	_check(fx.show_strikes(strikes, state["map"], point, 40.0, day) == 0,
		"Один день не воспроизводит молнию или гром второй раз")
	var flash: OmniLight3D = fx._slots[0]["flash"]
	var core: MeshInstance3D = fx._slots[0]["core"]
	var glow: MeshInstance3D = fx._slots[0]["glow"]
	_check(flash.visible and core.visible and glow.visible,
		"Молния имеет канал, свечение и локальную вспышку")
	_check((core.mesh as ArrayMesh).get_surface_count() == 1,
		"Канал электрического разряда собран единым мешем")
	var verts: PackedVector3Array = (core.mesh as ArrayMesh).surface_get_arrays(0)[
		Mesh.ARRAY_VERTEX]
	_check(verts.size() > 65,
		"Молния содержит основной канал и боковые ответвления")
	_check(fx.debug_state()["pending_thunder"] == 1,
		"Раскат грома следует за светом с задержкой")
	fx._process(0.15)
	_check(flash.visible, "Двойной импульс делает вспышку выразительной")
	fx._process(2.7)
	_check(fx.debug_state()["pending_thunder"] == 0
		and fx.debug_state()["visible"] == 0,
		"Свет завершился, а звуковое событие не повторяется")
	_check(fx.show_strikes(strikes, state["map"], point + Vector2(200, 0),
		40.0, day + 1) == 0,
		"Молния вне камеры не создаёт ненужный GPU или звук")
	fx.clear(day)
	_check(fx.show_strikes(strikes, state["map"], point, 40.0, day) == 0,
		"Загрузка сохранения не воспроизводит старую молнию")
	_check(fx.debug_state()["visible"] == 0
		and fx.debug_state()["pending_thunder"] == 0,
		"После загрузки нет оставшегося света или грома")
	_check(original_map == JSON.stringify(state["map"].to_data())
		and original_weather == JSON.stringify(state["weather"].to_snapshot())
		and original_surface == JSON.stringify(state["surface"].to_data())
		and original_nature == JSON.stringify(state["nature"].to_data()),
		"Визуализация и звук не меняют физические сохранения")
	root.remove_child(fx)
	fx.free()


func _run() -> void:
	# Отдельно проверяются доказуемая физика и видимые эффекты;
	# это не декоративный разряд из случайного таймера.
	var state := _make_world()
	var hit := _natural_lightning(state)
	_check(not hit.is_empty(), "В течение года появляется естественная молния")
	if not hit.is_empty():
		_test_physical_effect(state, hit)
		_test_visual(state, hit)
	if failures.is_empty():
		print("Этап 11.4: физическая молния, урон, канал и гром — успешно")
		quit(0)
		return
	for reason in failures:
		printerr("Этап 11.4: ", reason)
	quit(1)


func _initialize() -> void:
	# Перед созданием звуковых узлов дожидаемся готовности SceneTree.
	call_deferred("_run")
