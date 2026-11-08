extends SceneTree
## #93/PBR: два одинаковых маршрута 370 кадров без/с общей
## физической сеткой цвета и материала. Software GL не равен GPU FPS.

const View = preload("res://scripts/world.gd")
const Runner = preload("res://scripts/world_benchmark_runner.gd")
const Route = preload("res://scripts/world_benchmark_route.gd")

var errors: Array[String] = []


func _check(ok: bool, reason: String) -> void:
	# Сверяем не только скорость, но количество построенных чанков,
	# память, кадры и физику между двумя одинаковыми маршрутами.
	if not ok:
		errors.append(reason)


func _path() -> String:
	# CI сохраняет машиночитаемый отчёт, пригодный для A/B.
	for part in OS.get_cmdline_user_args():
		if part.begins_with("--report="):
			return part.trim_prefix("--report=")
	return "user://pbr-physical-cells-route.json"


func _run() -> void:
	# Игровая сцена использует настоящие WorkerThreadPool,
	# ArrayMesh, растительность и гидрологию на обеих трассах.
	root.size = Vector2i(960, 540)
	var scene := View.new()
	root.add_child(scene)
	_check(scene._world_model != null and scene._camera != null,
		"Физическая карта и камера созданы")
	var report: Dictionary = await Runner.new().run_pbr_cache(scene, "physical")
	_check(report["task"] == "9.4.2/PBR-physical-cells",
		"Замерен именно кеш физических PBR-клеток")
	_check(report["physics_unchanged"] and report["setting_restored"],
		"Рельеф и климат не изменены, настройка возвращена")
	_check(not report["hardware_approval"] and report["gpu_frame_ms"] == null
		and report["vram_bytes"] == null,
		"Программный GL не выдаётся за FPS/VRAM реальной видеокарты")

	var passes: Array = report["passes"]
	_check(passes.size() == 2, "Оба маршрута выполнены")
	if passes.size() == 2:
		_check(not passes[0]["cache_enabled"] and passes[1]["cache_enabled"],
			"Первый маршрут без кеша, второй с общим кешем")
		for item in passes:
			var summary: Dictionary = item["summary"]
			_check(int(item["route_frames"]) == Route.samples(
				scene._world_model.config.width,
				scene._world_model.config.height).size(),
				"Все 370 кадров игровой трассы представлены")
			_check(int(summary["chunks_built"]) > 0 and
				float(summary["ground_prepare_worker_ms_total"]) > 0.0,
				"В обоих режимах реально строились PBR-чанки")
			_check(float(summary["interval_ms_p50"]) > 0.0
				and float(summary["interval_ms_p50"]) <=
				float(summary["interval_ms_p95"])
				and float(summary["interval_ms_p95"]) <=
				float(summary["interval_ms_p99"]),
				"Интервал кадров p50/p95/p99 монотонен")
			_check(item["phases"].size() == 9 and summary["physics_unchanged"],
				"Все девять фаз и физические инварианты сохранены")
		var before: Dictionary = passes[0]["summary"]
		var after: Dictionary = passes[1]["summary"]
		report["cpu_prepare_speedup"] = float(
			before["ground_prepare_worker_ms_total"]) / maxf(
			float(after["ground_prepare_worker_ms_total"]), 0.001)
		print("#93/PBR-CELLS-GL: CPU до/после = ",
			before["ground_prepare_worker_ms_total"], " / ",
			after["ground_prepare_worker_ms_total"], " мс, p95 кадра = ",
			before["interval_ms_p95"], " / ",
			after["interval_ms_p95"], " мс, чанки = ",
			before["chunks_built"], " / ", after["chunks_built"])
	report["passed"] = errors.is_empty()
	report["errors"] = errors
	var file := FileAccess.open(_path(), FileAccess.WRITE)
	_check(file != null, "Отчёт сохранён")
	if file != null:
		file.store_string(JSON.stringify(report, "\t") + "\n")
		file.close()
	scene.queue_free()
	await process_frame
	if not errors.is_empty():
		for message in errors:
			push_error("#93/PBR-CELLS-GL: " + message)
		quit(1)
		return
	print("#93/PBR-CELLS-GL: 740 кадров, PBR и физика — успешно")
	quit(0)


func _initialize() -> void:
	# Дождёмся готовности SceneTree перед созданием игрового мира.
	call_deferred("_run")
