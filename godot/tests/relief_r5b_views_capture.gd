extends SceneTree
## R5b: физически выбранные овраг, бровка, плато и берег.
## Снимаем восемь PNG из настоящей сцены Godot в двух масштабах.
## Программный OpenGL не заменяет художественную и аппаратную приёмку.

const View = preload("res://scripts/world.gd")
const Terrain = preload("res://scripts/terrain.gd")
const Chunk = preload("res://scripts/chunk.gd")
const Features = preload("res://scripts/relief_visual_features.gd")
const Config = preload("res://scripts/world_config.gd")
const Size := Vector2i(960, 540)
const WaitFrames := 540
const ZoomNear := 40.0
const ZoomFar := 94.0

var failures: Array[String] = []
var captures: Array[String] = []


func _check(valid: bool, reason: String) -> void:
	# Ошибки накапливаются, чтобы CI сообщил обо всех нарушениях
	# физических инвариантов и полноты кадров за один прогон.
	if not valid:
		failures.append(reason)


func _output_directory() -> String:
	# В CI выбирается временная папка; локальный запуск сохраняет
	# файлы в user://, не изменяя данные игрового мира.
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--out="):
			return argument.trim_prefix("--out=")
	return "user://relief-r5b-views"


func _feature_center(world: RefCounted, kind: int) -> Vector2i:
	# Ищем настоящий географический объект через индекс формы
	# и seed текущего мира. Центр совпадает с генератором Terrain.
	var seed: int = world.config.world_seed
	for gy in range(-1, 4):
		for gx in range(-1, 5):
			if Terrain._form_index(gx, gy, seed) != kind:
				continue
			var jitter_x: float = (Terrain.hash2(gx, gy, seed + 11) - 0.5) * 0.32
			var jitter_y: float = (Terrain.hash2(gx, gy, seed + 12) - 0.5) * 0.32
			var point := Vector2i(
				roundi((float(gx) + 0.5 + jitter_x) * Terrain.FEATURE_STEP),
				roundi((float(gy) + 0.5 + jitter_y) * Terrain.FEATURE_STEP))
			if point.x >= 18 and point.y >= 18 \
					and point.x < world.config.width - 18 \
					and point.y < world.config.height - 18:
				return point
	_check(false, "Не найден физический центр формы %d" % kind)
	return Vector2i(-1, -1)


func _ravine_and_rim(world: RefCounted) -> Dictionary:
	# Уточняем дно оврага по реальной вогнутости WorldMap;
	# для бровки ищем соседний более высокий и крутой участок.
	var center := _feature_center(world, 6)
	if center.x < 0:
		return {}
	var bottom := center
	var highest_concavity := -1.0
	for dy in range(-12, 13, 2):
		for dx in range(-12, 13, 2):
			var cell := center + Vector2i(dx, dy)
			if not world.config.contains_cell(cell):
				continue
			var concavity: float = Features.sample_at(world, cell).y
			if concavity > highest_concavity:
				highest_concavity = concavity
				bottom = cell
	var rim := bottom
	var rim_score := -INF
	var bottom_height: float = world.vertex_at(bottom)
	for dy in range(-14, 15, 2):
		for dx in range(-14, 15, 2):
			var offset := Vector2i(dx, dy)
			if offset.length() < 5.0:
				continue
			var cell := bottom + offset
			if not world.config.contains_cell(cell):
				continue
			var height: float = world.vertex_at(cell)
			var normal: Vector3 = world.normal_at(cell)
			var slope := Vector2(normal.x, normal.z).length()
			var score := (height - bottom_height) * 0.35 + slope
			if score > rim_score:
				rim_score = score
				rim = cell
	_check(highest_concavity > 0.0, "В овраге есть физическая вогнутость")
	_check(rim != bottom and world.vertex_at(rim) > bottom_height,
		"Найдена поднятая бровка реального оврага")
	return {"овраг": bottom, "бровка": rim}


func _coast(world: RefCounted, hydro: RefCounted) -> Vector2i:
	# Берег выбирается не по цвету шейдера: сухая клетка должна
	# непосредственно соседствовать с физическим морем.
	hydro.ensure_ready()
	var directions := [
		Vector2i.LEFT, Vector2i.RIGHT, Vector2i.UP, Vector2i.DOWN
	]
	for y in range(4, world.config.height - 4):
		for x in range(4, world.config.width - 4):
			var cell := Vector2i(x, y)
			if hydro.has_water(hydro.cell_index(cell)):
				continue
			for direction in directions:
				var neighbor: Vector2i = cell + direction
				if hydro.ocean_at(hydro.cell_index(neighbor)):
					return cell
	_check(false, "Не найден настоящий берег моря, соседний с сушей")
	return Vector2i(-1, -1)


func _landmarks(view: Node3D) -> Dictionary:
	# Формируем четыре независимых физических ракурса.
	# Ни одна координата не берётся из изображения или рендера.
	var result := _ravine_and_rim(view._world_model)
	result["плато"] = _feature_center(view._world_model, 3)
	result["берег"] = _coast(view._world_model, view._hydro)
	for name in result:
		var cell: Vector2i = result[name]
		_check(view._world_model.config.contains_cell(cell),
			"Ракурс %s расположен внутри физической карты" % name)
	return result


func _verify_mesh(view: Node3D, point: Vector2i, label: String) -> Dictionary:
	# Визуальный ArrayMesh должен содержать исходную вершину карты.
	# Смена детализации не имеет права деформировать WorldMap.
	var world: RefCounted = view._world_model
	var chunk: Vector2i = world.config.chunk_of(point)
	if chunk.x < 0:
		_check(false, "Неверный чанк ракурса " + label)
		return {}
	var arrays: Array = Chunk.prepare_arrays(chunk.x, chunk.y, 1,
		world, view._surface, 0, view._climate, view._hydro)
	var physical: Vector3 = world.config.to_scene(
		Vector2(point), world.vertex_at(point))
	var found := false
	for vertex in arrays[Mesh.ARRAY_VERTEX]:
		if (vertex as Vector3).distance_to(physical) < 0.001:
			found = true
			break
	_check(found, "Меш совпадает с физической вершиной: " + label)
	return {"x": point.x, "y": point.y,
		"elevation": world.vertex_at(point),
		"chunk": [chunk.x, chunk.y], "mesh_vertex_found": found}


func _wait_chunks(view: Node3D, label: String) -> bool:
	# Ждём построения всех видимых чанков после изменения камеры.
	# Задержка не подменяется фиксированным временем в секундах.
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
	_check(false, "Чанки не загрузились: " + label)
	return false


func _capture(directory: String, name: String) -> void:
	# Сохраняем настоящий Viewport с PBR, водой и освещением,
	# а не программный рисунок по рассчитанным высотам.
	await process_frame
	await process_frame
	var shot: Image = root.get_texture().get_image()
	var path := directory.path_join(name)
	_check(shot.get_size() == Size, "Неверное разрешение " + name)
	_check(shot.save_png(path) == OK, "PNG не сохранён: " + name)
	_check(FileAccess.get_file_as_bytes(path).size() > 18000,
		"Пустой или неполный игровой кадр: " + name)
	captures.append(name)


func _run() -> void:
	# Сначала определяем воспроизводимые ландшафтные ориентиры
	# и запоминаем состояние физики до любого изменения камеры.
	var directory := _output_directory()
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(directory))
	root.size = Size
	var view := View.new()
	root.add_child(view)
	for child in view.get_children():
		if child is CanvasLayer:
			child.visible = false
	var world: RefCounted = view._world_model
	var before_map: Dictionary = world.to_data()
	var before_surface: Dictionary = view._surface.to_snapshot()
	var before_hydro: Dictionary = view._hydro.to_snapshot()
	var landmarks := _landmarks(view)
	if not failures.is_empty():
		view.queue_free()
		quit(1)
		return

	# Измеряем точные позиции в игровой геометрии; затем для
	# каждого места снимаем два разных настоящих масштаба LOD.
	var anchors := {}
	var comparisons: Array[Dictionary] = []
	for label in ["овраг", "бровка", "плато", "берег"]:
		var point: Vector2i = landmarks[label]
		anchors[label] = _verify_mesh(view, point, label)
		var levels: Array[Dictionary] = []
		for setting in [
			{"label": "близко", "zoom": ZoomNear},
			{"label": "далеко", "zoom": ZoomFar}
		]:
			var zoom: float = float(setting["zoom"])
			var name: String = "%s_%s.png" % [label, setting["label"]]
			view._center = Vector2(point)
			view._camera.size = zoom
			view._update_camera()
			view._refresh_visible(true)
			view._update_material_detail()
			_check(await _wait_chunks(view, name),
				"Полная загрузка чанков " + name)
			var detail: float = view._ground_material.get_shader_parameter(
				"detail_strength")
			await _capture(directory, name)
			levels.append({"file": name, "zoom": zoom,
				"detail_strength": detail, "visible_chunks": view._active.size()})
		_check(float(levels[0]["detail_strength"]) >
			float(levels[1]["detail_strength"]),
			"Дальний LOD ослабляет детализацию: " + label)
		comparisons.append({"name": label, "levels": levels})

	# Рендер не должен менять природу, сток, высоты и сохранения.
	_check(before_map == world.to_data(), "Камера не изменила WorldMap")
	_check(before_surface == view._surface.to_snapshot(),
		"Камера не изменила физическую поверхность")
	_check(before_hydro == view._hydro.to_snapshot(),
		"Камера не изменила гидрологию")
	var report := {
		"stage": "relief/R5b-technical",
		"seed": world.config.world_seed,
		"terrain_version": Config.TERRAIN_VERSION,
		"real_game_world": true,
		"software_opengl": true,
		"hardware_fps_verified": false,
		"artistic_approval": false,
		"reference_approved": false,
		"anchors": anchors,
		"comparisons": comparisons,
		"captures": captures,
		"passed": failures.is_empty(),
		"failures": failures
	}
	var file := FileAccess.open(directory.path_join("manifest.json"),
		FileAccess.WRITE)
	_check(file != null, "Манифест R5b записан")
	if file != null:
		file.store_string(JSON.stringify(report, "  "))
		file.close()
	view.queue_free()
	await process_frame
	if not failures.is_empty():
		for reason in failures:
			push_error("R5b: " + reason)
		quit(1)
		return
	print("R5b: 8 реальных кадров, 4 физических ориентира, LOD и сохранность мира — успешно.")
	quit(0)


func _initialize() -> void:
	# Запускаем после создания SceneTree, чтобы игровая сцена
	# успела создать свои модели, камеру, PBR и узлы рендера.
	call_deferred("_run")
