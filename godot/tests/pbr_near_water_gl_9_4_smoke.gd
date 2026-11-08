extends SceneTree
## 9.4.2/PBR — два реальных маршрута по 370 кадров без/с кешем берега.
## Программный OpenGL не считается аппаратной приёмкой FPS или VRAM.

const View = preload("res://scripts/world.gd")
const Runner = preload("res://scripts/world_benchmark_runner.gd")
const Route = preload("res://scripts/world_benchmark_route.gd")

var failures: Array[String] = []


func _check(ok: bool, reason: String) -> void:
	# Сохраняем отдельные нарушения маршрута, памяти, физики и
	# настроек: сам по себе меньший p95 не означает корректный код.
	if not ok:
		failures.append(reason)


func _path() -> String:
	# В CI отчёт сохраняется рядом с журналами Godot; в игре
	# используется штатная область пользовательских данных.
	for item in OS.get_cmdline_user_args():
		if item.begins_with("--report="):
			return item.trim_prefix("--report=")
	return "user://pbr-near-water-route.json"


func _run() -> void:
	# Настоящая сцена строит воду, землю, лес и коллизии через
	# те же CPU-воркеры и ArrayMesh, что при игре.
	root.size = Vector2i(960, 540)
	var scene := View.new()
	root.add_child(scene)
	_check(scene._world_model != null and scene._camera != null,
		"Игровой World создал физическую карту и камеру")
	var report: Dictionary = await Runner.new().run_pbr_cache(scene)
	_check(bool(report["physics_unchanged"])
		and bool(report["setting_restored"]),
		"Маршрут не изменяет физику и возвращает режим кеша")
	_check(not report["hardware_approval"]
		and report["gpu_frame_ms"] == null
		and report["vram_bytes"] == null,
		"Программный GL не выдаётся за аппаратный тест")
	var passes: Array = report["passes"]
	_check(passes.size() == 2, "Оба режима прошли один маршрут")
	if passes.size() == 2:
		_check(passes[0]["cache_enabled"] == false
			and passes[1]["cache_enabled"] == true,
			"Режим кеша действительно переключился")
		for measured in passes:
			var summary: Dictionary = measured["summary"]
			_check(int(measured["route_frames"]) == Route.samples(
				scene._world_model.config.width,
				scene._world_model.config.height).size(),
				"Получены все 370 контрольных кадров")
			_check(int(summary["chunks_built"]) > 0,
				"Маршрут создал настоящие GPU-чанки")
			_check(float(summary["ground_prepare_worker_ms_total"]) > 0.0,
				"Профиль содержит время CPU подготовки грунта")
			_check(float(summary["interval_ms_p50"]) > 0.0
				and float(summary["interval_ms_p50"]) <=
					float(summary["interval_ms_p95"])
				and float(summary["interval_ms_p95"]) <=
					float(summary["interval_ms_p99"]),
				"Интервалы p50/p95/p99 корректно упорядочены")
			_check(bool(summary["physics_unchanged"]),
				"Физика осталась неизменной в каждом проходе")
			_check(measured["phases"].size() == 9,
				"Измерены все девять фаз маршрута")
		var before: Dictionary = passes[0]["summary"]
		var after: Dictionary = passes[1]["summary"]
		report["cpu_prepare_speedup"] = float(
			before["ground_prepare_worker_ms_total"]) / maxf(
				float(after["ground_prepare_worker_ms_total"]), 0.001)
		print("9.4.2/GL: CPU подготовки до/после = ",
			before["ground_prepare_worker_ms_total"], " / ",
			after["ground_prepare_worker_ms_total"], " мс; p95 кадра = ",
			before["interval_ms_p95"], " / ", after["interval_ms_p95"], " мс")
	report["passed"] = failures.is_empty()
	report["failures"] = failures
	var file := FileAccess.open(_path(), FileAccess.WRITE)
	_check(file != null, "JSON-отчёт записан")
	if file != null:
		file.store_string(JSON.stringify(report, "\t") + "\n")
		file.close()
	scene.queue_free()
	await process_frame
	if not failures.is_empty():
		for reason in failures:
			push_error("9.4.2/PBR-GL: " + reason)
		quit(1)
		return
	print("9.4.2/PBR-GL: 740 кадров и физические инварианты — успешно.")
	quit(0)


func _initialize() -> void:
	# Сцена Godot готова после одного кадра SceneTree.
	call_deferred("_run")
