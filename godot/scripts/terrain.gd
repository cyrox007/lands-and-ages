extends RefCounted
## Детерминированные высоты. Формулы согласованы с world-terrain.js.
## Хранение вершин не зависит от порядка загрузки чанков.

const Config = preload("res://scripts/world_config.gd")
const WIDTH := Config.DEFAULT_WIDTH
const HEIGHT := Config.DEFAULT_HEIGHT
const SEED := Config.DEFAULT_SEED
const HEIGHT_SCALE := Config.DEFAULT_HEIGHT_SCALE

static func hash2(x: int, y: int, seed: int) -> float:
	var n: int = (x * 374761393 + y * 668265263 + seed * 1442695041) & 0xffffffff
	n = ((n ^ (n >> 13)) * 1274126177) & 0xffffffff
	n = (n ^ (n >> 16)) & 0xffffffff
	return float(n) / 4294967295.0


static func _noise(x: float, y: float, seed: int) -> float:
	var i := floori(x)
	var j := floori(y)
	var u := smoothstep(0.0, 1.0, x - float(i))
	var v := smoothstep(0.0, 1.0, y - float(j))
	var a := lerpf(hash2(i, j, seed), hash2(i + 1, j, seed), u)
	var b := lerpf(hash2(i, j + 1, seed), hash2(i + 1, j + 1, seed), u)
	return (lerpf(a, b, v) * 2.0) - 1.0


static func _gaussian(x: float, y: float, cx: float, cy: float, rx: float, ry: float) -> float:
	var a := (x - cx) / rx
	var b := (y - cy) / ry
	return exp(-2.0 * (a * a + b * b))


static func vertex_height(x: int, y: int, seed: int = SEED) -> float:
	return vertex_height_on_map(x, y, WIDTH, HEIGHT, seed)


static func vertex_height_on_map(x: int, y: int, width: int, height: int, seed: int) -> float:
	var u := float(x) / float(width)
	var v := float(y) / float(height)
	var hills := _gaussian(u, v, 0.21, 0.28, 0.16, 0.24)
	var lowland := _gaussian(u, v, 0.14, 0.76, 0.19, 0.18)
	var mesa_radius := Vector2((u - 0.71) / 0.15, (v - 0.28) / 0.21).length()
	var plateau := 1.0 - smoothstep(0.78, 1.37, mesa_radius)
	var curved := 0.50 + 0.045 * sin(v * 12.5 + 1.2)
	var trench := exp(-0.5 * pow((u - curved) / 0.035, 2.0))
	var ravine := trench * smoothstep(0.12, 0.26, v) * (1.0 - smoothstep(0.78, 0.96, v))
	var mountains := _gaussian(u, v, 0.85, 0.73, 0.17, 0.30)
	var ridge := _gaussian(u, v, 0.90, 0.59, 0.092, 0.16)
	var gentle := 0.30 * _noise(float(x) / 6.0, float(y) / 6.0, seed)
	gentle += 0.12 * _noise(float(x) / 2.6, float(y) / 2.6, seed + 17)
	var undulation := 0.24 + gentle
	var hill_height := 2.9 * hills * (0.78 + 0.22 * cos(u * 52.0 + v * 19.0))
	var mountain_height := 6.9 * mountains * (0.72 + 0.28 * pow(sin(u * 62.0 - v * 33.0), 2.0))
	return undulation * (1.0 - 0.82 * plateau) + hill_height - 2.6 * lowland \
		+ 4.9 * plateau - 3.2 * ravine + mountain_height + 2.6 * ridge


static func ground_height(x: float, y: float, seed: int = SEED) -> float:
	var ix := clampi(floori(x), 0, WIDTH - 1)
	var iy := clampi(floori(y), 0, HEIGHT - 1)
	var u := clampf(x - float(ix), 0.0, 1.0)
	var v := clampf(y - float(iy), 0.0, 1.0)
	var h00 := vertex_height(ix, iy, seed)
	var h10 := vertex_height(ix + 1, iy, seed)
	var h01 := vertex_height(ix, iy + 1, seed)
	var h11 := vertex_height(ix + 1, iy + 1, seed)
	if u + v <= 1.0:
		return h00 + (h10 - h00) * u + (h01 - h00) * v
	return h11 + (h01 - h11) * (1.0 - u) + (h10 - h11) * (1.0 - v)


static func normal_at(x: int, y: int, seed: int = SEED) -> Vector3:
	var west := vertex_height(x - 1, y, seed)
	var east := vertex_height(x + 1, y, seed)
	var north := vertex_height(x, y - 1, seed)
	var south := vertex_height(x, y + 1, seed)
	return Vector3((west - east) * HEIGHT_SCALE, 2.0, (north - south) * HEIGHT_SCALE).normalized()


static func slope_at(x: int, y: int, seed: int = SEED) -> float:
	var west := vertex_height(x - 1, y, seed)
	var east := vertex_height(x + 1, y, seed)
	var north := vertex_height(x, y - 1, seed)
	var south := vertex_height(x, y + 1, seed)
	return Vector2((east - west) * 0.5, (south - north) * 0.5).length()
