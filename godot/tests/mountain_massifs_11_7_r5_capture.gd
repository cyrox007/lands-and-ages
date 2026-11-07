extends SceneTree
## R5/GL — два настоящих снимка гор из игрового Godot.
## Снимаем живую 3D-сцену, а не перерисовываем карту в Python
## или генеративной моделью. CI не подтверждает художественный допуск.

const View = preload("res://scripts/world.gd")
const Terrain = preload("res://scripts/terrain.gd")
const Size := Vector2i(960, 540)
const WaitFrames := 480

var failures: Array[String] = []
var captures: Array[String] = []


func _check(ok: bool, message: String) -> void:
	# Реальные кадры и исходные геометрические числа сохраняем
	# вместе, чтобы автор мог оценить стиль, не открывая Godot.
	if not ok:
		failures.append(message)


func _out_dir() -> String:
	# GitHub CI передаёт /tmp; локальный запуск не записывает
	# ничего в основной каталог пользовательских сохранений.
	for value in OS.get_cmdline_user_args():
		if value.begins_with("--out="):
			return value.trim_prefix("--out=")
	return "user://mountain-r5"


func _wait_chunks(view: Node3D) -> bool:
	# Камера может начать перестроение фоновых чанков. Ждём
	# окончания GPU-мешей и пересборки природных коллизий.
	for frame in range(WaitFrames):
		await process_frame
		if view._day_task_id >= 0 or view._days_pending > 0:
			continue
		if view._chunk_jobs.is_empty() and view._pending.is_empty() \
				and view._rebuild_pending.is_empty() \
				and view._nature_dirty.is_empty() \
				and not view._active.is_empty():
			await process_frame
			await process_frame
			return true
	_check(false, "Не завершилась визуализация реальных чанков")
	return false


func _peak(world: RefCounted) -> Dictionary:
	# Находим высочайшую вершину в настоящем массиве конкретного
	# seed. Запрос использует WorldMap, а не подобранную картинку.
	var seed: int = world.config.world_seed
	var center := Vector2(-1.0, -1.0)
	for gy in range(3):
		for gx in range(4):
			if Terrain._form_index(gx, gy, seed) != 4:
				continue
			var jitter_x := (Terrain.hash2(gx, gy, seed + 11) - 0.5) * 0.32
			var jitter_y := (Terrain.hash2(gx, gy, seed + 12) - 0.5) * 0.32
			var point := Vector2((float(gx) + 0.5 + jitter_x) * 72.0,
				(float(gy) + 0.5 + jitter_y) * 72.0)
			if point.x >= 30.0 and point.y >= 30.0 \
					and point.x < float(world.config.width) - 30.0 \
					and point.y < float(world.config.height) - 30.0:
				center = point
				break
		if center.x >= 0.0:
			break
	_check(center.x >= 0.0, "На игровой карте найден горный массив")
	if center.x < 0.0:
		return {}
	var best := -INF
	var summit := Vector2i.ZERO
	for y in range(roundi(center.y) - 20, roundi(center.y) + 21, 2):
		for x in range(roundi(center.x) - 20, roundi(center.x) + 21, 2):
			if not world.config.contains_vertex(Vector2i(x, y)):
				continue
			var h: float = world.vertex_at(Vector2i(x, y))
			if h > best:
				best = h
				summit = Vector2i(x, y)
	return {"cell": summit, "height": best}


func _capture(directory: String, name: String) -> void:
	# Изображение берём строго из 3D Viewport после двух кадров
	# рендеринга, оно содержит реальные шейдеры, меши и освещение.
	await process_frame
	await process_frame
	var shot: Image = root.get_texture().get_image()
	var path := directory.path_join(name)
	_check(shot.get_size() == Size, "Размер настоящего PNG неверен")
	_check(shot.save_png(path) == OK, "Godot не записал " + name)
	_check(FileAccess.get_file_as_bytes(path).size() > 18000,
		"Кадр пустой или неполный: " + name)
	captures.append(name)


func _run() -> void:
	var directory := _out_dir()
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(directory))
	root.size = Size
	var view := View.new()
	root.add_child(view)
	for child in view.get_children():
		if child is CanvasLayer:
			child.visible = false
	var summary: Dictionary = _peak(view._world_model)
	if summary.is_empty():
		view.queue_free()
		quit(1)
		return
	var peak: Vector2i = summary["cell"]
	_check(float(summary["height"]) >= 18.0,
		"В тестовом игровом мире вершина выше обычного холма")

	# Кадр издалека показывает связность гряды, ближний — острые
	# участки, предгорья, материал, деревья и реальную высоту.
	view._center = Vector2(peak)
	view._camera.size = 92.0
	view._update_camera()
	view._refresh_visible(true)
	_check(await _wait_chunks(view), "Панорама прогрузилась")
	await _capture(directory, "горный_массив.png")

	view._camera.size = 50.0
	view._update_camera()
	view._refresh_visible(true)
	_check(await _wait_chunks(view), "Вершина прогрузилась")
	await _capture(directory, "горные_вершины.png")

	var manifest := {
		"stage": "11.7/R5", "real_game_world": true,
		"software_opengl": true, "hardware_fps_verified": false,
		"artistic_approval": false,
		"terrain_version": view._world_model.config.TERRAIN_VERSION,
		"peak": {"x": peak.x, "y": peak.y, "elevation": summary["height"]},
		"captures": captures, "passed": failures.is_empty(),
		"failures": failures
	}
	var file := FileAccess.open(directory.path_join("manifest.json"),
		FileAccess.WRITE)
	_check(file != null, "Манифест визуального теста записан")
	if file != null:
		file.store_string(JSON.stringify(manifest, "  "))
		file.close()
	view.queue_free()
	await process_frame
	if not failures.is_empty():
		for message in failures:
			push_error("11.7/R5/GL: " + message)
		quit(1)
		return
	print("11.7/R5/GL: настоящие панорама и вершины Godot — успешно.")
	quit(0)


func _initialize() -> void:
	call_deferred("_run")
