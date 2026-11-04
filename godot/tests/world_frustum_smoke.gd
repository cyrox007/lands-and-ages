extends SceneTree
## Этап 8.4: отбор только видимых GPU-чанков.
## Берега, рельеф и законы природного мира не изменяются.

const View = preload("res://scripts/world.gd")
const Visibility = preload("res://scripts/chunk_visibility.gd")

var failures: Array[String] = []


func _check(valid: bool, reason: String) -> void:
	if not valid:
		failures.append(reason)


func _check_projection() -> void:
	var bounds := Rect2i(Vector2i(-2, -2), Vector2i(4, 4))
	var camera_position := Vector3(0.0, 10.0, 0.0)
	var right := Vector3.RIGHT
	var up := Vector3.UP
	_check(Visibility.intersects(bounds, Vector2(9.0, 11.0),
		camera_position, right, up, 10.0, 1.0),
		"Чанк перед камерой считается видимым")
	_check(not Visibility.intersects(
		Rect2i(Vector2i(25, 0), Vector2i(4, 4)),
		Vector2(9.0, 11.0), camera_position, right, up, 10.0, 1.0),
		"Чанк далеко за пределами экрана отсекается")
	_check(not Visibility.intersects(bounds, Vector2(-20.0, -19.0),
		camera_position, right, up, 10.0, 1.0),
		"Низкий участок можно отсечь по вертикали")
	_check(Visibility.intersects(bounds, Vector2(-20.0, 10.0),
		camera_position, right, up, 10.0, 1.0),
		"Верх высокой горы не пропускается при видимой вершине")
	_check(Visibility.intersects(Rect2i(Vector2i(7, -1), Vector2i(3, 3)),
		Vector2(9.0, 11.0), camera_position, right, up, 10.0, 3.0),
		"На широком экране сохраняется видимость боковых чанков")


func _check_physical_vertices(scene: Node3D) -> int:
	var map: RefCounted = scene._world_model
	var camera: Camera3D = scene._camera
	var basis: Basis = camera.global_transform.basis
	var dimensions: Vector2 = camera.get_viewport().get_visible_rect().size
	var aspect: float = dimensions.x / dimensions.y
	var limit_x: float = camera.size * aspect * 0.5 - 0.4
	var limit_y: float = camera.size * 0.5 - 0.4
	var visible := {}
	for coord in scene._pending:
		visible[coord] = true
	for coord in scene._active.keys():
		visible[coord] = true
	var sampled := 0
	var missing := 0
	for y in range(0, map.config.height + 1, 3):
		for x in range(0, map.config.width + 1, 3):
			var vertex := Vector2i(x, y)
			var position: Vector3 = map.config.to_scene(
				Vector2(vertex), map.vertex_at(vertex))
			var relative: Vector3 = position - camera.global_position
			if absf(basis.x.dot(relative)) > limit_x or \
					absf(basis.y.dot(relative)) > limit_y:
				continue
			var cell := Vector2i(mini(x, map.config.width - 1),
				mini(y, map.config.height - 1))
			var chunk: Vector2i = map.config.chunk_of(cell)
			sampled += 1
			if not visible.has(chunk):
				missing += 1
	_check(sampled > 10, "Камера видит реальные вершины природного мира")
	_check(missing == 0,
		"Ни одна проверенная видимая вершина не осталась без чанка")
	return sampled


func _check_scene() -> void:
	var scene := View.new()
	get_root().add_child(scene)
	if scene._world_model == null or scene._camera == null:
		_check(false, "Игровая сцена не прошла инициализацию")
		scene.queue_free()
		return
	var map: RefCounted = scene._world_model
	var map_before: Dictionary = map.to_data()
	var hydro_before: Dictionary = scene._hydro.water_count()
	var screen: Vector2 = scene._camera.get_viewport().get_visible_rect().size
	_check(screen.y > 0.0, "Размеры тестового Viewport корректны")

	scene._change_zoom(0.1)
	var near_count: int = scene._pending.size()
	var near_radius: int = scene._visible_radius()
	var square_count := 0
	var center_chunk: Vector2i = scene._chunk_center
	for cy in range(center_chunk.y - near_radius, center_chunk.y + near_radius + 1):
		for cx in range(center_chunk.x - near_radius, center_chunk.x + near_radius + 1):
			if map.config.chunk_rect(Vector2i(cx, cy)).has_area():
				square_count += 1
	_check(near_count > 0 and near_count < square_count,
		"Проекция отсекает часть чанков относительно квадрата этапа 8.3")
	var checked: int = _check_physical_vertices(scene)

	var seen := {}
	for coord in scene._pending:
		_check(map.config.chunk_rect(coord).has_area(),
			"В очереди нет чанков за пределами мира")
		_check(not seen.has(coord), "Чанки не дублируются в очереди")
		seen[coord] = true
	scene._refresh_visible(false)
	_check(scene._pending.size() == near_count,
		"Повторное обновление без движения не меняет количество задач")

	# Подвижки меньше размера чанка всё равно обновляют реальную область.
	var first: Vector2 = scene._visibility_center
	scene._move_center(Vector2(1.25, 0.0))
	_check(scene._visibility_center.distance_squared_to(first) > 1.0,
		"Панорама внутри чанка обновляет область загрузки")
	_check(scene._visibility_center.is_equal_approx(scene._center),
		"После перемещения фиксируется фактический центр камеры")
	checked += _check_physical_vertices(scene)

	scene._change_zoom(100.0)
	var far_count: int = scene._pending.size()
	_check(far_count > near_count, "При отдалении охват карты расширяется")
	checked += _check_physical_vertices(scene)

	# Граница высот должна пересчитываться после физической правки.
	var central: Vector2i = scene._chunk_center
	var terrain: Rect2i = map.config.chunk_rect(central)
	var at: Vector2i = terrain.position
	var old: Vector2 = scene._chunk_elevation_bounds(central)
	_check(map.set_vertex(at, 63.5), "Тестовая деформация рельефа принята")
	scene._refresh_visible(false)
	var changed: Vector2 = scene._chunk_elevation_bounds(central)
	_check(changed.y > old.y and changed.y >= 63.5 *
		map.config.height_scale, "Кеш высот обновлён после деформации")
	_check(map.changed_vertex_count() > 0,
		"Изменение высоты остаётся единственным физическим событием теста")
	_check(scene._hydro.water_count() == hydro_before or
		scene._hydro.full_rebuilds > 1,
		"Гидрология реагирует на изменение мира через прежнюю модель")
	print("Этап 8.4: ближний масштаб ", near_count,
		" вместо квадрата ", square_count,
		", дальний ", far_count,
		", видимых вершин проверено ", checked)
	scene.queue_free()
	_check(map_before.get("version") == map.to_data().get("version"),
		"Формат сохранений неизменен")


func _initialize() -> void:
	_run()


func _run() -> void:
	# Дерево сцены должно войти в игровой цикл до добавления World.
	await process_frame
	_check_projection()
	_check_scene()
	if not failures.is_empty():
		for reason in failures.slice(0, 20):
			push_error("Этап 8.4: " + reason)
		quit(1)
		return
	print("Этап 8.4: отсечение невидимых чанков и сохранность физики — успешно.")
	quit(0)
