extends RefCounted
## Источник данных карты: параметры мира, процедурная основа и редкие изменения.
## Камера и рендер не управляют состоянием карты.

signal vertices_changed(chunks: Array[Vector2i], revision: int)

const Config = preload("res://scripts/world_config.gd")
const Terrain = preload("res://scripts/terrain.gd")
const SAVE_VERSION := 2
const MIN_HEIGHT := -64.0
const MAX_HEIGHT := 64.0
const HEIGHT_UNITS := 1000000.0

var config: RefCounted
var revision := 0
var _heights: Dictionary = {}
var _dirty: Dictionary = {}
var _base_cache: Dictionary = {}
const BASE_CACHE_LIMIT := 65536


func _init(p_config: RefCounted = null) -> void:
	config = p_config if p_config != null else Config.new()


func vertex_id(coord: Vector2i) -> int:
	return coord.y * (config.width + 1) + coord.x


func vertex_at(coord: Vector2i) -> float:
	if not config.contains_vertex(coord):
		return NAN
	var key := vertex_id(coord)
	if _heights.has(key):
		return float(_heights[key])
	return _base_height(coord)


func _base_height(coord: Vector2i) -> float:
	var key := vertex_id(coord)
	if _base_cache.has(key):
		return float(_base_cache[key])
	# Восстанавливаем старую геометрию сохранённых миров по версии:
	# новая физическая форма не должна перескакивать под объектами.
	var value := Terrain.vertex_height_on_map(coord.x, coord.y,
		config.width, config.height, config.world_seed, config.relief_version)
	if _base_cache.size() >= BASE_CACHE_LIMIT:
		_base_cache.clear()
	_base_cache[key] = value
	return value


func height_at(point: Vector2) -> float:
	if not config.contains_point(point):
		return NAN
	var cell: Vector2i = config.cell_at(point)
	var u := point.x - float(cell.x)
	var v := point.y - float(cell.y)
	var h00 := vertex_at(cell)
	var h10 := vertex_at(cell + Vector2i(1, 0))
	var h01 := vertex_at(cell + Vector2i(0, 1))
	var h11 := vertex_at(cell + Vector2i(1, 1))
	if u + v <= 1.0:
		return h00 + (h10 - h00) * u + (h01 - h00) * v
	return h11 + (h01 - h11) * (1.0 - u) + (h10 - h11) * (1.0 - v)


func normal_at(vertex: Vector2i) -> Vector3:
	if not config.contains_vertex(vertex):
		return Vector3.ZERO
	var left := vertex_at(Vector2i(maxi(vertex.x - 1, 0), vertex.y))
	var right := vertex_at(Vector2i(mini(vertex.x + 1, config.width), vertex.y))
	var up := vertex_at(Vector2i(vertex.x, maxi(vertex.y - 1, 0)))
	var down := vertex_at(Vector2i(vertex.x, mini(vertex.y + 1, config.height)))
	var dx := float(2 if vertex.x > 0 and vertex.x < config.width else 1)
	var dy := float(2 if vertex.y > 0 and vertex.y < config.height else 1)
	return Vector3((left - right) * config.height_scale / dx,
		1.0, (up - down) * config.height_scale / dy).normalized()


func chunk_at(cell: Vector2i) -> Dictionary:
	var coord: Vector2i = config.chunk_of(cell)
	if coord.x < 0:
		return {}
	return {
		"coord": coord, "bounds": config.chunk_rect(coord),
		"id": coord.y * config.chunk_count().x + coord.x
	}


func region_at(cell: Vector2i) -> Dictionary:
	var coord: Vector2i = config.region_of(cell)
	if coord.x < 0:
		return {}
	return {
		"coord": coord, "bounds": config.region_rect(coord),
		"id": coord.y * config.region_count().x + coord.x,
		"seed": config.region_seed(coord)
	}


func set_vertex(coord: Vector2i, height_value: float) -> bool:
	return apply_vertex_changes({coord: height_value})


func apply_vertex_changes(changes: Dictionary) -> bool:
	# Сначала проверяем пакет целиком: недопустимая запись ничего не изменяет.
	if changes.is_empty():
		return false
	var planned := {}
	for coord in changes.keys():
		if not (coord is Vector2i):
			return false
		if not config.contains_vertex(coord):
			return false
		if not (changes[coord] is float or changes[coord] is int):
			return false
		var value := float(changes[coord])
		if not is_finite(value) or value < MIN_HEIGHT or value > MAX_HEIGHT:
			return false
		# Фиксированная точность исключает потерю разрядов при записи JSON.
		value = round(value * HEIGHT_UNITS) / HEIGHT_UNITS
		if not is_equal_approx(vertex_at(coord), value):
			planned[coord] = value
	if planned.is_empty():
		return false
	var affected := {}
	for coord in planned.keys():
		var value: float = planned[coord]
		var baseline := _base_height(coord)
		var key := vertex_id(coord)
		if is_equal_approx(value, baseline):
			_heights.erase(key)
		else:
			_heights[key] = value
		for cy in [coord.y - 1, coord.y]:
			for cx in [coord.x - 1, coord.x]:
				var cell := Vector2i(cx, cy)
				if not config.contains_cell(cell):
					continue
				affected[config.chunk_of(cell)] = true
	revision += 1
	var chunks: Array[Vector2i] = []
	for chunk in affected.keys():
		chunks.append(chunk)
		_dirty[chunk] = true
	chunks.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
		return a.y < b.y or (a.y == b.y and a.x < b.x))
	vertices_changed.emit(chunks, revision)
	return true


func take_dirty_chunks() -> Array[Vector2i]:
	var result: Array[Vector2i] = []
	for key in _dirty.keys():
		result.append(key)
	result.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
		return a.y < b.y or (a.y == b.y and a.x < b.x))
	_dirty.clear()
	return result


func changed_vertex_count() -> int:
	return _heights.size()


func to_data() -> Dictionary:
	var keys := _heights.keys()
	keys.sort()
	var changes := []
	for key in keys:
		var index: int = int(key)
		changes.append([index % (config.width + 1),
			index / (config.width + 1), roundi(float(_heights[key]) * HEIGHT_UNITS)])
	return {
		"version": SAVE_VERSION,
		"config": config.to_data(),
		"vertices": changes
	}


static func from_data(data: Dictionary) -> RefCounted:
	if data.get("version") != SAVE_VERSION or not (data.get("config") is Dictionary):
		return null
	if not (data.get("vertices") is Array):
		return null
	var loaded_config: RefCounted = Config.from_data(data["config"])
	if loaded_config == null:
		return null
	var raw_changes: Array = data["vertices"]
	if raw_changes.size() > (loaded_config.width + 1) * (loaded_config.height + 1):
		return null
	var planned := {}
	for raw in raw_changes:
		if not (raw is Array) or raw.size() != 3:
			return null
		if not (raw[0] is int or raw[0] is float) or not (raw[1] is int or raw[1] is float):
			return null
		if not (raw[2] is int or raw[2] is float):
			return null
		var coord := Vector2i(int(raw[0]), int(raw[1]))
		if float(coord.x) != float(raw[0]) or float(coord.y) != float(raw[1]):
			return null
		var raw_units := float(raw[2])
		if not is_finite(raw_units) or raw_units != float(int(raw_units)):
			return null
		var value := raw_units / HEIGHT_UNITS
		if not loaded_config.contains_vertex(coord) or not is_finite(value):
			return null
		if value < MIN_HEIGHT or value > MAX_HEIGHT or planned.has(coord):
			return null
		planned[coord] = value
	var result = load("res://scripts/world_map.gd").new(loaded_config)
	if not planned.is_empty():
		result.apply_vertex_changes(planned)
		result.take_dirty_chunks()
		result.revision = 0
	return result
