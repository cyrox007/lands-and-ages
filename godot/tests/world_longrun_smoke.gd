extends SceneTree
## Этап 7.5: длительная физика, разные seed, сохранения и нагрузка.

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

const TEMP_PATH := "user://world-stage-7-5.json"
const METRICS_PATH := "res://tests/world-stress-metrics.json"
const MAX_MEMORY_BYTES := 1024 * 1024 * 1024
const MAX_STEP_US := 30000000
const CASES := [
	{"width": 32, "height": 24, "seed": 1729, "days": 288, "step": 48},
	{"width": 64, "height": 48, "seed": 5821, "days": 192, "step": 48},
	{"width": 128, "height": 96, "seed": 9143, "days": 96, "step": 24},
	{"width": 256, "height": 192, "seed": 1729, "days": 24, "step": 12}
]

var failures: Array[String] = []
var metrics: Array[Dictionary] = []


func _check(valid: bool, message: String) -> void:
	if not valid:
		failures.append(message)


func _state(config: RefCounted) -> Dictionary:
	var world := Map.new(config)
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


func _same(a: Dictionary, b: Dictionary, label: String) -> void:
	_check(a["climate"].day == b["climate"].day,
		label + ": календарь непрерывен")
	_check(a["world"].to_data() == b["world"].to_data(),
		label + ": единые физические высоты")
	_check(a["hydro"]._downstream == b["hydro"]._downstream,
		label + ": направление стока")
	_check(a["hydro"]._discharge == b["hydro"]._discharge,
		label + ": расход рек")
	_check(a["hydro"]._water_level == b["hydro"]._water_level,
		label + ": уровень воды")
	_check(Save.capture(a) == Save.capture(b),
		label + ": все сохранённые природные состояния совпадают")


func _run_case(spec: Dictionary) -> void:
	var config := Config.new(spec["width"], spec["height"],
		spec["seed"], 16, 32)
	var reference := _state(config)
	var restarted := _state(Config.new(spec["width"], spec["height"],
		spec["seed"], 16, 32))
	var begin_us := Time.get_ticks_usec()
	var peak_step_us := 0
	var peak_memory := 0
	var min_memory := 9223372036854775807
	var restores := 0
	var save_bytes := 0
	var changes := 0
	var rebuilds := 0
	var height_reads := 0
	var max_pending_days := 0

	for i in range(spec["days"]):
		reference["runner"].run_day()
		restarted["runner"].run_day()
		peak_step_us = maxi(peak_step_us, restarted["runner"].last_duration_us)
		rebuilds += int(restarted["runner"].last_statistics["пересчёты водосборов"])
		height_reads += int(restarted["runner"].last_statistics["прочитано высот"])
		if restarted["runner"].last_result["terrain_changed"]:
			changes += 1
		var memory := OS.get_static_memory_usage()
		peak_memory = maxi(peak_memory, memory)
		min_memory = mini(min_memory, memory)
		if (i + 1) % spec["step"] != 0:
			continue
		var label := "%d×%d, seed %d, день %d" % [
			config.width, config.height, config.seed, i + 2]
		_same(reference, restarted, label)
		_check(Save.write_file(restarted, TEMP_PATH),
			label + ": сохранение на диск прошло")
		_check(FileAccess.file_exists(TEMP_PATH),
			label + ": файл на диске существует")
		var file := FileAccess.open(TEMP_PATH, FileAccess.READ)
		if file != null:
			save_bytes = maxi(save_bytes, file.get_length())
			file.close()
		var loaded: Dictionary = Save.read_file(TEMP_PATH)
		_check(not loaded.is_empty(), label + ": файл восстановлен")
		if loaded.is_empty():
			break
		restarted = loaded
		restores += 1
		_same(reference, restarted, label + " после загрузки")
		max_pending_days = maxi(max_pending_days, spec["days"] - i - 1)
		_check(peak_step_us <= MAX_STEP_US,
			label + ": отдельный физический день завершился за 30 с")
		_check(peak_memory < MAX_MEMORY_BYTES,
			label + ": превышен лимит памяти тестового полигона")
	_check(restores == spec["days"] / spec["step"],
		"Все промежуточные сохранения реально восстановлены")
	_check(restarted["climate"].day == spec["days"] + 1,
		"Дни всей многолетней симуляции рассчитаны без пропусков")
	_check(peak_memory >= min_memory and min_memory > 0,
		"Получены показатели потребления памяти")
	var elapsed_us := Time.get_ticks_usec() - begin_us
	var result := {
		"size": "%d×%d" % [config.width, config.height],
		"seed": config.seed, "days": spec["days"],
		"restores": restores, "changed_days": changes,
		"hydrology_rebuilds": rebuilds, "ground_cells_read": height_reads,
		"elapsed_ms": elapsed_us / 1000.0,
		"max_day_ms": peak_step_us / 1000.0,
		"memory_min_mib": min_memory / 1048576.0,
		"memory_peak_mib": peak_memory / 1048576.0,
		"max_save_bytes": save_bytes,
		"remaining_days_at_checkpoint": max_pending_days
	}
	metrics.append(result)
	print("Этап 7.5, длительный прогон: ", result)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(TEMP_PATH))


func _test_scene() -> void:
	var scene := Scene.new()
	get_root().add_child(scene)
	await process_frame
	# Стресс-тест не имеет права перезаписывать игровой слот пользователя.
	var scene_save := "user://world-stage-7-5-scene.json"
	scene._save_path = scene_save
	var begin_day: int = scene._climate.day
	var days := 24
	scene._queue_days(days)
	scene._request_storage("save")
	var frames := 0
	var busy_frames := 0
	var peak_frame_us := 0
	var last_frame := Time.get_ticks_usec()
	var timeout := Time.get_ticks_msec() + 180000
	while scene._days_pending > 0 or scene._day_task_id >= 0 \
			or not scene._storage_request.is_empty():
		await process_frame
		var current := Time.get_ticks_usec()
		peak_frame_us = maxi(peak_frame_us, current - last_frame)
		last_frame = current
		frames += 1
		if scene._day_task_id >= 0:
			busy_frames += 1
		if Time.get_ticks_msec() > timeout:
			_check(false, "Полный сезон в игровой сцене превысил 180 с")
			break
	_check(scene._climate.day == begin_day + days,
		"Сезон завершён в реальной игровой сцене")
	_check(busy_frames > days, "Во время расчёта продолжали выводиться кадры")
	_check(scene._visual_refreshes == 1,
		"После сезона GPU-чанки перестраиваются однократно")
	_check(FileAccess.file_exists(scene_save),
		"Отложенное сохранение сезона действительно записано")
	var file_state: Dictionary = Save.read_file(scene_save)
	_check(not file_state.is_empty(), "Большой мир можно восстановить с диска")
	if not file_state.is_empty():
		_check(file_state["climate"].day == begin_day + days,
			"Сохранение содержит последний рассчитанный день")
	scene._request_storage("load")
	_check(scene._day_task_id < 0 and scene._days_pending == 0,
		"После восстановления нет незавершённой задачи")
	_check(scene._day_runner.world == scene._world_model,
		"Фоновая симуляция работает с загруженной картой")
	var expected_chunks: int = scene._pending.size()
	for i in range(expected_chunks + 3):
		await process_frame
		if scene._pending.is_empty():
			break
	_check(scene._pending.is_empty(),
		"После восстановления очередь GPU отрисована до конца")
	_check(scene._active.size() == expected_chunks,
		"Нет лишних или пропущенных видимых чанков")
	metrics.append({
		"scene_days": days, "frames": frames,
		"frames_while_busy": busy_frames,
		"max_frame_ms": peak_frame_us / 1000.0,
		"mesh_rebuilds": scene._chunk_rebuilds,
		"visible_chunks": scene._active.size(),
		"season_refreshes": scene._visual_refreshes
	})
	print("Этап 7.5, GPU-полигон: ", metrics.back())
	scene.queue_free()
	await process_frame
	DirAccess.remove_absolute(ProjectSettings.globalize_path(scene_save))


func _write_metrics() -> void:
	var file := FileAccess.open(METRICS_PATH, FileAccess.WRITE)
	if file == null:
		return
	file.store_string(JSON.stringify({
		"version": 1, "cases": metrics,
		"failures": failures.size()
	}, "  ", true, true))
	file.close()


func _run() -> void:
	for spec in CASES:
		_run_case(spec)
	await _test_scene()
	_write_metrics()
	if not failures.is_empty():
		for problem in failures.slice(0, 20):
			push_error("Этап 7.5: " + problem)
		print("Нарушений длительного теста: ", failures.size())
		quit(1)
		return
	print("Этап 7.5: многолетняя симуляция, память и восстановление — успешно.")
	quit(0)


func _initialize() -> void:
	_run()
