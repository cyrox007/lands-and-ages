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
	return sample_at(vertex, height, normal, world, surface, hydro)["weights"]


static func sample_at(vertex: Vector2i, height: float, normal: Vector3,
		world: RefCounted, surface: RefCounted,
		hydro: RefCounted) -> Dictionary:
	# Веса и влажность берутся из одного физического снимка вершины.
	# У каждого чанка на общей вершине будет одинаковый набор данных.
	# Поэтому на границах GPU-чанков коэффициенты одинаковы.
	var result := PackedFloat32Array([0.0, 0.0, 0.0, 0.0, 0.0, 0.0])
	var cells := 0
	var dry_cells := 0
	var wetness := 0.0
	var frost := 0.0
	for dy in [-1, 0]:
		for dx in [-1, 0]:
			var cell := vertex + Vector2i(dx, dy)
			if not world.config.contains_cell(cell):
				continue
			var weights := _cell_weights(cell, height, normal, surface, hydro)
			for index in range(MATERIALS):
				result[index] += weights[index]
			cells += 1
			var index: int = hydro.cell_index(cell)
			var is_water: bool = hydro.has_water(index)
			var moisture: float = surface.moisture_at_index(index)
			var waterlogging: float = surface.waterlogging_at_index(index)
			# Влажная почва не равна затопленной. Обычная почвенная
			# влага даёт лишь слабый блеск, застой воды — сильный.
			wetness += maxf(moisture * 0.55, waterlogging)
			frost += surface.frost_at_index(index)
			if not is_water:
				dry_cells += 1

	if cells == 0:
		result[GRASS] = 1.0
		return {"weights": result, "conditions": Vector4.ZERO}

	for index in range(MATERIALS):
		result[index] /= float(cells)
	var nearby: Vector2 = Appearance._near_water(vertex, world, hydro)
	var dry_share := float(dry_cells) / float(cells)
	var gentle := 1.0 - smoothstep(0.14, 0.46,
		1.0 - clampf(normal.y, 0.0, 1.0))
	# Даже рядом с морем высокий берег остаётся сухим.
	var water_level := -INF
	for dy in range(-1, 2):
		for dx in range(-1, 2):
			var neighbor := vertex + Vector2i(dx, dy)
			if not world.config.contains_cell(neighbor):
				continue
			var water_index: int = hydro.cell_index(neighbor)
			if hydro.has_water(water_index):
				water_level = maxf(water_level, hydro.level_at(water_index))
	var coastal_height := 0.0
	if is_finite(water_level):
		coastal_height = 1.0 - smoothstep(0.03, 0.65,
			maxf(0.0, height - water_level))
	var shore_factor := coastal_height * gentle * dry_share
	_blend(result, SAND, nearby.x * shore_factor * 0.60)
	_blend(result, SOIL, nearby.y * shore_factor * 0.18)
	var conditions := Vector4(
		clampf(wetness / float(cells), 0.0, 1.0),
		clampf(nearby.x * shore_factor, 0.0, 1.0),
		clampf(frost / float(cells), 0.0, 1.0),
		clampf(nearby.y * shore_factor, 0.0, 1.0))
	return {"weights": result, "conditions": conditions}
