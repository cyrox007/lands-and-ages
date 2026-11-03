extends SceneTree
## Этап 7.2: корректность фоновой физики и отзывчивость игрового кадра.

const Config = preload("res://scripts/world_config.gd")
const Map = preload("res://scripts/world_map.gd")
const Hydro = preload("res://scripts/hydrology.gd")
const Surface = preload("res://scripts/surface.gd")
const Climate = preload("res://scripts/climate.gd")
const Natural = preload("res://scripts/natural_processes.gd")
const Disasters = preload("res://scripts/natural_disasters.gd")
const Weather = preload("res://scripts/weather_events.gd")
const Runner = preload("res://scripts/world_day_runner.gd")
const WorldScene = preload("res://scripts/world.gd")

var failures: Array[String] = []


func _check(ok: bool, reason: String) -> void:
	if not ok:
		failures.append(reason)


func _make_state() -> Dictionary:
	var world := Map.new(Config.new(96, 64, 1729, 16, 32))
	var hydro := Hydro.new(world)
	hydro.rebuild()
	var surface := Surface.new(world, hydro)
	surface.rebuild()
	var climate := Climate.new(world, hydro)
	climate.rebuild()
	climate.set_day(1)
	surface.advance_climate_day(climate)
	hydro.apply_rainfall_map(surface.runoff_map())
	var runner := Runner.new(world, hydro, surface, climate,
		Weather.new(world, climate, surface, hydro),
		Natural.new(world, hydro, surface, climate),
		Disasters.new(world, hydro, surface, climate))
	return {"world": world, "hydro": hydro, "surface": surface,
		"climate": climate, "runner": runner}


func _verify_same_world(a: Dictionary, b: Dictionary) -> void:
	_check(JSON.stringify(a["world"].to_data()) ==
		JSON.stringify(b["world"].to_data()),
		"Вершины после работы в потоке совпадают с обычным расчётом")
	_check(JSON.stringify(a["surface"].to_data()) ==
		JSON.stringify(b["surface"].to_data()),
		"Влага, наносы, снег и заболачивание совпадают")
	_check(a["hydro"].water_count() == b["hydro"].water_count(),
		"Русла, озёра и разливы совпадают")
	_check(a["runner"].weather_events.to_data() ==
		b["runner"].weather_events.to_data(),
		"Разряды молний совпадают по seed")
	_check(a["runner"].natural_disasters.to_data() ==
		b["runner"].natural_disasters.to_data(),
		"Стихийные события и напряжения совпадают")


func _test_threaded_physics() -> void:
	var threaded := _make_state()
	var reference := _make_state()
	var frames := 0
	for day in range(12):
		var job: int = WorkerThreadPool.add_task(
			threaded["runner"].run_day, false, "Контроль фоновой физики")
		while not WorkerThreadPool.is_task_completed(job):
			frames += 1
			await process_frame
		WorkerThreadPool.wait_for_task_completion(job)
		reference["runner"].run_day()
		_check(threaded["climate"].day == reference["climate"].day,
			"Фоновая физика завершает день строго по порядку")
		_check(threaded["runner"].last_result["day"] == day + 2,
			"Фоновая задача сохраняет номер рассчитанного дня")
	_verify_same_world(threaded, reference)
	_check(frames > 0, "Главный поток получает кадры при расчёте")
	_check(threaded["runner"].last_duration_us > 0,
		"Измерено полное время фонового шага")
	var profile: Dictionary = threaded["runner"].last_profile_us
	for kind in ["климат", "почва", "гидрология", "молнии",
			"эрозия", "бедствия", "согласование"]:
		_check(profile.has(kind) and int(profile.get(kind, -1)) >= 0,
			"Выведена длительность этапа: " + kind)
	print("Этап 7.2: 12 дней, доступных кадров ", frames,
		", последний шаг ", threaded["runner"].last_duration_us, " мкс")
	print("Разбивка физики, мкс: ", profile)


func _test_real_scene() -> void:
	var scene := WorldScene.new()
	get_root().add_child(scene)
	scene._queue_days(3)
	var frames_while_busy := 0
	var timeout := Time.get_ticks_msec() + 90000
	while scene._days_pending > 0 or scene._day_task_id >= 0:
		await process_frame
		if scene._day_task_id >= 0:
			frames_while_busy += 1
		if Time.get_ticks_msec() > timeout:
			_check(false, "Фоновый расчёт превысил лимит исполнения")
			break
	_check(scene._climate.day == 4,
		"Реальная игровая сцена прошла три дня без пропусков")
	_check(scene._day_task_id < 0,
		"После расчёта рабочая задача корректно завершилась")
	_check(scene._last_completed_day == scene._climate.day,
		"HUD получил последнее завершённое состояние карты")
	_check(frames_while_busy > 2,
		"При тяжёлой физике главный поток продолжал выдавать кадры")
	print("Этап 7.2: кадров при фоновой физике ", frames_while_busy,
		", пик шага ", scene._peak_day_step_us, " мкс")
	scene.queue_free()
	await process_frame


func _initialize() -> void:
	_run()


func _run() -> void:
	await _test_threaded_physics()
	await _test_real_scene()
	if not failures.is_empty():
		for reason in failures.slice(0, 16):
			push_error("Этап 7.2: " + reason)
		quit(1)
		return
	print("Этап 7.2: фоновая физика, кадры и сохранность модели — успешно.")
	quit(0)
