extends SceneTree
## Этап 11.2/L2: два настоящих кадра одной горной сцены.
## Программный OpenGL на CI подтверждает работу рендера, но не FPS Android.

const View = preload("res://scripts/world.gd")
const SIZE := Vector2i(960, 540)
const MAX_FRAMES := 360

var errors: Array[String] = []


func _check(ok: bool, reason: String) -> void:
	## Сохраняем причину даже если позже требуется освободить сцену.
	if not ok:
		errors.append(reason)


func _output() -> String:
	## На CI путь задаётся аргументом; локально используется user://.
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--out="):
			return arg.trim_prefix("--out=")
	return "user://shadow-l2"


func _mountain_center(view: Node3D) -> Vector2:
	## Выбираем высокую сухую точку внутри карты, без искусственной
	## морской границы; так кадры можно воспроизводить по seed.
	var world: RefCounted = view._world_model
	var hydro: RefCounted = view._hydro
	var best := -INF
	var position := Vector2(128.0, 96.0)
	for y in range(28, world.config.height - 28, 3):
		for x in range(28, world.config.width - 28, 3):
			var cell := Vector2i(x, y)
			if hydro.has_water(hydro.cell_index(cell)):
				continue
			var h: float = world.vertex_at(cell)
			if h > best:
				best = h
				position = Vector2(cell)
	return position


func _wait_chunks(view: Node3D) -> void:
	## Продолжаем обновлять экран, пока ближайшие чанки не готовы.
	## Пустую карту не выдаём за корректный графический результат.
	for frame in range(MAX_FRAMES):
		await process_frame
		if view._pending.is_empty() and view._rebuild_pending.is_empty() 				and view._active.size() >= view._wanted_chunks.size() 				and not view._active.is_empty():
			await process_frame
			await process_frame
			return
	_check(false, "Горная сцена не успела загрузиться в допустимый бюджет кадров")


func _compare(first: Image, second: Image) -> Dictionary:
	## Сравниваем одинаковые координаты пикселей при выключенной
	## и включённой карте теней. Без движения камеры и физики.
	var changed := 0
	var checked := 0
	var contrast := 0.0
	for y in range(40, SIZE.y - 30, 6):
		for x in range(30, SIZE.x - 30, 6):
			var a: Color = first.get_pixel(x, y)
			var b: Color = second.get_pixel(x, y)
			var delta: float = absf(a.get_luminance() - b.get_luminance())
			contrast += delta
			if delta >= 0.012:
				changed += 1
			checked += 1
	return {"changed": changed, "samples": checked,
		"average_difference": contrast / float(maxi(checked, 1))}


func _run() -> void:
	await process_frame
	_check(DisplayServer.get_name() != "headless",
		"Нужен оконный рендерер, а не headless")
	if not errors.is_empty():
		quit(1)
		return
	var folder := _output()
	_check(DirAccess.make_dir_recursive_absolute(folder) == OK,
		"Каталог изображений доступен")
	get_root().size = SIZE

	var view := View.new()
	get_root().add_child(view)
	for node in view.get_children():
		if node is CanvasLayer:
			node.visible = false
	var before: Dictionary = view._world_model.to_data()
	var camera_center: Vector2 = _mountain_center(view)
	view._change_zoom(32.0 / view._camera.size)
	view._move_center(camera_center - view._center)
	await _wait_chunks(view)
	_check(view._world_light.shadow_enabled,
		"Ближний масштаб включил настоящий направленный свет")
	var terrain_casters := 0
	var forest_casters := 0
	for chunk in view._active.values():
		var ground: MeshInstance3D = (chunk as Node3D).get_node_or_null("Рельеф")
		if ground != null and ground.cast_shadow == 				GeometryInstance3D.SHADOW_CASTING_SETTING_ON:
			terrain_casters += 1
		var nature := (chunk as Node3D).get_node_or_null("Природные объекты")
		if nature != null:
			for item in nature.get_children():
				if item is GeometryInstance3D and item.cast_shadow == 						GeometryInstance3D.SHADOW_CASTING_SETTING_ON:
					forest_casters += 1
	_check(terrain_casters > 0 and terrain_casters <= 25,
		"Реальные геометрические тени ограничены двадцатью пятью чанками")
	_check(forest_casters > 0,
		"Среди видимых групп растений есть реальные теневые меши")

	await process_frame
	await process_frame
	var on: Image = view.get_viewport().get_texture().get_image()
	_check(on != null and on.get_width() == SIZE.x and on.get_height() == SIZE.y,
		"Сохранение изображения работающего GL-рендера")
	if on != null:
		_check(on.save_png(folder.path_join("горы_с_тенями.png")) == OK,
			"Кадр с тенями сохранён")

	# Убираем исключительно источник карты теней без пересоздания сцены.
	view._world_light.shadow_enabled = false
	await process_frame
	await process_frame
	await process_frame
	var off: Image = view.get_viewport().get_texture().get_image()
	if off != null:
		_check(off.save_png(folder.path_join("горы_без_теней.png")) == OK,
			"Контрольный кадр без теней сохранён")
	if on != null and off != null and on.get_size() == off.get_size():
		var result: Dictionary = _compare(on, off)
		print("L2 кадры: пикселей изменилось ", result["changed"],
			"/", result["samples"], ", средняя световая разница ",
			result["average_difference"])
		_check(int(result["changed"]) > 20,
			"На настоящем изображении тени должны изменять рельеф")
	else:
		_check(false, "Оба кадра для сравнения должны существовать")

	_check(view._world_model.to_data() == before,
		"Рендер теней не меняет ни одной физической высоты")
	view.queue_free()
	if errors.is_empty():
		print("Этап 11.2/L2: реальные кадры теней — успешно")
		quit(0)
		return
	for error in errors:
		printerr("Этап 11.2/L2: ", error)
	quit(1)


func _initialize() -> void:
	## Запускаем только после создания настоящего окна и viewport.
	_run()
