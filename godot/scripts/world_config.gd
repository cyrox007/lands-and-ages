extends RefCounted
## Неизменяемый после создания контракт пространства. X/Y — координаты карты,
## в сцене Godot им соответствуют X/Z, а высоте — ось Y.

const FORMAT_VERSION := 1
const DEFAULT_WIDTH := 256
const DEFAULT_HEIGHT := 192
const DEFAULT_SEED := 1729
const DEFAULT_CHUNK := 16
const DEFAULT_REGION := 64
const DEFAULT_HEIGHT_SCALE := 0.9

var width: int
var height: int
var seed: int
var chunk_size: int
var region_size: int
var height_scale: float


func _init(p_width: int = DEFAULT_WIDTH, p_height: int = DEFAULT_HEIGHT,
		p_seed: int = DEFAULT_SEED, p_chunk: int = DEFAULT_CHUNK,
		p_region: int = DEFAULT_REGION, p_height_scale: float = DEFAULT_HEIGHT_SCALE) -> void:
	assert(valid_dimensions(p_width, p_height, p_chunk, p_region, p_height_scale))
	width = p_width
	height = p_height
	seed = p_seed
	chunk_size = p_chunk
	region_size = p_region
	height_scale = p_height_scale


static func valid_dimensions(w: int, h: int, chunk: int, region: int, scale: float) -> bool:
	return w >= 1 and w <= 4096 and h >= 1 and h <= 4096 \
		and chunk >= 1 and chunk <= 128 and region >= 1 and region <= 1024 \
		and is_finite(scale) and scale > 0.0 and scale <= 20.0


func contains_cell(cell: Vector2i) -> bool:
	return cell.x >= 0 and cell.y >= 0 and cell.x < width and cell.y < height


func contains_vertex(vertex: Vector2i) -> bool:
	return vertex.x >= 0 and vertex.y >= 0 and vertex.x <= width and vertex.y <= height


func contains_point(point: Vector2) -> bool:
	return is_finite(point.x) and is_finite(point.y) \
		and point.x >= 0.0 and point.y >= 0.0 \
		and point.x < float(width) and point.y < float(height)


func clamp_point(point: Vector2) -> Vector2:
	return Vector2(clampf(point.x, 0.0, float(width) - 0.001),
		clampf(point.y, 0.0, float(height) - 0.001))


func cell_at(point: Vector2) -> Vector2i:
	if not contains_point(point):
		return Vector2i(-1, -1)
	return Vector2i(floori(point.x), floori(point.y))


func to_scene(point: Vector2, elevation: float = 0.0) -> Vector3:
	return Vector3(point.x, elevation * height_scale, point.y)


func from_scene(position: Vector3) -> Vector3:
	return Vector3(position.x, position.z, position.y / height_scale)


func chunk_count() -> Vector2i:
	return Vector2i(ceili(float(width) / float(chunk_size)),
		ceili(float(height) / float(chunk_size)))


func region_count() -> Vector2i:
	return Vector2i(ceili(float(width) / float(region_size)),
		ceili(float(height) / float(region_size)))


func chunk_of(cell: Vector2i) -> Vector2i:
	if not contains_cell(cell):
		return Vector2i(-1, -1)
	return Vector2i(cell.x / chunk_size, cell.y / chunk_size)


func region_of(cell: Vector2i) -> Vector2i:
	if not contains_cell(cell):
		return Vector2i(-1, -1)
	return Vector2i(cell.x / region_size, cell.y / region_size)


func chunk_rect(coord: Vector2i) -> Rect2i:
	return _rect(coord, chunk_size, chunk_count())


func region_rect(coord: Vector2i) -> Rect2i:
	return _rect(coord, region_size, region_count())


func _rect(coord: Vector2i, step: int, count: Vector2i) -> Rect2i:
	if coord.x < 0 or coord.y < 0 or coord.x >= count.x or coord.y >= count.y:
		return Rect2i()
	var origin := coord * step
	return Rect2i(origin, Vector2i(mini(step, width - origin.x),
		mini(step, height - origin.y)))


func region_seed(coord: Vector2i) -> int:
	if region_rect(coord).has_area() == false:
		return -1
	return ((coord.x * 73856093) ^ (coord.y * 19349663) ^ seed) & 0x7fffffff


func to_data() -> Dictionary:
	return {
		"width": width, "height": height, "seed": seed,
		"chunk_size": chunk_size, "region_size": region_size,
		"height_scale": height_scale
	}


static func from_data(data: Dictionary) -> RefCounted:
	for field in ["width", "height", "seed", "chunk_size", "region_size", "height_scale"]:
		if not data.has(field) or not (data[field] is int or data[field] is float):
			return null
	var w := int(data["width"])
	var h := int(data["height"])
	var chunk := int(data["chunk_size"])
	var region := int(data["region_size"])
	var scale := float(data["height_scale"])
	if not valid_dimensions(w, h, chunk, region, scale):
		return null
	if float(w) != float(data["width"]) or float(h) != float(data["height"]):
		return null
	if float(chunk) != float(data["chunk_size"]) or float(region) != float(data["region_size"]):
		return null
	if float(int(data["seed"])) != float(data["seed"]):
		return null
	# Не допускаем случайного открытия файлов с удалённым прототипным генератором.
	if data.has("generator_version"):
		return null
	return load("res://scripts/world_config.gd").new(w, h, int(data["seed"]),
		chunk, region, scale)
