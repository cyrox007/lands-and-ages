extends SceneTree
## 11.2/L1/L6: реальные сравнимые кадры атмосферы в Godot.
## Это технические изображения ПРОГРАММНОГО OpenGL, не заменяющие
## художественную оценку и реальные замеры GPU на ПК или Android.

const View = preload("res://scripts/world.gd")
const Visual = preload("res://scripts/weather_visual_state.gd")
const Light = preload("res://scripts/weather_lighting_state.gd")
const SIZE := Vector2i(960, 540)
const MAX_FRAMES := 420

var errors: Array[String] = []


func _check(ok: bool, text: String) -> void:
	# Критерии разных сценариев не смешиваем; в манифесте
	# сохраняем, какой именно эталон не отрисовался корректно.
	if not ok:
		errors.append(text)


func _output() -> String:
	# CI получает путь аргументом. Локальная съёмка использует
	# только user:// и не загрязняет отслеживаемые исходники.
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--out="):
			return arg.trim_prefix("--out=")
	return "user://world-art-11-2"


func _landmarks(view: Node3D) -> Array[Dictionary]:
	# На реальной карте выбираем гору, сухую низину и участок леса.
	# Выбор повторяем при том же seed, без изменения физического мира.
	var world: RefCounted = view._world_model
	var hydro: RefCounted = view._hydro
	var highest := -INF
	var lowest := INF
	var mountain := Vector2(128, 96)
	var valley := Vector2(128, 96)
	for y in range(24, world.config.height - 24, 4):
		for x in range(24, world.config.width - 24, 4):
			var cell := Vector2i(x, y)
			if hydro.has_water(hydro.cell_index(cell)):
				continue
			var height: float = world.vertex_at(cell)
			if height > highest:
				highest = height
				mountain = Vector2(cell)
			if height < lowest:
				lowest = height
				valley = Vector2(cell)
	var woodland := Vector2(128, 96)
	var best_distance := INF
	for item in view._nature._objects.values():
		if item["kind"] != "дерево" or item["state"] != "целое":
			continue
		var position := Vector2(float(item["x"]), float(item["y"]))
		var dist := position.distance_squared_to(Vector2(128, 96))
		if dist < best_distance:
			best_distance = dist
			woodland = position
	_check(highest > lowest, "На карте найдены различимые гора и низина")
	_check(best_distance < INF, "В природном мире найден лес")
	return [
		{"name": "горы_близко", "center": mountain, "zoom": 34.0},
		{"name": "горы_панорама", "center": mountain, "zoom": 82.0},
		{"name": "лес_и_долина", "center": woodland, "zoom": 42.0}
	]


func _weather(name: String) -> Dictionary:
	# Контрольные эталоны воспроизводят возможные значения Climate.
	# Съёмка не навязывает эти значения физическому миру, а только
	# задаёт графический снимок при неизменной камере/геометрии.
	var fields := {"temperature": 13.0, "humidity": 0.28,
		"rainfall": 0.0, "snowfall": 0.0,
		"storm_intensity": 0.0, "wind_speed": 5.0,
		"wind_gust": 7.0, "wind_direction_x": 0.87,
		"wind_direction_y": 0.49}
	match name:
		"облачно_просветы":
			fields["humidity"] = 0.79
			fields["wind_speed"] = 9.0
		"утренний_туман":
			fields["humidity"] = 0.97
			fields["wind_speed"] = 2.0
		"гроза_ливень":
			fields["humidity"] = 0.98
			fields["rainfall"] = 2.3
			fields["storm_intensity"] = 0.91
			fields["wind_speed"] = 20.0
	return Visual.from_weather(fields)


func _wait_world(view: Node3D) -> void:
	# Снимок пустых ещё не построенных чанков неприемлем
	# для художественного сравнения рельефа и древесных теней.
	for frame in range(MAX_FRAMES):
		await process_frame
		if view._pending.is_empty() and view._rebuild_pending.is_empty() \
				and view._active.size() >= view._wanted_chunks.size() \
				and not view._active.is_empty():
			await process_frame
			await process_frame
			return
	_check(false, "Геометрия карты не загрузилась к контрольному кадру")


func _capture(folder: String, name: String) -> Image:
	# Два готовых кадра нужны для применения новых Environment
	# и ShaderMaterial без изменения физического времени.
	await process_frame
	await process_frame
	var image: Image = root.get_texture().get_image()
	var path := folder.path_join(name + ".png")
	_check(image.get_size() == SIZE, "Неверный размер кадра " + name)
	_check(image.save_png(path) == OK, "Не записан PNG " + name)
	_check(FileAccess.get_file_as_bytes(path).size() > 18000,
		"Кадр " + name + " пустой или неправильно закодирован")
	return image


func _difference(first: Image, second: Image) -> int:
	# Отличие погоды измеряется на пикселях настоящего рендера,
	# без предварительно нарисованной композиции.
	var count := 0
	for y in range(60, SIZE.y - 30, 8):
		for x in range(40, SIZE.x - 40, 8):
			var a := first.get_pixel(x, y)
			var b := second.get_pixel(x, y)
			if absf(a.r - b.r) + absf(a.g - b.g) + absf(a.b - b.b) > 0.14:
				count += 1
	return count


func _percentile(values: Array[float], fraction: float) -> float:
	# Длина кадра по программному GL — диагностический сигнал,
	# а не измерение реального Android/GTX GPU.
	if values.is_empty():
		return 0.0
	values.sort()
	var at := clampi(roundi((values.size() - 1) * fraction),
		0, values.size() - 1)
	return values[at]


func _run() -> void:
	# Изображения трёх типовых мест × четырёх состояний погоды
	# имеют неизменный seed, камеру, время и физическую геометрию.
	var folder := _output()
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(folder))
	root.size = SIZE
	var view := View.new()
	root.add_child(view)
	for child in view.get_children():
		if child is CanvasLayer:
			child.visible = false
	var original_world := JSON.stringify(view._world_model.to_data())
	var original_hydro := JSON.stringify(view._hydro.to_data())
	var original_climate := JSON.stringify(view._climate.to_data())
	var places := _landmarks(view)
	var weathers := ["ясно", "облачно_просветы", "утренний_туман", "гроза_ливень"]
	var manifest := {"stage": "11.2", "renderer": "Godot Compatibility/software OpenGL",
		"manual_art_approval": false, "hardware_gpu_accepted": false,
		"scenes": [], "metrics": {}, "checks_passed": false}
	var frame_intervals: Array[float] = []
	var capture_cycles: Array[float] = []

	for place in places:
		view._change_zoom(float(place["zoom"]) / view._camera.size)
		view._move_center(Vector2(place["center"]) - view._center)
		await _wait_world(view)
		# После готовности мешей отключаем игровой _process:
		# сравнимые снимки не перезаписывает климат нового кадра.
		view.set_process(false)
		var baseline: Image
		for weather_name in weathers:
			var state: Dictionary = _weather(weather_name)
			var lighting: Dictionary = Light.from_snapshot(state)
			view._weather_light_current = lighting.duplicate(true)
			view._weather_light_target = lighting.duplicate(true)
			view._write_weather_lighting(lighting)
			view._weather_fx.apply_snapshot(state, place["center"],
				0.0, float(place["zoom"]), view._world_model.config.world_seed)
			# Замеряем именно интервалы программного рендера, а не
			# сохранение PNG на диск. По ним можно найти регрессии CI,
			# но нельзя судить о FPS реальных GPU или Android.
			for sample in range(9):
				var frame_started := Time.get_ticks_usec()
				await process_frame
				frame_intervals.append(
					float(Time.get_ticks_usec() - frame_started) / 1000.0)
			var started := Time.get_ticks_usec()
			var filename: String = str(place["name"]) + "_" + str(weather_name)
			var shot: Image = await _capture(folder, filename)
			capture_cycles.append(float(Time.get_ticks_usec() - started) / 1000.0)
			var changed := 0
			if weather_name == "ясно":
				baseline = shot
			else:
				changed = _difference(baseline, shot)
				_check(changed > 30,
					"Погода " + weather_name + " различима в " + str(place["name"]))
			manifest["scenes"].append({
				"scene": place["name"], "weather": weather_name,
				"file": filename + ".png", "changed_sample_pixels": changed,
				"zoom": place["zoom"], "center": str(place["center"])
			})
		view.set_process(true)
	_check(JSON.stringify(view._world_model.to_data()) == original_world
		and JSON.stringify(view._hydro.to_data()) == original_hydro
		and JSON.stringify(view._climate.to_data()) == original_climate,
		"Съёмка света не меняет карту, гидрологию или климат")
	manifest["metrics"] = {
		"software_gl_frame_ms_p50": _percentile(frame_intervals.duplicate(), 0.50),
		"software_gl_frame_ms_p95": _percentile(frame_intervals.duplicate(), 0.95),
		"software_gl_frame_ms_p99": _percentile(frame_intervals.duplicate(), 0.99),
		"software_gl_frame_samples": frame_intervals.size(),
		"capture_cycle_ms_p95": _percentile(capture_cycles.duplicate(), 0.95),
		"warning": "Программный GL в CI, НЕ FPS/замеры GPU реального устройства"
	}
	manifest["checks_passed"] = errors.is_empty()
	var file := FileAccess.open(folder.path_join("manifest.json"), FileAccess.WRITE)
	if file == null:
		errors.append("Не удалось записать манифест кадров")
	else:
		file.store_string(JSON.stringify(manifest, "\t"))
		file.close()
	view.queue_free()
	if errors.is_empty():
		print("Этап 11.2/GL: 12 художественных кадров и климатическая глубина — успешно")
		quit(0)
		return
	for reason in errors:
		printerr("Этап 11.2/GL: ", reason)
	quit(1)


func _initialize() -> void:
	# Запускаем реальный оконный Godot, а не headless подмену.
	call_deferred("_run")
