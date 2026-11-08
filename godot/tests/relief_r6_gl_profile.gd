extends SceneTree
## R6/GL — два сравнимых запуска игрового маршрута камеры на Godot.
## Сравнение не выдаёт программный OpenGL за реальный GPU ПК/Android.

const View = preload("res://scripts/world.gd")
const Runner = preload("res://scripts/world_benchmark_runner.gd")
const Config = preload("res://scripts/world_config.gd")

const SIZE := Vector2i(960, 540)
const EXPECTED_ROUTE_FRAMES := 370
var failures: Array[String] = []


func _check(valid: bool, reason: String) -> void:
	# Отдельные неисправности маршрута и отчёта записываем
	# независимо: результат будет понятен без запуска редактора.
	if not valid:
		failures.append(reason)


func _report_path() -> String:
	# Выход CI хранится отдельно от сохранения пользовательского
	# мира; локальный запуск пишет файл в user://.
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--report="):
			return arg.trim_prefix("--report=")
	return "user://relief-r6-gl.json"


func _check_pass(measurement: Dictionary) -> void:
	# Данные получены от существующего WorldBenchmarkRunner.run:
	# никакой подстановки условных FPS либо чисел GPU не допускаем.
	var summary: Dictionary = measurement["summary"]
	var intervals := [
		float(summary["interval_ms_p50"]),
		float(summary["interval_ms_p95"]),
		float(summary["interval_ms_p99"])
	]
	_check(measurement["route_frames"] == EXPECTED_ROUTE_FRAMES,
		"R6: записан весь маршрут из 370 реальных кадров")
	_check(intervals[0] > 0.0 and intervals[0] <= intervals[1]
		and intervals[1] <= intervals[2],
		"R6: p50/p95/p99 упорядочены и не равны нулю")
	_check(int(summary["chunks_built"]) > 0,
		"R6: построены настоящие чанки игровой сцены")
	_check(float(summary["ground_mesh_cpu_ms_total"]) > 0.0,
		"R6: посчитана CPU-стоимость построения земли")
	_check(int(summary["peak_godot_static_bytes"]) > 0,
		"R6: собрана оценка статической памяти Godot")
	_check(bool(summary["physics_unchanged"]),
		"R6: материал не меняет WorldMap при проходе камеры")
	for phase in measurement["phases"]:
		_check(phase["cache_limits_valid"],
			"R6: лимиты графического кеша не нарушены")
		_check(int(phase["frames"]) > 0, "R6: фаза маршрута не пуста")


func _run() -> void:
	# Используем настоящую стартовую сцену, физику и GPU-чанки,
	# фиксируя разрешение и seed. Не отключаем воду/лес/климат
	# ради искусственного увеличения результатов измерений.
	root.size = SIZE
	var view := View.new()
	root.add_child(view)
	_check(view._world_model != null and view._camera != null,
		"R6: создан реальный World с камерой")
	var report: Dictionary = await Runner.new().run_relief(view)
	_check(bool(report["physics_unchanged"]),
		"R6: оба профиля сохранили физику грунта, высоты и сток")
	_check(bool(report["material_restored"]),
		"R6: исходные параметры шейдера восстановлены")
	_check(report["gpu_frame_ms"] == null and report["vram_bytes"] == null,
		"R6: программный GL не подменён замером VRAM")
	_check(not bool(report["hardware_approval"]),
		"R6: аппаратный допуск требует реальных ПК/Android")
	_check(report["seed"] == Config.DEFAULT_SEED,
		"R6: известный seed используется в обоих проходах")
	var passes: Array = report["passes"]
	_check(passes.size() == 2, "R6: выполнены оба материала")
	if passes.size() == 2:
		_check(float(passes[0]["terrain_palette_strength"]) == 0.0
			and float(passes[1]["terrain_palette_strength"]) == 1.0,
			"R6: материал сравнивается без изменения физики")
		for measured in passes:
			_check_pass(measured)
	report["passed"] = failures.is_empty()
	report["failures"] = failures
	var file := FileAccess.open(_report_path(), FileAccess.WRITE)
	_check(file != null, "R6: отчёт GL записан")
	if file != null:
		file.store_string(JSON.stringify(report, "\t") + "\n")
		file.close()
	view.queue_free()
	await process_frame
	if not failures.is_empty():
		for reason in failures:
			push_error(reason)
		quit(1)
		return
	print("R6/GL: два игровых маршрута, 740 кадров, p50/p95/p99 — успешно.")
	quit(0)


func _initialize() -> void:
	# Живой World и его HUD создаются после запуска SceneTree.
	call_deferred("_run")
