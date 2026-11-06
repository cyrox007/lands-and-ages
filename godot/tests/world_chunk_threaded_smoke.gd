extends SceneTree
## Многопоточная подготовка чанков: массивы — worker, ресурсы — main.

const View = preload("res://scripts/world.gd")
const Chunk = preload("res://scripts/chunk.gd")
const Worker = preload("res://scripts/chunk_build_worker.gd")
const Water = preload("res://scripts/water_mesh.gd")

var errors: Array[String] = []


func _check(ok: bool, reason: String) -> void:
	if not ok:
		errors.append(reason)


func _run() -> void:
	await process_frame
	var view := View.new()
	get_root().add_child(view)
	_check(not view._pending.is_empty(), "После загрузки есть план чанков")
	if view._pending.is_empty():
		view.queue_free()
		quit(1)
		return
	var coord: Vector2i = view._pending[0]
	var map_before: Dictionary = view._world_model.to_data()
	var water_before: Dictionary = view._hydro.to_snapshot()
	var surface_before: Dictionary = view._surface.to_snapshot()

	# Независимая подготовка в WorkerThreadPool выдаёт ту же геометрию,
	# что синхронный путь 8.1–9.3, включая RGBA8 и оба UV-канала.
	var job := Worker.new(coord, 0, view._world_model, view._surface,
		view._climate, view._hydro)
	var task: int = WorkerThreadPool.add_task(job.run, false,
		"Тест фоновой подготовки")
	WorkerThreadPool.wait_for_task_completion(task)
	_check(job.prepare_us > 0 and job.arrays.size() == Mesh.ARRAY_MAX,
		"CPU-маски вычислены без GPU и дерева сцены")
	var synchronous := Chunk.create_mesh(coord.x, coord.y, 1,
		view._world_model, view._surface, 0, view._climate, view._hydro)
	var prepared := Chunk.mesh_from_arrays(job.arrays)
	var water_sync := Water.prepare_arrays(view._world_model, view._hydro,
		coord, view._surface)
	_check(job.water_arrays == water_sync,
		"Фоновая геометрия воды совпадает с синхронной во всех каналах")
	var normal: Array = synchronous.surface_get_arrays(0)
	var background: Array = prepared.surface_get_arrays(0)
	for channel in [Mesh.ARRAY_VERTEX, Mesh.ARRAY_NORMAL, Mesh.ARRAY_COLOR,
			Mesh.ARRAY_TEX_UV, Mesh.ARRAY_TEX_UV2, Mesh.ARRAY_CUSTOM0,
			Mesh.ARRAY_INDEX]:
		_check(normal[channel] == background[channel],
			"Многопоточный расчёт сохраняет массив %d" % channel)

	var cancelled := Worker.new(coord, 0, view._world_model, view._surface,
		view._climate, view._hydro)
	cancelled.cancel()
	var cancelled_task := WorkerThreadPool.add_task(cancelled.run)
	WorkerThreadPool.wait_for_task_completion(cancelled_task)
	_check(cancelled.arrays.is_empty() and cancelled.water_arrays.is_empty(),
		"Устаревшее задание прекращается до построения массивов")

	# Очередь сцены ограничена двумя заданиями, а результат попадает
	# в Node только из основного потока Godot.
	view._start_chunk_jobs()
	_check(view._chunk_jobs.size() > 0 and
		view._chunk_jobs.size() <= View.MAX_CONCURRENT_CHUNK_JOBS,
		"На CPU работают не больше двух независимых заданий")
	var deadline := Time.get_ticks_msec() + 15000
	while view._chunk_rebuilds == 0 and Time.get_ticks_msec() < deadline:
		await process_frame
	_check(view._chunk_rebuilds > 0 and not view._active.is_empty(),
		"Готовый массив передан в GPU через основной поток")
	_check(view._total_ground_prepare_us > 0 and
		view._total_ground_upload_us >= 0,
		"Затраты подготовки и отправки в GPU измеряются отдельно")

	# Изменение вида инвалидирует уже начатую подготовку. При
	# повторном открытии сцены нельзя применить старую маску.
	view._change_zoom(0.25)
	view._cycle_view()
	view._start_chunk_jobs()
	var obsolete: int = view._chunk_generation
	view._cycle_view()
	_check(view._chunk_generation > obsolete,
		"Смена режима делает результаты воркера устаревшими")
	view._wait_chunk_jobs()
	_check(view._chunk_jobs.is_empty(),
		"Остановка сцены ожидает завершения всех потоков")

	_check(view._world_model.to_data() == map_before and
		view._hydro.to_snapshot() == water_before and
		view._surface.to_snapshot() == surface_before,
		"Потоки не изменили карту, гидрологию и состояние грунта")
	view.queue_free()
	if not errors.is_empty():
		for reason in errors:
			push_error("Фоновые чанки: " + reason)
		quit(1)
		return
	print("Фоновые чанки: параллельная подготовка и смена режимов — успешно.")
	quit(0)


func _initialize() -> void:
	_run()
