extends SceneTree
## Этап 8.5: ограниченная память кэшей и повторное использование GPU-мешей.

const View = preload("res://scripts/world.gd")
const Cache = preload("res://scripts/chunk_render_cache.gd")

var failures: Array[String] = []


func _check(ok: bool, description: String) -> void:
	if not ok:
		failures.append(description)


func _test_cache_limit() -> void:
	var holder := Node3D.new()
	get_root().add_child(holder)
	var cache := Cache.new()
	var earliest: Node3D
	for i in range(Cache.MAX_CHUNKS + 10):
		var node := Node3D.new()
		holder.add_child(node)
		if i == 0:
			earliest = node
		cache.put(Vector2i(i, 0), node)
		_check(cache.count() <= Cache.MAX_CHUNKS,
			"Кеш не превышает установленное число чанков")
		_check(cache.estimated_bytes <= Cache.MAX_ESTIMATED_BYTES,
			"Оценка памяти остаётся внутри установленного лимита")
	_check(cache.evictions == 10, "При переполнении вытесняются старые записи")
	_check(earliest.is_queued_for_deletion(),
		"Самый старый узел запланирован к освобождению")
	var last := Vector2i(Cache.MAX_CHUNKS + 9, 0)
	var reused: Node3D = cache.take(last)
	_check(reused != null and reused.visible and cache.hits == 1,
		"Повторно взятый меш показывается без создания нового")
	_check(cache.count() == Cache.MAX_CHUNKS - 1,
		"Изъятый узел больше не занимает место в кеше")
	cache.clear()
	_check(cache.count() == 0 and cache.estimated_bytes == 0,
		"Очистка освобождает записи и их оценочную память")
	holder.queue_free()


func _test_pan_cache_capacity() -> void:
	# При долгой панораме раньше хватало лишь на 24 готовых чанка,
	# хотя установленный предел памяти почти не использовался.
	var holder := Node3D.new()
	get_root().add_child(holder)
	var cache := Cache.new()
	var nodes: Array[Node3D] = []
	for x in range(72):
		var node := Node3D.new()
		holder.add_child(node)
		nodes.append(node)
		cache.put(Vector2i(x, 0), node)
	_check(cache.count() == 72 and cache.evictions == 0,
		"При движении кеш удерживает 72 небольших участка без вытеснения")
	_check(cache.estimated_bytes <= Cache.MAX_ESTIMATED_BYTES,
		"Увеличенный кеш сохраняет прежний предел памяти")
	var restored := cache.take(Vector2i(0, 0))
	_check(restored == nodes[0] and cache.hits == 1,
		"Первый участок повторно используется без пересоздания GPU-меша")
	cache.clear()
	holder.queue_free()


func _test_mesh_estimate() -> void:
	var vertices := PackedVector3Array([
		Vector3(0, 0, 0), Vector3(1, 0, 0), Vector3(0, 1, 0)
	])
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_INDEX] = PackedInt32Array([0, 1, 2])
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var node := Node3D.new()
	var child := MeshInstance3D.new()
	child.mesh = mesh
	node.add_child(child)
	_check(Cache._estimate_node_bytes(node) ==
		3 * Cache.BYTES_PER_VERTEX + 3 * Cache.BYTES_PER_INDEX,
		"Оценка геометрии учитывает вершины и индексы")
	node.free()


func _test_height_cache() -> void:
	var view := View.new()
	for i in range(View.HEIGHT_BOUNDS_CACHE_LIMIT + 40):
		view._remember_height_bounds(Vector2i(i, 0), Vector2(-1.0, 8.0))
	_check(view._chunk_height_bounds.size() == View.HEIGHT_BOUNDS_CACHE_LIMIT,
		"Кеш высот не растёт бесконечно при движении по большой карте")
	_check(view._chunk_height_order.size() == View.HEIGHT_BOUNDS_CACHE_LIMIT,
		"Очередь вытеснения высот ограничена тем же пределом")
	_check(not view._chunk_height_bounds.has(Vector2i(0, 0)),
		"Старые границы высот вытесняются")
	_check(view._chunk_height_bounds.has(
		Vector2i(View.HEIGHT_BOUNDS_CACHE_LIMIT + 39, 0)),
		"Последние посещённые границы остаются в кеше")
	view.free()


func _test_scene_reuse() -> void:
	var scene := View.new()
	get_root().add_child(scene)
	if scene._world_model == null:
		_check(false, "Сцена должна инициализировать карту")
		return
	var map: RefCounted = scene._world_model
	var physical_before: Dictionary = map.to_data()
	scene._change_zoom(0.1)
	_check(not scene._pending.is_empty(), "Ближний масштаб загрузил чанки")
	if scene._pending.is_empty():
		scene.queue_free()
		return
	var coord: Vector2i = scene._pending[0]
	scene._create_chunk(coord)
	var node: Node3D = scene._active[coord]
	var built: int = scene._chunk_rebuilds
	scene._move_center(Vector2(96.0, 0.0))
	_check(scene._render_cache.has(coord),
		"После ухода из кадра ранее построенный меш удерживается кешем")
	_check(not node.visible, "Кешированный меш перестаёт отрисовываться")
	scene._move_center(Vector2(-96.0, 0.0))
	_check(scene._active.get(coord) == node and node.visible,
		"При возврате камера использует тот же экземпляр чанка")
	_check(scene._chunk_rebuilds == built and scene._render_cache.hits > 0,
		"Возврат не требует повторного построения GPU-меша")

	# Ни физическая деформация, ни новая погода не должны отдавать
	# старые визуальные данные из кеша.
	scene._move_center(Vector2(96.0, 0.0))
	_check(scene._render_cache.has(coord), "Перед правкой чанк снова в кеше")
	var at := Vector2i(128, 96)
	_check(map.set_vertex(at, map.vertex_at(at) + 0.15),
		"Модель принимает локальное изменение высоты")
	scene._refresh_visible(false)
	_check(scene._render_cache.count() == 0,
		"Физическая ревизия очищает устаревшую геометрию")
	_check(node.is_queued_for_deletion(),
		"Устаревший меш освобождается, а не повторно используется")
	_check(scene._render_cache.estimated_bytes == 0,
		"После инвалидизации не удерживается память GPU-кеша")
	_check(map.revision == 1 and
		map.to_data()["config"] == physical_before["config"],
		"Оптимизация не меняет формат и параметры физической карты")

	scene._frame_samples.clear()
	for i in range(View.FRAME_SAMPLE_LIMIT + 15):
		scene._record_frame(1.0 / 60.0)
	_check(scene._frame_samples.size() == View.FRAME_SAMPLE_LIMIT,
		"Время кадров хранится в ограниченном окне")
	_check(absf(View._frame_percentile(scene._frame_samples, 0.95) -
		1000.0 / 60.0) < 0.1, "p95 времени кадра рассчитывается корректно")
	print("Этап 8.5: попаданий кеша ", scene._render_cache.hits,
		", сохранено пересборок ", built,
		", ограничение высот ", View.HEIGHT_BOUNDS_CACHE_LIMIT,
		", выборка кадров ", scene._frame_samples.size())
	scene.queue_free()


func _initialize() -> void:
	_run()


func _run() -> void:
	await process_frame
	_test_cache_limit()
	_test_pan_cache_capacity()
	_test_mesh_estimate()
	_test_height_cache()
	_test_scene_reuse()
	if not failures.is_empty():
		for reason in failures.slice(0, 20):
			push_error("Этап 8.5: " + reason)
		quit(1)
		return
	print("Этап 8.5: кэширование чанков, память и измерения — успешно.")
	quit(0)
