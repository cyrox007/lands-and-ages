extends SceneTree
## Приёмка 7.4: снимок без потери Float32, продолжение по seed и атомарный файл.

const Config = preload("res://scripts/world_config.gd")
const Map = preload("res://scripts/world_map.gd")
const Hydro = preload("res://scripts/hydrology.gd")
const Surface = preload("res://scripts/surface.gd")
const Climate = preload("res://scripts/climate.gd")
const Weather = preload("res://scripts/weather_events.gd")
const Natural = preload("res://scripts/natural_processes.gd")
const Disasters = preload("res://scripts/natural_disasters.gd")
const Runner = preload("res://scripts/world_day_runner.gd")
const Save = preload("res://scripts/world_save.gd")
const Scene = preload("res://scripts/world.gd")

const TEST_PATH := "user://stage-7-4-smoke.json"
var failures: Array[String] = []


func _check(ok: bool, message: String) -> void:
	if not ok:
		failures.append(message)


func _make_world() -> Dictionary:
	var world := Map.new(Config.new(64, 48, 1729, 16, 32))
	var hydro := Hydro.new(world)
	hydro.rebuild()
	var surface := Surface.new(world, hydro)
	surface.rebuild()
	var climate := Climate.new(world, hydro)
	climate.rebuild()
	climate.set_day(1)
	surface.advance_climate_day(climate)
	hydro.apply_rainfall_map(surface.runoff_map())
	var weather := Weather.new(world, climate, surface, hydro)
	var natural := Natural.new(world, hydro, surface, climate)
	var disasters := Disasters.new(world, hydro, surface, climate)
	return {
		"world": world, "hydro": hydro, "surface": surface,
		"climate": climate, "weather": weather,
		"natural": natural, "disasters": disasters,
		"runner": Runner.new(world, hydro, surface, climate,
			weather, natural, disasters)
	}


func _report_difference(label: String, first: Dictionary, second: Dictionary) -> void:
	if first == second:
		return
	for key in first.keys():
		if first[key] == second.get(key):
			continue
		if first[key] is String and String(first[key]).length() > 120:
			print("Различие ", label, "/", key, ": байт ",
				String(first[key]).length(), "/", String(second.get(key, "")).length(),
				" · начало ", String(first[key]).substr(0, 80),
				" / ", String(second.get(key, "")).substr(0, 80))
		else:
			print("Различие ", label, "/", key, ": ",
				first[key], " / ", second.get(key))


func _same(a: Dictionary, b: Dictionary) -> void:
	_check(a["world"].to_data() == b["world"].to_data(),
		"Высоты и параметры мира сохраняются")
	_report_difference("гидрология", a["hydro"].to_snapshot(), b["hydro"].to_snapshot())
	_check(a["hydro"].to_snapshot() == b["hydro"].to_snapshot(),
		"Местный сток возвращается без округления")
	_report_difference("почва", a["surface"].to_snapshot(), b["surface"].to_snapshot())
	_check(a["surface"].to_snapshot() == b["surface"].to_snapshot(),
		"Снег, грунт, влага, сток и наносы восстанавливаются побитово")
	_check(a["climate"].to_data() == b["climate"].to_data(),
		"Календарь и климат совпадают")
	_check(a["weather"].to_data() == b["weather"].to_data(),
		"История молний и вероятность возгорания совпадают")
	_check(a["natural"].to_data() == b["natural"].to_data(),
		"Естественная эрозия продолжает свой календарь")
	_check(a["disasters"].to_data() == b["disasters"].to_data(),
		"Накопленные засухи, бури, паводки и напряжение совпадают")
	_check(a["hydro"]._downstream == b["hydro"]._downstream,
		"Направления всех речных стоков совпадают")
	_check(a["hydro"]._discharge == b["hydro"]._discharge,
		"Расход рек после загрузки совпадает")
	_check(a["hydro"]._water_level == b["hydro"]._water_level,
		"Уровни водной поверхности совпадают")


func _test_snapshot() -> void:
	var original := _make_world()
	for i in range(23):
		original["runner"].run_day()
	var cell := Vector2i(21, 15)
	var world: RefCounted = original["world"]
	_check(world.set_vertex(cell, world.vertex_at(cell) + 0.08),
		"Физическая вершина изменена перед сохранением")
	_check(original["runner"].synchronize_world(),
		"Водосборы согласованы с ручной деформацией")
	var saved: Dictionary = Save.capture(original)
	_check(not saved.is_empty(), "Все природные системы объединены в снимок")
	var parsed: Variant = JSON.parse_string(JSON.stringify(saved, "", true, true))
	_check(parsed is Dictionary, "Снимок записывается обычным JSON")
	var loaded: Dictionary = Save.restore(parsed)
	_check(not loaded.is_empty(), "Мир восстанавливается целиком")
	if loaded.is_empty():
		return
	_same(original, loaded)
	_check(loaded["natural"].advance_day(24).is_empty(),
		"Нельзя ещё раз выполнить сохранённый природный день")
	_check(loaded["weather"].advance_day(24).is_empty(),
		"Повторная молния после загрузки не возникает")
	_check(loaded["disasters"].advance_day(24).is_empty(),
		"Стихийное событие сохранённого дня не воспроизводится")
	for i in range(16):
		original["runner"].run_day()
		loaded["runner"].run_day()
		_check(original["climate"].day == loaded["climate"].day,
			"Обе симуляции продолжаются с одного игрового дня")
	_same(original, loaded)
	print("Этап 7.4: непрерывный расчёт до дня ",
		original["climate"].day, " — результаты совпали")


func _test_file_and_corruption() -> void:
	var original := _make_world()
	for i in range(5):
		original["runner"].run_day()
	_check(Save.write_file(original, TEST_PATH),
		"Единое сохранение атомарно записано в user://")
	var restored: Dictionary = Save.read_file(TEST_PATH)
	_check(not restored.is_empty(), "Файл прошёл проверку контрольной суммы")
	if not restored.is_empty():
		_same(original, restored)
	_check(not Save.write_file({}, TEST_PATH),
		"Неполный мир не может перезаписать корректный файл")
	_check(not Save.read_file(TEST_PATH).is_empty(),
		"Ошибочная запись не уничтожает предыдущее сохранение")
	var damaged: Dictionary = Save.capture(original)
	damaged["day"] = 99999
	_check(Save.restore(damaged).is_empty(),
		"Разные дни природных систем отвергаются")
	damaged = Save.capture(original)
	damaged["hydrology"]["local_rain"] = "invalid"
	_check(Save.restore(damaged).is_empty(),
		"Повреждённый пространственный сток не загружается")
	damaged = Save.capture(original)
	damaged["surface"]["moisture"] = "AA=="
	_check(Save.restore(damaged).is_empty(),
		"Не допускается обрезанный массив влажности")
	damaged = Save.capture(original)
	damaged["world"]["version"] = 900
	_check(Save.restore(damaged).is_empty(),
		"Чужой формат карты нельзя загрузить")
	# Проверяем подмену полезной нагрузки при неизменном SHA-256.
	var file := FileAccess.open(TEST_PATH, FileAccess.READ)
	var raw: String = file.get_as_text()
	file.close()
	var envelope: Dictionary = JSON.parse_string(raw)
	envelope["payload"] = envelope["payload"] + " "
	file = FileAccess.open(TEST_PATH, FileAccess.WRITE)
	file.store_string(JSON.stringify(envelope))
	file.close()
	_check(Save.read_file(TEST_PATH).is_empty(),
		"Контрольная сумма обнаруживает изменение файла")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(TEST_PATH))


func _test_live_scene() -> void:
	var scene := Scene.new()
	get_root().add_child(scene)
	# В SceneTree._initialize узлы становятся готовы на следующем кадре.
	await process_frame
	scene._save_path = TEST_PATH
	scene._request_storage("save")
	_check(FileAccess.file_exists(TEST_PATH),
		"Кнопка технического HUD создаёт реальный файл")
	_check(scene._last_completed_day == 1, "Начальный день сохранён")
	scene._queue_days(3)
	# Загрузка во время фонового расчёта должна дождаться одного
	# согласованного дня и отменить оставшуюся очередь сезонов.
	await process_frame
	scene._request_storage("load")
	var timeout := Time.get_ticks_msec() + 90000
	while scene._day_task_id >= 0 or scene._storage_request != "":
		await process_frame
		if Time.get_ticks_msec() > timeout:
			_check(false, "Ожидание завершения потока превысило лимит")
			break
	_check(scene._days_pending == 0, "Остаток очереди дней отменён")
	_check(scene._climate.day == 1 and scene._surface.day == 1,
		"Загрузка возвратила календарь и почву к снимку")
	_check(scene._last_completed_day == 1,
		"HUD показывает загруженный, а не прежний день")
	_check(scene._day_runner.world == scene._world_model,
		"Фоновый расчёт подключён к восстановленной карте")
	_check(scene._world_model.vertices_changed.is_connected(scene._on_world_changed),
		"Сигналы карты подключены к новой сцене")
	scene.queue_free()
	await process_frame
	DirAccess.remove_absolute(ProjectSettings.globalize_path(TEST_PATH))


func _run() -> void:
	_test_snapshot()
	_test_file_and_corruption()
	await _test_live_scene()
	if not failures.is_empty():
		for failure in failures.slice(0, 20):
			push_error("Этап 7.4: " + failure)
		print("Нарушений восстановления: ", failures.size())
		quit(1)
		return
	print("Этап 7.4: сохранения, восстановление и непрерывность физики — успешно.")
	quit(0)


func _initialize() -> void:
	_run()
