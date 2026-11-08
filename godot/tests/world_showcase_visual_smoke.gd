extends SceneTree
## Демонстрация природного мира: пользователь выбирает четыре
## настоящие местности, получает экранные кадры без нарушения физики.
## Это программный OpenGL, а не художественная/аппаратная приёмка.

const ViewScene = preload("res://scenes/world.tscn")
const Save = preload("res://scripts/world_save.gd")

const FILES := [
	"01-forest.png", "02-river.png", "03-mountain.png", "04-coast.png"
]
const EXPECTED := [
	"Лесная долина", "Изгиб реки", "Горный хребет", "Морской берег"
]
const TIMEOUT_MS := 120000

var failures: Array[String] = []


func _check(ok: bool, message: String) -> void:
	# Все ошибки выводим вместе. Так понятно, было ли нарушено
	# место на карте, качество кадра, загрузка или WorldSave.
	if not ok:
		failures.append(message)


func _folder() -> String:
	# Каталог задаёт CI, локальный запуск пишет в user://.
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--out="):
			return arg.trim_prefix("--out=")
	return ProjectSettings.globalize_path("user://showcase")


func _wait_for_scene(view: Node3D, target: Vector2) -> bool:
	# В потоковой сцене экранная камера остаётся на старом
	# готовом виде до загрузки всех целевых чанков.
	var deadline := Time.get_ticks_msec() + TIMEOUT_MS
	while Time.get_ticks_msec() < deadline:
		await process_frame
		if view._loading_layer == null or view._display_camera == null:
			continue
		if view._loading_layer.visible:
			continue
		if view._display_center.distance_to(target) > 1.0:
			continue
		if view._target_chunks.is_empty() or view._active.is_empty():
			continue
		return true
	return false


func _wait_for_start(view: Node3D) -> bool:
	# Не делаем видовые переходы до окончания фоновой генерации
	# физической карты и появления кнопок игрового интерфейса.
	var deadline := Time.get_ticks_msec() + TIMEOUT_MS
	while Time.get_ticks_msec() < deadline:
		await process_frame
		if view._showcase_text == null or view._loading_layer == null:
			continue
		if not view._loading_layer.visible and view._target_view_valid:
			return true
	return false


func _quality(image: Image) -> Dictionary:
	# Изображение должно содержать настоящие различающиеся
	# покрытия, а не фон или экран загрузки вместо карты.
	var colors := {}
	var visible := 0
	var total := 0
	for y in range(50, image.get_height() - 25, 20):
		for x in range(420, image.get_width() - 25, 20):
			var pixel: Color = image.get_pixel(x, y)
			colors[Vector3i(int(pixel.r * 12.0),
				int(pixel.g * 12.0), int(pixel.b * 12.0))] = true
			if pixel.get_luminance() > 0.09:
				visible += 1
			total += 1
	return {
		"distinct_color_buckets": colors.size(),
		"visible_ratio": float(visible) / float(maxi(total, 1))
	}


func _physical_place(view: Node3D, spot: Dictionary) -> bool:
	# Проверяем, что красивые названия ведут к физическим объектам:
	# река не просто нарисована текстурой, а берег — не случайная суша.
	var cell: Vector2i = spot["cell"]
	var index: int = view._hydro.cell_index(cell)
	match str(spot["name"]):
		"Изгиб реки":
			return view._hydro.river_at(index)
		"Морской берег":
			for offset in [Vector2i(1, 0), Vector2i(-1, 0),
					Vector2i(0, 1), Vector2i(0, -1)]:
				if view._hydro.ocean_at(view._hydro.cell_index(cell + offset)):
					return true
			return false
		"Горный хребет":
			return view._world_model.vertex_at(cell) > 4.0
		"Лесная долина":
			# Для леса достаточно наличия живых деревьев
			# в районе выбранного физического чанка.
			for item in view._nature.objects_in_chunk(
					view._world_model.config.chunk_of(cell)):
				if item["kind"] == "дерево" and item["state"] == "целое":
					return true
			return false
	return false


func _run() -> void:
	# Запускаем ту же сцену world.tscn, что открывается у игрока;
	# проверяем потоковую камеру, а не обходной тестовый просмотр.
	_check(DisplayServer.get_name() != "headless",
		"Для кадров требуется оконный GL, headless недопустим")
	if not failures.is_empty():
		_finish([])
		return
	var out: String = _folder()
	_check(DirAccess.make_dir_recursive_absolute(out) == OK,
		"Каталог изображений доступен")
	var view: Node3D = ViewScene.instantiate()
	get_root().add_child(view)
	_check(await _wait_for_start(view), "Стартовая карта загружена")
	if not failures.is_empty():
		view.queue_free()
		_finish([])
		return

	var tour_button: Button = view.find_child("Прогулка по миру", true, false)
	_check(tour_button != null, "Маршрут доступен в обычной панели")
	if tour_button == null:
		view.queue_free()
		_finish([])
		return
	var before: Dictionary = Save.capture(view._storage_models())
	_check(not before.is_empty(), "Перед прогулкой получен полный WorldSave")
	var shots: Array[Dictionary] = []
	var controls_saved := false
	for i in range(EXPECTED.size()):
		# Нажатие настоящей кнопки проверяет путь пользователя.
		tour_button.pressed.emit()
		_check(view._showcase_index == i, "Маршрут переключился на вид %d" % i)
		_check(view._showcase_overlay.visible and not view._main_panel.visible,
			"Прогулка освобождает экран от большой служебной панели")
		if view._showcase_index != i:
			break
		var spot: Dictionary = view._showcase_views[i]
		_check(spot["name"] == EXPECTED[i],
			"Порядок природных ракурсов соответствует интерфейсу")
		_check(_physical_place(view, spot),
			"Вид %s существует в физической карте" % str(spot["name"]))
		var target: Vector2 = view._center
		_check(await _wait_for_scene(view, target),
			"Потоковая камера загрузила место " + str(spot["name"]))
		if view._loading_layer.visible:
			break
		await process_frame
		await process_frame
		if not controls_saved:
			# Сохраняем отдельно реальный игровой интерфейс, затем
			# снимаем четыре пейзажа без панели: художественную
			# геометрию нужно оценивать без скрывающих деталей меню.
			var controls: Image = view.get_viewport().get_texture().get_image()
			_check(controls.save_png(out.path_join("00-tour-ui.png")) == OK,
				"Сохранён компактный игровой интерфейс прогулки")
			for child in view.get_children():
				if child is CanvasLayer and child != view._loading_layer:
					child.visible = false
			controls_saved = true
			await process_frame
			await process_frame
		var image: Image = view.get_viewport().get_texture().get_image()
		_check(image != null and image.get_width() >= 1280
			and image.get_height() >= 720,
			"Кадр %s имеет нужное разрешение" % str(spot["name"]))
		if image == null:
			break
		var quality: Dictionary = _quality(image)
		_check(quality["distinct_color_buckets"] >= 14
			and quality["visible_ratio"] > 0.25,
			"Видимый ландшафт %s не пустой" % str(spot["name"]))
		_check(image.save_png(out.path_join(FILES[i])) == OK,
			"Сохранён кадр " + FILES[i])
		shots.append({
			"name": spot["name"], "file": FILES[i],
			"cell": {"x": spot["cell"].x, "y": spot["cell"].y},
			"zoom": spot["zoom"], "quality": quality,
			"chunks": view._active.size()
		})
	# Проверяем полноценный возврат к игровому управлению:
	# обзор не должен оставлять игрока без кнопок сохранения.
	var exit_button: Button = view.find_child("Выход из прогулки", true, false)
	_check(exit_button != null, "Кнопка возврата доступна")
	if exit_button != null:
		exit_button.pressed.emit()
		_check(view._main_panel.visible and not view._showcase_overlay.visible
			and view._showcase_index == -1,
			"Возврат раскрывает игровую панель без сброса мира")
	# Режим обзора не изменяет ни одного физического состояния,
	# не телепортирует ресурсы и не сдвигает календарь.
	_check(Save.capture(view._storage_models()) == before,
		"Четыре видовых перехода не меняют WorldSave")
	_check(view._view_mode == 0,
		"В каждом виде используется природный слой, не диагностика")
	var manifest := {
		"schema_version": 1,
		"purpose": "Первая демонстрация живого природного мира",
		"art_accepted": false, "hardware_accepted": false,
		"renderer": DisplayServer.get_name(),
		"gpu": RenderingServer.get_video_adapter_name(),
		"seed": view._world_model.config.world_seed,
		"day": view._climate.day,
		"controls_file": "00-tour-ui.png",
		"views": shots,
		"physical_world_unchanged": Save.capture(view._storage_models()) == before,
		"checks_passed": failures.is_empty()
	}
	var file := FileAccess.open(out.path_join("manifest.json"), FileAccess.WRITE)
	_check(file != null, "Манифест демонстрации создан")
	if file != null:
		file.store_string(JSON.stringify(manifest, "\t") + "\n")
		file.close()
	view.queue_free()
	_finish(shots)


func _finish(shots: Array[Dictionary]) -> void:
	# CI принимает результат только при четырёх изображениях
	# и непротиворечивом физическом состоянии.
	_check(shots.size() == EXPECTED.size(),
		"Получены все четыре природных вида")
	if not failures.is_empty():
		for reason in failures:
			printerr("SHOWCASE: ", reason)
		quit(1)
		return
	print("SHOWCASE: четыре физические панорамы, потоковая камера и WorldSave — успешно")
	quit(0)


func _initialize() -> void:
	# Отложенный запуск даёт SceneTree создать экранный viewport.
	call_deferred("_run")
