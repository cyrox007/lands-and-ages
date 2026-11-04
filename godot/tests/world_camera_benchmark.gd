extends SceneTree
## Этап 8.7: воспроизводимый маршрут камеры на настоящей сцене Godot.
## Headless измеряет интервал главного цикла, не аппаратные FPS/VRAM.

const View = preload("res://scripts/world.gd")
const Route = preload("res://scripts/world_benchmark_route.gd")
const Metrics = preload("res://scripts/world_benchmark_metrics.gd")
const RenderCache = preload("res://scripts/chunk_render_cache.gd")
const Runner = preload("res://scripts/world_benchmark_runner.gd")

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

	var config: RefCounted = scene._world_model.config
	var points: Array[Dictionary] = Route.samples(config.width, config.height)
	_validate_route(points, config.width, config.height)
	var report: Dictionary = await Runner.new().run(scene)
	report["initialization_ms"] = initialization_ms
	var summary: Dictionary = report["summary"]
	var phases: Array = report["phases"]

	_check(report["route_frames"] == points.size(),
		"Количество кадров соответствует версии маршрута")
	_check(phases.size() == Route.SEGMENTS.size(),
		"Все девять фаз записаны в отчёт")
	var reported_frames := 0
	for result in phases:
		reported_frames += int(result["frames"])
		_check(result["frames"] > 0, "Каждая фаза содержит измерения")
		_check(result["cache_limits_valid"], "Лимит кеша не нарушен")
	_check(reported_frames == points.size(),
		"Все кадры распределены по фазам без пропусков")
	_check(int(summary["chunks_built"]) > 0,
		"Тест использует реальные GPU-чанки")
	_check(bool(summary["physics_unchanged"]),
		"Измерения не изменили физическую карту")
	_check(int(summary["visibility_fast_rejects"]) > 0,
		"Быстрое отсечение действительно отсекает кандидатов")
	_check(int(summary["visibility_precise_checks"]) > 0,
		"Видимые кандидаты проверяются точно")
	_check(scene._render_cache.count() <= RenderCache.MAX_CHUNKS,
		"Число записей кеша ограничено")
	_check(scene._render_cache.estimated_bytes <= RenderCache.MAX_ESTIMATED_BYTES,
		"Оценка памяти кеша ограничена")
	_check(_save_report(report), "Отчёт JSON сохранён")
	scene.queue_free()

	if not failures.is_empty():
		for reason in failures.slice(0, 20):
			push_error("Этап 8.7: " + reason)
		quit(1)
		return

	print("Этап 8.7: ", points.size(), " кадров, ",
		summary["chunks_built"], " GPU-построений, ",
		summary["cache_hits"], " попаданий кеша; p95 интервала ",
		"%.2f" % summary["interval_ms_p95"],
		" мс; быстро отсечено ", summary["visibility_fast_rejects"],
		"; отчёт ", _output_path())
	print("Этап 8.7: воспроизводимый маршрут и JSON-метрики — успешно.")
	quit(0)
