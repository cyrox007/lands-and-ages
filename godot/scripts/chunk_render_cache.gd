extends RefCounted
## Ограниченный LRU-кеш готовых GPU-чанков.
## Удерживает только невидимые меши; физические данные не дублирует.

# При движении сохраняем больше уже построенных чанков, но предел памяти
# остаётся прежним. Ранее 24 записи вытеснялись при ~2.7 МиБ из 12 МиБ.
const MAX_CHUNKS := 96
const MAX_ESTIMATED_BYTES := 12 * 1024 * 1024
const BYTES_PER_VERTEX := 64
const BYTES_PER_INDEX := 4

var _items: Dictionary = {}
var _order: Array[Vector2i] = []
var estimated_bytes := 0
var hits := 0
var evictions := 0


func count() -> int:
	return _items.size()


func has(coord: Vector2i) -> bool:
	return _items.has(coord)


func take(coord: Vector2i) -> Node3D:
	if not _items.has(coord):
		return null
	var item: Dictionary = _items[coord]
	_items.erase(coord)
	_order.erase(coord)
	estimated_bytes -= int(item["bytes"])
	var node: Node3D = item["node"]
	node.visible = true
	hits += 1
	return node


func put(coord: Vector2i, node: Node3D) -> void:
	if node == null:
		return
	if _items.has(coord):
		_evict(coord)
	var bytes := _estimate_node_bytes(node)
	if bytes > MAX_ESTIMATED_BYTES:
		evictions += 1
		node.queue_free()
		return
	node.visible = false
	_items[coord] = {"node": node, "bytes": bytes}
	_order.append(coord)
	estimated_bytes += bytes
	while _items.size() > MAX_CHUNKS or estimated_bytes > MAX_ESTIMATED_BYTES:
		_evict(_order[0])


func clear() -> void:
	for item in _items.values():
		var node: Node3D = item["node"]
		node.queue_free()
	_items.clear()
	_order.clear()
	estimated_bytes = 0


func _evict(coord: Vector2i) -> void:
	var item: Dictionary = _items[coord]
	_items.erase(coord)
	_order.erase(coord)
	estimated_bytes -= int(item["bytes"])
	var node: Node3D = item["node"]
	node.queue_free()
	evictions += 1


static func _estimate_node_bytes(node: Node3D) -> int:
	# Оценка верхнего порядка для позиций, нормалей, цвета, UV и индексов.
	# Это не фактический объём VRAM, который зависит от драйвера.
	var bytes := 0
	for child in node.get_children():
		if not child is MeshInstance3D:
			continue
		var mesh: Mesh = child.mesh
		if mesh == null:
			continue
		for surface in range(mesh.get_surface_count()):
			bytes += mesh.surface_get_array_len(surface) * BYTES_PER_VERTEX
			bytes += mesh.surface_get_array_index_len(surface) * BYTES_PER_INDEX
	return bytes
