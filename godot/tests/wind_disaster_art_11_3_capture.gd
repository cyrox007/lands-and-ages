extends SceneTree
## Этап 11.3: реальные художественные PNG ветровых бедствий в Godot.
## Сцена использует существующий World. Демонстрационные события
## нужны только для сравнения графики, не запускают физический урон.

const View = preload("res://scripts/world.gd")
const Visual = preload("res://scripts/weather_visual_state.gd")
const SIZE := Vector2i(960, 540)
const MAX_BUILD_FRAMES := 420

var failures: Array[String] = []


func _check(condition: bool, message: String) -> void:
	# Ошибки реальной отрисовки собираем по каждому состоянию,
	# чтобы не путать пустую сцену с исправным FX.
	if not condition:
		failures.append(message)


func _out_dir() -> String:
	# Путь задаётся CI, иначе используем только каталог user://.
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--out="):
			return arg.trim_prefix("--out=")
	return "user://stage-11-3-art"


func _wait_chunks(view: Node3D) -> void:
	# Прежде чем снимать вихрь, дожидаемся настоящих природных
	# объектов и мешей, иначе можно принять пустую карту за успех.
	for i in range(MAX_BUILD_FRAMES):
		await process_frame
		if view._pending.is_empty() and view._rebuild_pending.is_empty() \
				and not view._active.is_empty() \
				and view._active.size() >= view._wanted_chunks.size():
			await process_frame
			await process_frame
			return
	_check(false, "Карта не успела построиться для контрольной сцены")


func _climate() -> Dictionary:
	# Один и тот же климат для всех кадров позволяет отделить
	# форму бедствия от других погодных или сезонных изменений.
	return Visual.from_weather({
		"temperature": 21.0, "humidity": 0.31,
		"rainfall": 0.0, "snowfall": 0.0,
		"storm_intensity": 0.0, "wind_speed": 21.0,
		"wind_gust": 28.0, "wind_direction_x": 1.0,
		"wind_direction_y": 0.0
	})


func _capture(folder: String, name: String) -> Image:
	# Снимок производится из настоящего Viewport после отрисовки
	# Godot, без промежуточной синтетической картинки.
	await process_frame
	await process_frame
	var image: Image = root.get_texture().get_image()
	var file := folder.path_join(name + ".png")
	_check(image.get_size() == SIZE, "Кадр " + name + " неверного размера")
	_check(image.save_png(file) == OK, "Ошибка записи " + file)
	_check(FileAccess.get_file_as_bytes(file).size() > 18000,
		"Пустое изображение погодного состояния " + name)
	return image


func _changed_pixels(baseline: Image, image: Image) -> int:
	# Цветовая разница тестирует наличие видимого эффекта,
	# но художественную оценку композиции всё равно делает автор.
	var count := 0
	for y in range(45, SIZE.y - 30, 6):
		for x in range(35, SIZE.x - 35, 6):
			var a: Color = baseline.get_pixel(x, y)
			var b: Color = image.get_pixel(x, y)
			if absf(a.r - b.r) + absf(a.g - b.g) + absf(a.b - b.b) > 0.11:
				count += 1
	return count


func _render_event(view: Node3D, folder: String, name: String,
		baseline: Image) -> Dictionary:
	# Каждый вариант использует один и тот же физический эпицентр.
	# Визуальное событие задано диагностикой, а настоящие
	# расчёты ветровала/пыли проверяют отдельные физические smoke.
	view._atmosphere.clear_after_load(-1)
	var position: Vector2 = view._center
	var cell := view._world_model.config.cell_at(position)
	var hazard: Dictionary = {
		"kind": name, "cell": cell, "day": 5,
		"severity": 0.98, "sediment_volume": 0.038
	}
	if name != "спокойно":
		view._atmosphere.show_hazard(hazard, Vector2.RIGHT,
			view._world_model)
	var height := view._world_model.config.to_scene(position,
		view._world_model.height_at(position)).y
	view._weather_fx.apply_snapshot(_climate(), position, height,
		view._camera.size, 1729)
	await create_timer(0.85).timeout
	var shot := await _capture(folder, name)
	var changed := _changed_pixels(baseline, shot)
	if name in ["смерч", "пыльная буря"]:
		_check(changed > 22,
			"Смерч и пыль должны быть различимы на настоящем ландшафте")
	return {
		"weather": name, "file": name + ".png",
		"changed_sample_pixels": changed,
		"epicenter": str(cell),
		"geometry_is_physical": false
	}


func _run() -> void:
	# Одинаковая камера, seed и готовая карта нужны для проверки
	# реальной выразительности разных типов ветровой графики.
	var dir := _out_dir()
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dir))
	root.size = SIZE
	var view := View.new()
	root.add_child(view)
	for child in view.get_children():
		if child is CanvasLayer:
			child.visible = false
	await _wait_chunks(view)
	view.set_process(false)
	var before := JSON.stringify(view._world_model.to_data())
	var soil_before := JSON.stringify(view._surface.to_data())
	var calm := await _render_event(view, dir, "спокойно",
		Image.create_empty(SIZE.x, SIZE.y, false, Image.FORMAT_RGBA8))
	var baseline := Image.load_from_file(dir.path_join("спокойно.png"))
	var scenes := [calm]
	for kind in ["шторм", "шквал", "ураган", "смерч", "пыльная буря"]:
		scenes.append(await _render_event(view, dir, kind, baseline))
	_check(JSON.stringify(view._world_model.to_data()) == before
		and JSON.stringify(view._surface.to_data()) == soil_before,
		"Визуальные испытания не переносят почву и не валят деревья")
	var manifest := {
		"stage": "11.3", "capture_renderer": "Godot Compatibility/software OpenGL",
		"artistic_approval": false, "android_pc_gpu_verified": false,
		"visual_reference_events_only": true,
		"scenes": scenes, "checks_passed": failures.is_empty()
	}
	var file := FileAccess.open(dir.path_join("manifest.json"), FileAccess.WRITE)
	if file == null:
		failures.append("Нет манифеста контрольных изображений")
	else:
		file.store_string(JSON.stringify(manifest, "\t"))
		file.close()
	view.queue_free()
	if failures.is_empty():
		print("Этап 11.3/GL: шесть погодных сцен и сохранность мира — успешно")
		quit(0)
		return
	for error in failures:
		printerr("Этап 11.3/GL: ", error)
	quit(1)


func _initialize() -> void:
	# Выделяем сцену и каналы рендера до начала испытаний.
	call_deferred("_run")
