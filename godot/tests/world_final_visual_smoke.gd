extends SceneTree
## Этап 8.8: полная приёмка быстрого отсечения и маршрута на устройстве.
## Не изменяем законы мира и не выдаём headless за аппаратные FPS.

const View = preload("res://scripts/world.gd")
const Visibility = preload("res://scripts/chunk_visibility.gd")
const Route = preload("res://scripts/world_benchmark_route.gd")

var failures: Array[String] = []


func _check(ok: bool, message: String) -> void:
	if not ok:
		failures.append(message)


func _test_horizontal_projection() -> void:
	var bounds := Rect2i(Vector2i(0, 0), Vector2i(16, 16))
	var camera := Vector3(8.0, 30.0, 8.0)
	_check(Visibility.horizontal_intersects(bounds, camera,
		Vector3.RIGHT, 16.0, 1.0),
		"Видимый по горизонтали чанк проходит первую проверку")
	_check(not Visibility.horizontal_intersects(bounds,
		camera + Vector3(100.0, 0.0, 0.0),
		Vector3.RIGHT, 16.0, 1.0),
		"Далёкий боковой чанк отсекается до чтения высот")
	_check(Visibility.horizontal_intersects(bounds,
		camera + Vector3(100.0, 0.0, 0.0),
		Vector3(0.7, 0.4, 0.5).normalized(), 16.0, 1.0),
		"При наклонённой боковой оси используется безопасная точная проверка")
	_check(not Visibility.horizontal_intersects(Rect2i(), camera,
		Vector3.RIGHT, 16.0, 1.0),
		"Пустой прямоугольник не становится видимым")


func _compare_exact_visibility(scene: Node3D) -> int:
	var camera: Camera3D = scene._camera
	var dimensions: Vector2 = camera.get_viewport().get_visible_rect().size
	var aspect: float = dimensions.x / maxf(dimensions.y, 1.0)
	var right: Vector3 = camera.global_transform.basis.x
	var up: Vector3 = camera.global_transform.basis.y
	var position: Vector3 = camera.global_position
	var count: Vector2i = scene._world_model.config.chunk_count()
	var matches := 0
	for y in range(count.y):
		for x in range(count.x):
			var coord := Vector2i(x, y)
			var bounds: Rect2i = scene._world_model.config.chunk_rect(coord)
			var elevation: Vector2 = scene._chunk_elevation_bounds(coord)
			var expected := Visibility.intersects(bounds, elevation,
				position, right, up, camera.size, aspect)
			if expected != scene._wanted_chunks.has(coord):
				_check(false, "Отсечение изменило видимость чанка " + str(coord))
			else:
				matches += 1
	return matches


func _test_camera_positions(scene: Node3D) -> void:
	var before: Dictionary = scene._world_model.to_data()
	var positions := [
		Vector2(1.0, 1.0), Vector2(255.0, 191.0),
		Vector2(1.0, 191.0), Vector2(255.0, 1.0),
		Vector2(128.0, 96.0), Vector2(20.0, 100.0),
		Vector2(230.0, 30.0), Vector2(70.0, 160.0)
	]
	var comparisons := 0
	for size in [16.0, 44.0, 66.0, 105.0]:
		scene._change_zoom(size / scene._camera.size)
		for target in positions:
			scene._move_center(target - scene._center)
			comparisons += _compare_exact_visibility(scene)
			_check(scene._chunk_height_bounds.size() <=
				View.HEIGHT_BOUNDS_CACHE_LIMIT,
				"Кеш высот не превышает лимит во время обхода карты")
			_check(scene._render_cache.estimated_bytes <=
				scene._render_cache.MAX_ESTIMATED_BYTES,
				"Кеш графики ограничен при движении по краям")
	_check(scene._visibility_fast_rejects > 0,
		"Быстрое отсечение реально сокращает число точных проверок")
	_check(scene._visibility_precise_checks > 0,
		"После предварительного фильтра выполняются точные проверки")
	_check(scene._world_model.to_data() == before,
		"Обход камеры не изменил физическое сохранение")
	print("Этап 8.8: сопоставлено ", comparisons, " чанков; ранних отказов ",
		scene._visibility_fast_rejects,
		"; точных проверок ", scene._visibility_precise_checks)


func _test_device_benchmark(scene: Node3D) -> void:
	var before: Dictionary = scene._world_model.to_data()
	var saved_center: Vector2 = scene._center
	var saved_zoom: float = scene._camera.size
	var button_present := false
	for item in scene._debug_details.get_children():
		if item is Button and item.text.contains("8.8"):
			button_present = true
	_check(button_present,
		"В диагностике доступен запуск маршрута на реальном устройстве")
	await scene._run_device_benchmark()
	_check(not scene._benchmark_running,
		"После завершения испытания управление разблокировано")
	_check(scene._center.is_equal_approx(saved_center) and
		is_equal_approx(scene._camera.size, saved_zoom),
		"После маршрута восстанавливаются позиция и масштаб камеры")
	_check(scene._world_model.to_data() == before,
		"Встроенный маршрут не изменяет физическую карту")
	var path := "user://world-camera-8-8-device.json"
	_check(FileAccess.file_exists(path), "Отчёт создан в папке пользователя")
	if not FileAccess.file_exists(path):
		return
	var file := FileAccess.open(path, FileAccess.READ)
	_check(file != null, "Файл испытаний доступен для чтения")
	if file == null:
		return
	var decoded: Variant = JSON.parse_string(file.get_as_text())
	file.close()
	_check(decoded is Dictionary, "JSON устройства содержит объект")
	if not decoded is Dictionary:
		return
	var report: Dictionary = decoded
	_check(int(report.get("route_frames", 0)) == Route.samples(
		scene._world_model.config.width,
		scene._world_model.config.height).size(),
		"Устройство выполняет тот же фиксированный маршрут, что CI")
	_check((report.get("phases", []) as Array).size() == 9,
		"Отчёт устройства включает все девять фаз")
	var summary: Dictionary = report["summary"]
	_check(summary.get("physics_unchanged", false),
		"Встроенный тест проверил неизменность физики")
	_check(int(summary.get("chunks_built", 0)) > 0,
		"В отчёте учтена реальная сборка GPU-чанков")
	_check(int(summary.get("visibility_fast_rejects", 0)) > 0,
		"В отчёте есть статистика быстрого отсечения")
	_check(report.get("headless", false),
		"CI явно маркирует отсутствие реальной GPU-проверки")
	print("Этап 8.8: встроенный маршрут — ",
		report["route_frames"], " кадров, p95 ",
		"%.2f" % summary["interval_ms_p95"], " мс")


func _initialize() -> void:
	_run()


func _run() -> void:
	await process_frame
	_test_horizontal_projection()
	var scene := View.new()
	get_root().add_child(scene)
	if scene._world_model == null:
		push_error("Этап 8.8: сцена Godot не инициализирована")
		quit(1)
		return
	_test_camera_positions(scene)
	await _test_device_benchmark(scene)
	scene.queue_free()
	if not failures.is_empty():
		for reason in failures.slice(0, 20):
			push_error("Этап 8.8: " + reason)
		quit(1)
		return
	print("Этап 8.8: быстрое отсечение, геометрия и встроенные замеры — успешно.")
	quit(0)
