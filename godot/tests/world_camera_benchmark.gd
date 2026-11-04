extends SceneTree
## Этап 8.7: воспроизводимый маршрут камеры на настоящей сцене Godot.
## Headless измеряет интервал главного цикла, не аппаратные FPS/VRAM.

const View = preload("res://scripts/world.gd")
const Route = preload("res://scripts/world_benchmark_route.gd")
const Metrics = preload("res://scripts/world_benchmark_metrics.gd")
const RenderCache = preload("res://scripts/chunk_render_cache.gd")

var failures: Array[String] = []


func _check(condition: bool, reason: String) -> void:
	if not condition:
		failures.append(reason)


func _check_percentiles() -> void:
	var values: Array[float] = [8.0, 2.0, 16.0, 4.0]
	var empty: Array[float] = []
	_check(Metrics.percentile(values, 0.5) == 4.0,
		"Медиана вычисляется на отсортированной выборке")
	_check(Metrics.percentile(values, 0.95) == 16.0,
		"Высокий процентиль включает худший кадр маленькой выборки")
	_check(Metrics.percentile(empty, 0.95) == 0.0,
		"Пустая выборка не вызывает деления на ноль")


func _validate_route(points: Array[Dictionary], width: int, height: int) -> void:
	_check(points.size() >= 300 and points == Route.samples(width, height),
		"Фиксированный маршрут воспроизводится без случайности")
	var phases := {}
	for point in points:
		var center: Vector2 = point["center"]
		var zoom: float = point["zoom"]
		_check(center.x >= 0.0 and center.y >= 0.0
			and center.x < float(width) and center.y < float(height),
			"Все точки маршрута находятся внутри карты")
		_check(zoom >= View.MIN_ZOOM and zoom <= View.MAX_ZOOM,
			"Масштаб маршрута поддерживается камерой")
		phases[point["phase"]] = true
	_check(phases.size() == Route.SEGMENTS.size(),
		"Все фазы маршрута включены в испытание")


func _output_path() -> String:
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--report="):
			return argument.trim_prefix("--report=")
	return "user://world-camera-8-7.json"


func _save_report(report: Dictionary) -> bool:
	var file := FileAccess.open(_output_path(), FileAccess.WRITE)
	if file == null:
		return false
	file.store_string(JSON.stringify(report, "\t") + "\n")
	file.close()
	return true


func _initialize() -> void:
	_run()


func _run() -> void:
	await process_frame
	_check_percentiles()
	var started := Time.get_ticks_usec()
	var scene := View.new()
	get_root().add_child(scene)
	var initialization_ms := float(Time.get_ticks_usec() - started) / 1000.0
	if scene._world_model == null or scene._camera == null:
		push_error("Этап 8.7: сцена мира не инициализирована")
		quit(1)
		return

	var model_before: Dictionary = scene._world_model.to_data()
	var config: RefCounted = scene._world_model.config
	var points: Array[Dictionary] = Route.samples(config.width, config.height)
	_validate_route(points, config.width, config.height)
	var recorder := Metrics.new()
	var phase := ""
	var phases: Array[Dictionary] = []
	var frame_intervals: Array[float] = []
	var last_tick := Time.get_ticks_usec()

	for point in points:
		var name: String = point["phase"]
		if name != phase:
			if not phase.is_empty():
				phases.append(recorder.finish(scene))
			recorder.begin(name, scene)
			phase = name

		var target: Vector2 = point["center"]
		var zoom: float = point["zoom"]
		if not is_equal_approx(scene._camera.size, zoom):
			scene._change_zoom(zoom / scene._camera.size)
		if scene._center.distance_squared_to(target) > 0.000001:
			scene._move_center(target - scene._center)

		await process_frame
		var current_tick := Time.get_ticks_usec()
		var interval := float(current_tick - last_tick) / 1000.0
		last_tick = current_tick
		frame_intervals.append(interval)
		recorder.record(scene, interval)

	if not phase.is_empty():
		phases.append(recorder.finish(scene))

	var total_builds := 0
	var total_hits := 0
	var total_evictions := 0
	var peak_pending := 0
	var peak_static := 0
	var peak_cached_bytes := 0
	for result in phases:
		_check(result["frames"] > 0, "Каждая фаза содержит реальные кадры")
		_check(result["cache_limits_valid"], "Кеш мешей не превысил бюджет")
		total_builds += int(result["chunks_built"])
		total_hits += int(result["cache_hits"])
		total_evictions += int(result["cache_evictions"])
		peak_pending = maxi(peak_pending, int(result["peak_pending_chunks"]))
		peak_static = maxi(peak_static, int(result["peak_godot_static_bytes"]))
		peak_cached_bytes = maxi(peak_cached_bytes,
			int(result["peak_cached_geometry_bytes"]))

	_check(frame_intervals.size() == points.size(),
		"Каждая точка маршрута получила замер интервала кадра")
	_check(phases.size() == Route.SEGMENTS.size(),
		"Для каждого этапа сформирована отдельная статистика")
	_check(total_builds > 0, "Используется реальная генерация GPU-чанков")
	_check(scene._world_model.to_data() == model_before,
		"Тест графики не меняет физическую карту или сохранение")
	_check(scene._render_cache.count() <= RenderCache.MAX_CHUNKS,
		"Кеш после маршрута ограничен по количеству")
	_check(scene._render_cache.estimated_bytes <=
		RenderCache.MAX_ESTIMATED_BYTES,
		"Кеш после маршрута ограничен по оценке памяти")

	var is_headless: bool = DisplayServer.get_name() == "headless"
	var report := {
		"schema_version": 1,
		"stage": "8.7",
		"route_version": Route.VERSION,
		"route_frames": points.size(),
		"engine": Engine.get_version_info().get("string", "unknown"),
		"platform": OS.get_name(),
		"render_backend": DisplayServer.get_name(),
		"headless": is_headless,
		"units": {
			"interval_ms": "интервал между кадрами игрового цикла",
			"build_frame_ms": "время очереди построения мешей на CPU",
			"peak_cached_geometry_bytes": "оценка буферов вершин/индексов",
			"peak_godot_static_bytes": "статическая память Godot, не RAM/VRAM"
		},
		"map": {
			"width": config.width,
			"height": config.height,
			"seed": config.seed,
			"chunk_size": config.chunk_size
		},
		"initialization_ms": initialization_ms,
		"summary": {
			"interval_ms_p50": Metrics.percentile(frame_intervals, 0.50),
			"interval_ms_p95": Metrics.percentile(frame_intervals, 0.95),
			"interval_ms_p99": Metrics.percentile(frame_intervals, 0.99),
			"chunks_built": total_builds,
			"cache_hits": total_hits,
			"cache_evictions": total_evictions,
			"peak_pending_chunks": peak_pending,
			"peak_cached_geometry_bytes": peak_cached_bytes,
			"peak_godot_static_bytes": peak_static,
			"pending_after_route": scene._pending.size(),
			"physics_unchanged": scene._world_model.to_data() == model_before
		},
		"phases": phases
	}
	_check(_save_report(report), "JSON-отчёт сохранён в выбранный файл")
	scene.queue_free()

	if not failures.is_empty():
		for reason in failures.slice(0, 20):
			push_error("Этап 8.7: " + reason)
		quit(1)
		return

	print("Этап 8.7: ", points.size(), " кадров, ",
		total_builds, " GPU-построений, ", total_hits,
		" попаданий кеша; p95 интервала ",
		"%.2f" % report["summary"]["interval_ms_p95"],
		" мс; отчёт ", _output_path())
	print("Этап 8.7: воспроизводимый маршрут и JSON-метрики — успешно.")
	quit(0)
