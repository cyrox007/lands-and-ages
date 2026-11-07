extends SceneTree
## RF4: реальные контрольные кадры геологических изменений в игровом Godot.
## Программный OpenGL проверяет видимость, но не аппаратный FPS и не художественную оценку.

const View = preload("res://scripts/world.gd")
const Save = preload("res://scripts/world_save.gd")
const Size := Vector2i(960, 540)
const MaxBuildFrames := 480

var failures: Array[String] = []


func _check(condition: bool, message: String) -> void:
	# Ошибки сохраняются до конца проверки: это позволяет отличить
	# невидимую геометрию от сломанного сохранения или коллизий.
	if not condition:
		failures.append(message)


func _folder() -> String:
	# CI передаёт собственный путь, на локальном устройстве записи
	# остаются в user:// и не затрагивают дерево исходного проекта.
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--out="):
			return argument.trim_prefix("--out=")
	return "user://landscape-11-7-rf4"


func _wait_chunks(view: Node3D) -> bool:
	# Дожидаемся именно перестроенных игровых чанков, а не двух
	# кадров после команды, когда на экране ещё может быть старый меш.
	for frame in range(MaxBuildFrames):
		await process_frame
		if view._day_task_id >= 0 or view._days_pending > 0:
			continue
		if view._chunk_jobs.is_empty() and view._pending.is_empty() \
				and view._rebuild_pending.is_empty() and view._nature_dirty.is_empty() \
				and not view._active.is_empty() \
				and view._active.size() >= view._wanted_chunks.size():
			await process_frame
			await process_frame
			return true
	_check(false, "Меши, растения или коллизии не успели обновиться")
	return false


func _choose_tree(view: Node3D) -> Dictionary:
	# Берём настоящее живое дерево NatureRegistry в безопасной
	# внутренней области: ударный кратер не должен обрезаться краем.
	var config: RefCounted = view._world_model.config
	var chosen: Dictionary = {}
	var best := INF
	var chunks: Vector2i = config.chunk_count()
	for cy in range(chunks.y):
		for cx in range(chunks.x):
			for item in view._nature.objects_in_chunk(Vector2i(cx, cy)):
				if item["kind"] != "дерево" or item["state"] != "целое" \
						or int(item["wood_units"]) <= 0:
					continue
				var center := Vector2(float(item["x"]) + 0.5,
					float(item["y"]) + 0.5)
				if center.x < 24.0 or center.y < 24.0 \
						or center.x > float(config.width) - 24.0 \
						or center.y > float(config.height) - 24.0:
					continue
				var height: float = view._world_model.height_at(center)
				if height < 4.0 or height > 35.0:
					continue
				var distance := center.distance_squared_to(
					Vector2(config.width, config.height) * 0.5)
				if distance < best:
					chosen = item
					best = distance
	return chosen


func _mesh_y(view: Node3D, vertex: Vector2i) -> float:
	# Сверяем реальные вершины готового ArrayMesh с физической
	# картой, а не с текстурой или HUD. Первый блок массива меша
	# содержит исходную сетку ровно один раз.
	var config: RefCounted = view._world_model.config
	var chunk: Vector2i = config.chunk_of(vertex)
	var node: Node3D = view._active.get(chunk)
	if node == null:
		return NAN
	var ground: MeshInstance3D = node.get_node_or_null("Рельеф")
	if ground == null or ground.mesh == null \
			or ground.mesh.get_surface_count() == 0:
		return NAN
	var bounds: Rect2i = config.chunk_rect(chunk)
	var local := vertex - bounds.position
	var index := local.y * (bounds.size.x + 1) + local.x
	var points: PackedVector3Array = ground.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	if index < 0 or index >= points.size():
		return NAN
	return points[index].y


func _image_difference(before: Image, after: Image) -> int:
	# Разница измеряется по разрежённой сетке экранных пикселей.
	# Она показывает реальное изменение кадра, но не качество арта.
	var count := 0
	for y in range(40, Size.y - 25, 6):
		for x in range(30, Size.x - 30, 6):
			var a: Color = before.get_pixel(x, y)
			var b: Color = after.get_pixel(x, y)
			if absf(a.r - b.r) + absf(a.g - b.g) + absf(a.b - b.b) > 0.12:
				count += 1
	return count


func _capture(folder: String, name: String) -> Image:
	# Получаем настоящую текстуру Viewport с запущенным рендером,
	# а не изображение, сформированное программно из высот.
	await process_frame
	await process_frame
	var shot: Image = root.get_texture().get_image()
	var path := folder.path_join(name + ".png")
	_check(shot.get_size() == Size, "Неверный размер кадра " + name)
	_check(shot.save_png(path) == OK, "PNG не записан: " + name)
	_check(FileAccess.get_file_as_bytes(path).size() > 18000,
		"Кадр геологического события слишком мал: " + name)
	return shot


func _parts(view: Node3D, object_id: int) -> Array[String]:
	# Проверяем живые физические формы в активном игровом чанке.
	# После падения дерева там должны остаться пень и бревно.
	var item: Dictionary = view._nature.object_at(object_id)
	var chunk: Vector2i = view._world_model.config.chunk_of(
		Vector2i(int(item["x"]), int(item["y"])))
	var result: Array[String] = []
	if not view._active.has(chunk):
		return result
	var collider: Node = view._active[chunk].get_node_or_null("Природные коллизии")
	if collider == null:
		return result
	for shape in collider.get_children():
		if shape is CollisionShape3D \
				and int(shape.get_meta("nature_id", -1)) == object_id:
			result.append(str(shape.get_meta("nature_part", "")))
	result.sort()
	return result


func _write_manifest(folder: String, payload: Dictionary) -> void:
	# Манифест фиксирует тип рендера и реальные границы доказательств.
	# Зелёный CI никогда не выставляет "аппаратная приёмка пройдена".
	var file := FileAccess.open(folder.path_join("manifest.json"), FileAccess.WRITE)
	_check(file != null, "Не открыт файл контрольного манифеста")
	if file == null:
		return
	file.store_string(JSON.stringify(payload, "\t") + "\n")
	file.close()


func _run() -> void:
	# Запускаем обычный игровой World и выбираем реальный объект
	# в известной карте; HUD отключаем только ради чистых кадров.
	var folder := _folder()
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(folder))
	root.size = Size
	var view := View.new()
	root.add_child(view)
	for node in view.get_children():
		if node is CanvasLayer:
			node.visible = false
	if not await _wait_chunks(view):
		view.queue_free()
		quit(1)
		return
	view._atmosphere.set_effects_enabled(false)
	view._weather_fx_cooldown = 9999.0
	var tree: Dictionary = _choose_tree(view)
	_check(not tree.is_empty(), "Не найдено живое дерево для приёмки")
	if tree.is_empty():
		view.queue_free()
		quit(1)
		return

	var center := Vector2(float(tree["x"]) + 0.5, float(tree["y"]) + 0.5)
	var vertex := Vector2i(int(tree["x"]), int(tree["y"]))
	var tree_id: int = int(tree["id"])
	view._center = center
	view._camera.size = 44.0
	view._update_camera()
	view._refresh_visible(true)
	if not await _wait_chunks(view):
		view.queue_free()
		quit(1)
		return
	var initial_mesh_y := _mesh_y(view, vertex)
	_check(is_finite(initial_mesh_y), "Не найдена исходная игровая вершина")
	var initial_wood: int = view._nature.wood_total()
	var before := await _capture(folder, "до_кратера")

	# Применяем ту же ручную команду, что доступна игровой сцене:
	# физика, уведомление NatureRegistry, синхронизация и GPU-чанки.
	var previous_revision: int = view._world_model.revision
	view._apply_landscape_event("кратер")
	_check(view._world_model.revision == previous_revision + 1,
		"Игровая команда кратера не изменила геометрию")
	if not await _wait_chunks(view):
		view.queue_free()
		quit(1)
		return
	var crater_mesh_y := _mesh_y(view, vertex)
	var expected_y: float = view._world_model.config.to_scene(
		Vector2(vertex), view._world_model.vertex_at(vertex)).y
	_check(is_finite(crater_mesh_y) and absf(crater_mesh_y - expected_y) < 0.0001,
		"Меш кратера соответствует обновлённому WorldMap")
	_check(absf(crater_mesh_y - initial_mesh_y) > 0.05,
		"Кратер реально сдвинул геометрию игрового чанка")
	_check(view._nature.object_at(tree_id)["state"] == "пень" \
			and int(view._nature.object_at(tree_id)["fallen_wood"]) > 0,
		"Кратер повалил физическое дерево с сохранением древесины")
	_check(view._nature.wood_total() == initial_wood,
		"Удар не создал и не уничтожил древесину")
	_check(_parts(view, tree_id) == ["бревно", "пень"],
		"На новой геометрии нет старой коллизии стоящего ствола")
	var after_crater := await _capture(folder, "после_кратера")
	var crater_pixels := _image_difference(before, after_crater)
	_check(crater_pixels > 40, "Кратер не виден на настоящем игровом кадре")

	# Второе реальное физическое воздействие проверяет, что первая
	# деформация не застыла в кеше и не подменилась старым мешем.
	previous_revision = view._world_model.revision
	view._apply_landscape_event("просадка")
	_check(view._world_model.revision == previous_revision + 1,
		"Последующий тектонический сдвиг не применён")
	if not await _wait_chunks(view):
		view.queue_free()
		quit(1)
		return
	var after_shift := await _capture(folder, "после_сдвига")
	var shift_pixels := _image_difference(after_crater, after_shift)
	_check(shift_pixels > 15,
		"Второе воздействие не перерисовало реальный кадр")
	_check(_parts(view, tree_id) == ["бревно", "пень"],
		"Повторная деформация не вернула старую коллизию дерева")

	# Панорамный LOD снимается уже после обоих физических событий.
	# Переключение детализации не восстанавливает исходные высоты.
	view._change_zoom(82.0 / view._camera.size)
	if not await _wait_chunks(view):
		view.queue_free()
		quit(1)
		return
	await _capture(folder, "панорама_после")
	var physical_before: Dictionary = view._world_model.to_data()
	var nature_before: Dictionary = view._nature.to_data()

	# Полный WorldSave восстанавливает объект и высоты в новом World.
	# После загрузки проверяем и ArrayMesh, и живую коллизию.
	var snapshot: Dictionary = Save.capture(view._storage_models())
	_check(not snapshot.is_empty(), "Не создан полный WorldSave после событий")
	if not snapshot.is_empty():
		var restored: Dictionary = Save.restore(
			JSON.parse_string(JSON.stringify(snapshot)))
		_check(not restored.is_empty(), "Не восстановлен WorldSave с деформациями")
		if not restored.is_empty():
			view._install_loaded_world(restored)
			view._camera.size = 44.0
			view._update_camera()
			view._refresh_visible(true)
			if await _wait_chunks(view):
				await _capture(folder, "после_загрузки")
				_check(view._world_model.to_data() == physical_before \
						and view._nature.to_data() == nature_before,
					"Загрузка изменила физику кратера или древесину")
				_check(_parts(view, tree_id) == ["бревно", "пень"],
					"Коллизии после WorldSave не восстановлены")
				expected_y = view._world_model.config.to_scene(
					Vector2(vertex), view._world_model.vertex_at(vertex)).y
				_check(absf(_mesh_y(view, vertex) - expected_y) < 0.0001,
					"Меш после загрузки не совпадает с физическим миром")

	# CPU-метрики справочные: программный OpenGL CI не измеряет
	# производительность пользовательских видеокарт и смартфонов.
	var manifest := {
		"stage": "11.7", "subtask": "RF4",
		"renderer": "Godot Compatibility / software OpenGL",
		"real_game_world": true, "simulation_physics_changed": true,
		"artistic_approval": false, "pc_android_gpu_verified": false,
		"hardware_fps_verified": false,
		"captures": [
			"до_кратера.png", "после_кратера.png",
			"после_сдвига.png", "панорама_после.png", "после_загрузки.png"
		],
		"tree_id": tree_id, "tree_origin": str(center),
		"crater_changed_sample_pixels": crater_pixels,
		"shift_changed_sample_pixels": shift_pixels,
		"mesh_builds_total": view._chunk_rebuilds,
		"ground_build_cpu_ms": float(view._total_ground_build_us) / 1000.0,
		"nature_attach_cpu_ms": float(view._total_nature_attach_us) / 1000.0,
		"checks_passed": failures.is_empty()
	}
	_write_manifest(folder, manifest)
	view.queue_free()
	if failures.is_empty():
		print("11.7/RF4/GL: физические кадры, коллизии и загрузка — успешно")
		quit(0)
		return
	for message in failures:
		printerr("11.7/RF4/GL: ", message)
	quit(1)


func _initialize() -> void:
	# SceneTree должен сначала создать окно и канал OpenGL,
	# иначе первый снимок получится пустым даже при верной физике.
	call_deferred("_run")
