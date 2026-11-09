extends SceneTree
## Реальная графическая приёмка одноэкранного пожара.
## Запускается только с оконным Godot Compatibility в программном GL:
## это не FPS видеокарты и не художественное одобрение.

const View = preload("res://scripts/world.gd")
const Save = preload("res://scripts/world_save.gd")
const Demo = preload("res://scripts/world_fire_demo.gd")

const TIMEOUT_MS := 220000
const CAPTURE_SIZE := Vector2i(1280, 720)
var failures: Array[String] = []


func _check(condition: bool, reason: String) -> void:
	# Три PNG, исходная камера и физический JSON — независимые
	# критерии, один успешный кадр не скрывает другую ошибку.
	if not condition:
		failures.append(reason)


func _output_folder() -> String:
	# CI собирает реальные исходные PNG для последующего
	# художественного сравнения; при ручном запуске сохраняем
	# отдельную директорию Godot user://.
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--out="):
			return arg.trim_prefix("--out=")
	return ProjectSettings.globalize_path("user://fire-demo-captures")


func _export_capture(source: String, destination: String) -> void:
	# Переносим именно viewport-файл, уже записанный игрой.
	# Генерация тестовой картинки здесь недопустима.
	var image := Image.load_from_file(source)
	_check(image != null and image.get_width() >= CAPTURE_SIZE.x
		and image.get_height() >= CAPTURE_SIZE.y,
		"Настоящий PNG создан в требуемом разрешении: " + source)
	if image == null:
		return
	_check(image.save_png(destination) == OK,
		"Фактический PNG сохранён в артефакты CI")


func _run() -> void:
	_check(DisplayServer.get_name() != "headless",
		"Для трёх реальных PNG необходим оконный рендерер")
	if not failures.is_empty():
		quit(1)
		return
	get_root().get_window().size = CAPTURE_SIZE
	var view := View.new()
	view.stream_camera = false
	get_root().add_child(view)
	await process_frame
	# В ручном тесте физическая сухость предсказуема:
	# мокрая почва не должна выдать ложное возгорание.
	view._surface._moisture.fill(0.02)
	view._surface._snow.fill(0.0)
	view._climate._rain.fill(0.0)
	var deadline := Time.get_ticks_msec() + TIMEOUT_MS
	while not view._fire_demo_ready() and Time.get_ticks_msec() < deadline:
		await process_frame
	_check(view._fire_demo_ready(), "Исходные чанки собраны без пустот")
	if not failures.is_empty():
		view.queue_free()
		quit(1)
		return

	view._begin_fire_demo()
	var stage := str(view._fire_demo.get("stage", ""))
	_check(stage == "before", "Сценарий выбрал настоящее дерево")
	if not failures.is_empty():
		view.queue_free()
		quit(1)
		return
	var initial_center: Vector2 = view._center
	var initial_zoom: float = view._camera.size
	var initial_day: int = view._climate.day
	var last_stage := ""
	while Time.get_ticks_msec() < deadline:
		await process_frame
		stage = str(view._fire_demo.get("stage", ""))
		if stage != last_stage:
			print("FIRE-DEMO-GL: этап=", stage, ", день=", view._climate.day,
				", чанки=", view._active.size(), "/", view._wanted_chunks.size())
			last_stage = stage
		if stage in ["complete", "failed"]:
			break
	_check(stage == "complete",
		"Пожар, два кадра и восстановление завершились в реальной сцене")
	if stage != "complete":
		_check(false, "Статус: " + str(view._fire_demo_status.text))
	else:
		_check(view._climate.day == initial_day + 1
			and view._center.is_equal_approx(initial_center)
			and is_equal_approx(view._camera.size, initial_zoom),
			"До, после и после загрузки используют одну камеру")
		_check(Demo.physical_equal(
			view._fire_demo["after_snapshot"], Save.capture(view._storage_models())),
			"Все физические состояния сохранились после фактической загрузки")
		var folder := _output_folder()
		_check(DirAccess.make_dir_recursive_absolute(folder) == OK,
			"Создан каталог реальных кадров")
		for item in [
			{"path": Demo.BEFORE_PNG, "name": "01-before.png"},
			{"path": Demo.AFTER_PNG, "name": "02-after.png"},
			{"path": Demo.RESTORED_PNG, "name": "03-restored.png"}
		]:
			_export_capture(str(item["path"]),
				folder.path_join(str(item["name"])))
		var saved := FileAccess.open(Demo.SAVE_PATH, FileAccess.READ)
		_check(saved != null and saved.get_length() > 1000,
			"Отдельный физический JSON пожара записан")
		if saved != null:
			saved.close()
	view.queue_free()
	await process_frame
	if not failures.is_empty():
		for failure in failures:
			push_error("FIRE-DEMO-GL: " + failure)
		quit(1)
		return
	print("FIRE-DEMO-GL: три реальных кадра, один ракурс и WorldSave — успешно")
	quit(0)


func _initialize() -> void:
	call_deferred("_run")
