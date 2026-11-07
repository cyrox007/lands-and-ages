extends SceneTree
## R4b/GL — парные игровые кадры земли с новой PBR-палитрой.
## Снимаем живую 3D-сцену, а не перерисовываем карту в Python
## или генеративной моделью. CI не подтверждает художественный допуск.

const View = preload("res://scripts/world.gd")
const Terrain = preload("res://scripts/terrain.gd")
const Config = preload("res://scripts/world_config.gd")
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
	return "user://terrain-palette-r4b"


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
				and not view._active.is_empty() \
				and view._active.size() >= view._wanted_chunks.size():
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


func _capture(directory: String, name: String) -> Image:
	# После изменения параметра материала ждём два GPU-кадра.
	# Записываем именно игровой Viewport, без генеративных картинок.
	await process_frame
	await process_frame
	var shot: Image = root.get_texture().get_image()
	var path := directory.path_join(name)
	_check(shot.get_size() == Size, "Размер настоящего PNG неверен")
	_check(shot.save_png(path) == OK, "Godot не записал " + name)
	_check(FileAccess.get_file_as_bytes(path).size() > 18000,
		"Кадр пустой или неполный: " + name)
	captures.append(name)
	return shot


func _difference(before: Image, after: Image, view_name: String) -> Dictionary:
	# Сравниваем изображения одной камеры по сетке пикселей.
	# Подсчёт изменений доказывает влияние материала, но не
	# заменяет художественную оценку реального скриншота.
	var samples := 0
	var changed := 0
	var maximum := 0.0
	var average := 0.0
	for y in range(0, Size.y, 5):
		for x in range(0, Size.x, 5):
			var a: Color = before.get_pixel(x, y)
			var b: Color = after.get_pixel(x, y)
			var diff := (absf(a.r - b.r) + absf(a.g - b.g) +
				absf(a.b - b.b)) / 3.0
			samples += 1
			average += diff
			maximum = maxf(maximum, diff)
			if diff > 0.025:
				changed += 1
	average /= float(maxi(1, samples))
	_check(changed >= 150,
		"Новая палитра действительно видна в ракурсе " + view_name)
	print("R4b/GL: ", view_name, " изменено ", changed,
		" / ", samples, ", средняя разница ", average)
	return {
		"camera": view_name, "sampled_pixels": samples,
		"changed_pixels": changed,
		"average_rgb_delta": average, "maximum_rgb_delta": maximum
	}


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

	# Панорама, вершина, предгорье и пасмурный кадр используют
	# один физический мир и неизменные настройки солнца.
	# До/после различается только художественная палитра R4b.
	var comparisons: Array[Dictionary] = []
	for angle in [
		{"name": "панорама", "zoom": 72.0,
			"offset": Vector2.ZERO, "cloud": 0.0},
		{"name": "вершина", "zoom": 50.0,
			"offset": Vector2.ZERO, "cloud": 0.0},
		{"name": "предгорье", "zoom": 58.0,
			"offset": Vector2(22.0, 28.0), "cloud": 0.0},
		{"name": "пасмурно", "zoom": 72.0,
			"offset": Vector2.ZERO, "cloud": 0.75}
	]:
		var name: String = angle["name"]
		view._center = Vector2(peak) + Vector2(angle["offset"])
		view._camera.size = float(angle["zoom"])
		view._update_camera()
		view._refresh_visible(true)
		view._update_material_detail()
		_check(await _wait_chunks(view), "Игровые чанки прогрузились: " + name)
		# Цвета сравниваем на неизменных высотах, деревьях,
		# солнце и климате. R4a включён для обоих кадров.
		view._ground_material.set_shader_parameter("rock_face_detail", 1.0)
		view._ground_material.set_shader_parameter(
			"cloud_coverage", float(angle["cloud"]))
		view._ground_material.set_shader_parameter(
			"terrain_palette_strength", 0.0)
		var before: Image = await _capture(directory, name + "_до.png")
		view._ground_material.set_shader_parameter(
			"terrain_palette_strength", 1.0)
		var after: Image = await _capture(directory, name + "_после.png")
		var diff: Dictionary = _difference(before, after, name)
		diff["zoom"] = angle["zoom"]
		diff["center"] = [view._center.x, view._center.y]
		diff["cloud_coverage"] = angle["cloud"]
		comparisons.append(diff)

	var manifest := {
		"stage": "relief/R4b", "real_game_world": true,
		"software_opengl": true, "hardware_fps_verified": false,
		"artistic_approval": false, "reference_approved": false,
		"terrain_version": Config.TERRAIN_VERSION,
		"seed": view._world_model.config.world_seed,
		"peak": {"x": peak.x, "y": peak.y, "elevation": summary["height"]},
		"comparisons": comparisons,
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
			push_error("R4b/GL: " + message)
		quit(1)
		return
	print("R4b/GL: четыре реальные пары земли до/после — успешно.")
	quit(0)


func _initialize() -> void:
	call_deferred("_run")
