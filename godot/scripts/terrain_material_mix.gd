extends RefCounted
## Физически обусловленные коэффициенты шести PBR-покрытий.
## Порядок: трава, почва, песок, скала, щебень, снег.

const SurfaceType = preload("res://scripts/surface.gd")
const Appearance = preload("res://scripts/landscape_appearance.gd")

const MATERIALS := 6
const GRASS := 0
const SOIL := 1
const SAND := 2
const ROCK := 3
const GRAVEL := 4
const SNOW := 5


static func _blend(weights: PackedFloat32Array, target: int,
		fraction: float) -> void:
	var amount := clampf(fraction, 0.0, 1.0)
	for index in range(MATERIALS):
		weights[index] *= 1.0 - amount
	weights[target] += amount


static func _cell_weights(cell: Vector2i, height: float, normal: Vector3,
		surface: RefCounted, hydro: RefCounted) -> PackedFloat32Array:
	var index: int = hydro.cell_index(cell)
	var weights := PackedFloat32Array([0.75, 0.25, 0.0, 0.0, 0.0, 0.0])
	if surface.rock_at_index(index):
		_blend(weights, ROCK, 1.0)
	elif surface.exposed_at_index(index):
		var substrate: int = surface.substrate_at_index(index)
		_blend(weights, SAND if substrate == SurfaceType.SAND else GRAVEL, 0.92)
	elif surface.substrate_at_index(index) == SurfaceType.CLAY:
		_blend(weights, SOIL, 0.9)
	elif surface.substrate_at_index(index) == SurfaceType.SAND:
		_blend(weights, SAND, 0.82)

	var slope := 1.0 - clampf(normal.y, 0.0, 1.0)
	_blend(weights, ROCK, smoothstep(0.15, 0.52, slope) * 0.88)
	var depth: float = surface.soil_depth_at_index(index)
	_blend(weights, GRAVEL, (1.0 - clampf(depth / 1.2, 0.0, 1.0)) * 0.34)
	_blend(weights, GRAVEL, smoothstep(3.7, 8.3, height) * 0.17)
	if hydro.has_water(index):
		_blend(weights, SAND, 0.50)
	else:
		var snow: float = surface.snow_at_index(index)
		_blend(weights, SNOW, smoothstep(0.04, 0.9, snow))
	return weights


static func at(vertex: Vector2i, height: float, normal: Vector3,
		world: RefCounted, surface: RefCounted,
		hydro: RefCounted) -> PackedFloat32Array:
	# Усредняем по четырём клеткам, как и прежний цвет вершины.
	# Поэтому на границах GPU-чанков коэффициенты одинаковы.
	var result := PackedFloat32Array([0.0, 0.0, 0.0, 0.0, 0.0, 0.0])
	var cells := 0
	var dry_cells := 0
	for dy in [-1, 0]:
		for dx in [-1, 0]:
			var cell := vertex + Vector2i(dx, dy)
			if not world.config.contains_cell(cell):
				continue
			var weights := _cell_weights(cell, height, normal, surface, hydro)
			for index in range(MATERIALS):
				result[index] += weights[index]
			cells += 1
			if not hydro.has_water(hydro.cell_index(cell)):
				dry_cells += 1

	if cells == 0:
		result[GRASS] = 1.0
		return result

	for index in range(MATERIALS):
		result[index] /= float(cells)
	var nearby: Vector2 = Appearance._near_water(vertex, world, hydro)
	var dry_share := float(dry_cells) / float(cells)
	var gentle := 1.0 - smoothstep(0.14, 0.46,
		1.0 - clampf(normal.y, 0.0, 1.0))
	_blend(result, SAND, nearby.x * dry_share * gentle * 0.60)
	_blend(result, SOIL, nearby.y * dry_share * 0.18)
	return result
