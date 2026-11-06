extends SceneTree
## Этап 9.4: воспроизводимые кадры и профиль сцены на программном OpenGL.
## Скриншоты проверяют реальный вывод, но не подтверждают FPS видеокарты.

const View = preload("res://scripts/world.gd")
const Runner = preload("res://scripts/world_benchmark_runner.gd")

const CAPTURE_SIZE := Vector2i(1280, 720)
const BUILD_TIMEOUT_MS := 15000
const QUALITY_MIN_COLORS := 14
const SCENE_NAMES := ["первый_день", "берег", "горный_рельеф", "влажная_земля"]

var failures: Array[String] = []


func _check(ok: bool, message: String) -> void:
	if not ok:
		failures.append(message)


func _output_directory() -> String:
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--out="):
			return argument.trim_prefix("--out=")
	return "user://visual-qa-9-4"


func _write_json(path: String, content: Dictionary) -> bool:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return false
	file.store_string(JSON.stringify(content, "\t") + "\n")
	file.close()
	return true


func _select_positions(view: Node3D) -> Array[Dictionary]:
	var world: RefCounted = view._world_model
	var hydro: RefCounted = view._hydro
	var surface: RefCounted = view._surface
	var size: Vector2i = Vector2i(world.config.width, world.config.height)
	var middle := Vector2(size) * 0.5
	var coastal := Vector2i(-1, -1)
	var mountain := Vector2i(-1, -1)
	var wetland := Vector2i(-1, -1)
	var nearest_shore := INF
	var best_height := -INF
	var most_wet := -1.0
	var flooded := Vector2i(-1, -1)
	var flood_score := -1.0

	for y in range(1, size.y - 1):
		for x in range(1, size.x - 1):
			var cell := Vector2i(x, y)
			var index: int = hydro.cell_index(cell)
			var flood_depth: float = hydro.flood_depth_at(index)
			if flood_depth > 0.00001:
				var flooded_neighbors := 0
				for dy in range(-2, 3):
					for dx in range(-2, 3):
						if hydro.flood_depth_at(hydro.cell_index(
							cell + Vector2i(dx, dy))) > 0.00001:
							flooded_neighbors += 1
				var score := float(flooded_neighbors) + flood_depth * 0.2
				if score > flood_score:
					flood_score = score
					flooded = cell
			if hydro.has_water(index):
				continue
			var height: float = world.vertex_at(cell)
			# Приёмочная гора должна быть внутри мира, а не на
			# искусственном краю его географического обрамления.
			var inland := (x >= 16 and y >= 16 and
				x < size.x - 16 and y < size.y - 16)
			var mountain_score := height
			if surface.rock_at_index(index):
				mountain_score += 6.0
			if inland and mountain_score > best_height:
				best_height = mountain_score
				mountain = cell
			var wet: float = maxf(surface.moisture_at_index(index),
				surface.waterlogging_at_index(index))
			if wet > most_wet:
				most_wet = wet
				wetland = cell

			var sea_near := false
			for delta in [Vector2i(-1, 0), Vector2i(1, 0),
					Vector2i(0, -1), Vector2i(0, 1)]:
				if hydro.ocean_at(hydro.cell_index(cell + delta)):
					sea_near = true
					break
			if sea_near:
				var distance: float = Vector2(cell).distance_squared_to(middle)
				if distance < nearest_shore:
					nearest_shore = distance
					coastal = cell

	_check(coastal.x >= 0, "Найдена суша рядом с настоящим морем")
	_check(mountain.x >= 0, "Найдена скальная область")
	_check(wetland.x >= 0, "Найдена суша с измеряемой влажностью")
	_check(flooded.x >= 0, "Для сравнения найдена реально подтопленная пойма")
	return [
		{"name": SCENE_NAMES[0], "center": Vector2i(middle), "zoom": 96.0},
		{"name": SCENE_NAMES[1], "center": coastal, "zoom": 28.0},
		{"name": "берег_вблизи", "center": coastal, "zoom": 16.0},
		{"name": "берег_издалека", "center": coastal, "zoom": 64.0},
		{"name": SCENE_NAMES[2], "center": mountain, "zoom": 22.0},
		{"name": "пойма_реки", "center": flooded if flooded.x >= 0 else wetland,
			"zoom": 22.0},
		{"name": SCENE_NAMES[3], "center": wetland, "zoom": 24.0}
	]


func _wait_for_chunks(view: Node3D) -> int:
	var deadline := Time.get_ticks_msec() + BUILD_TIMEOUT_MS
	var frames := 0
	while Time.get_ticks_msec() < deadline:
		await process_frame
		frames += 1
		if (view._pending.is_empty() and view._chunk_jobs.is_empty() and
				view._rebuild_pending.is_empty() and
				view._active.size() >= view._wanted_chunks.size() and
				not view._active.is_empty()):
			await process_frame
			await process_frame
			return frames
	return -1


func _image_quality(image: Image) -> Dictionary:
	var histogram := {}
	var bright := 0
	var measured := 0
	for y in range(70, image.get_height() - 10, 22):
		for x in range(15, image.get_width() - 15, 22):
			var color: Color = image.get_pixel(x, y)
			if color.get_luminance() > 0.08:
				bright += 1
			var bucket := Vector3i(int(color.r * 12.0),
				int(color.g * 12.0), int(color.b * 12.0))
			histogram[bucket] = true
			measured += 1
	return {
		"distinct_color_buckets": histogram.size(),
		"sampled_pixels": measured,
		"visible_pixel_ratio": float(bright) / float(maxi(measured, 1))
	}


func _snapshot(view: Node3D, scenario: Dictionary, folder: String) -> Dictionary:
	var center: Vector2i = scenario["center"]
	var zoom: float = scenario["zoom"]
	view._change_zoom(zoom / view._camera.size)
	view._move_center(Vector2(center) - view._center)
	var frames: int = await _wait_for_chunks(view)
	_check(frames >= 0,
		"Панорама " + str(scenario["name"]) + " не имеет незагруженных чанков")
	var image: Image = view.get_viewport().get_texture().get_image()
	_check(image != null and image.get_width() >= CAPTURE_SIZE.x and
		image.get_height() >= CAPTURE_SIZE.y,
		"Кадр имеет ожидаемое разрешение")
	if image == null:
		return {}
	var quality: Dictionary = _image_quality(image)
	var min_colors: int = 4 if bool(scenario.get("diagnostic", false)) else QUALITY_MIN_COLORS
	_check(quality["distinct_color_buckets"] >= min_colors and
		quality["visible_pixel_ratio"] > 0.20,
		"Рендер " + str(scenario["name"]) + " не пустой и не однотонный")
	var filename: String = str(scenario["name"]) + ".png"
	_check(image.save_png(folder.path_join(filename)) == OK,
		"Кадр сохранён: " + filename)
	var index: int = view._hydro.cell_index(center)
	return {
		"name": scenario["name"], "file": filename,
		"center": {"x": center.x, "y": center.y},
		"zoom": zoom, "loaded_chunks": view._active.size(),
		"load_frames": frames, "diagnostic": bool(scenario.get("diagnostic", false)),
		"moisture": view._surface.moisture_at_index(index),
		"snow": view._surface.snow_at_index(index),
		"frost": view._surface.frost_at_index(index),
		"waterlogging": view._surface.waterlogging_at_index(index),
		"height": view._world_model.vertex_at(center),
		"rock_at_center": view._surface.rock_at_index(index),
		"quality": quality
	}


func _run() -> void:
	await process_frame
	_check(DisplayServer.get_name() != "headless",
		"Для снимков нужен оконный рендерер, headless не подходит")
	if not failures.is_empty():
		push_error("Этап 9.4: " + failures[0])
		quit(1)
		return

	var folder := _output_directory()
	if not DirAccess.dir_exists_absolute(folder):
		_check(DirAccess.make_dir_recursive_absolute(folder) == OK,
			"Каталог результатов доступен")
	var view := View.new()
	get_root().add_child(view)
	# Скрываем HUD, чтобы проверять именно отрисовку природных покрытий.
	for child in view.get_children():
		if child is CanvasLayer:
			child.visible = false
	var world_before: Dictionary = view._world_model.to_data()
	var surface_before: Dictionary = view._surface.to_snapshot()
	var water_before: Dictionary = view._hydro.to_snapshot()

	var scenes: Array[Dictionary] = _select_positions(view)
	var captures: Array[Dictionary] = []
	for scenario in scenes:
		var result: Dictionary = await _snapshot(view, scenario, folder)
		if not result.is_empty():
			captures.append(result)

	# Диагностика сетчатых артефактов: отделяем полупрозрачную воду
	# от грунта, затем проверяем сам грунт без PBR-шейдера.
	var wet_scene: Dictionary = scenes[scenes.size() - 1]
	var water_nodes: Array[MeshInstance3D] = []
	var ground_nodes: Array[MeshInstance3D] = []
	for chunk in view._active.values():
		var node: Node3D = chunk
		for child in node.get_children():
			if child is MeshInstance3D and child.name == "Поверхностная вода":
				water_nodes.append(child)
			elif child is MeshInstance3D:
				ground_nodes.append(child)
	for water_node in water_nodes:
		water_node.visible = false
	var ground_only := wet_scene.duplicate()
	ground_only["name"] = "влажная_земля_без_воды"
	ground_only["diagnostic"] = true
	var ground_only_result: Dictionary = await _snapshot(view, ground_only, folder)
	if not ground_only_result.is_empty():
		captures.append(ground_only_result)
	for water_node in water_nodes:
		water_node.visible = true
	for ground_node in ground_nodes:
		ground_node.material_override = view._debug_ground_material
	var unshaded := wet_scene.duplicate()
	unshaded["name"] = "влажная_земля_без_PBR"
	unshaded["diagnostic"] = true
	var unshaded_result: Dictionary = await _snapshot(view, unshaded, folder)
	if not unshaded_result.is_empty():
		captures.append(unshaded_result)
	for ground_node in ground_nodes:
		ground_node.material_override = view._ground_material

	var benchmark: Dictionary = await Runner.new().run(view)
	benchmark["evaluation"] = "ПРОГРАММНЫЙ GL; НЕ ФАКТИЧЕСКИЕ FPS GPU"
	benchmark["hardware_accepted"] = false
	benchmark["visual_stage"] = "9.4"
	_check(_write_json(folder.path_join("benchmark.json"), benchmark),
		"Маршрут и p50/p95/p99 сохранены в JSON")
	_check(benchmark["summary"]["physics_unchanged"],
		"Сценарий камеры не изменил рельеф")

	_check(world_before == view._world_model.to_data() and
		surface_before == view._surface.to_snapshot() and
		water_before == view._hydro.to_snapshot(),
		"Скриншоты и маршрут не меняют физический мир")

	var manifest := {
		"schema_version": 1, "stage": "9.4",
		"hardware_accepted": false,
		"renderer": DisplayServer.get_name(),
		"gpu": RenderingServer.get_video_adapter_name(),
		"image_source": "ПРОГРАММНЫЙ GL на CI, не пользовательское устройство",
		"map_seed": view._world_model.config.world_seed,
		"season_day": view._climate.day,
		"captures": captures,
		"benchmark_file": "benchmark.json",
		"checks_passed": failures.is_empty()
	}
	_check(_write_json(folder.path_join("manifest.json"), manifest),
		"Манифест кадров и условий сохранён")
	view.queue_free()
	if not failures.is_empty():
		for reason in failures.slice(0, 25):
			push_error("Этап 9.4: " + reason)
		quit(1)
		return
	print("Этап 9.4: ", captures.size(),
		" снимка природных покрытий и JSON-метрики — успешно.")
	quit(0)


func _initialize() -> void:
	_run()
