extends SceneTree
## Этап 8.2: береговая геометрия зависит от физических высот.
## Визуальные материалы не изменяют карту и гидрологию.

const Config = preload("res://scripts/world_config.gd")
const WorldMap = preload("res://scripts/world_map.gd")
const Hydrology = preload("res://scripts/hydrology.gd")
const Surface = preload("res://scripts/surface.gd")
const WaterMesh = preload("res://scripts/water_mesh.gd")
const GroundShader = preload("res://shaders/natural_ground.gdshader")
const WaterShader = preload("res://shaders/natural_water.gdshader")

var failures: Array[String] = []


func _check(ok: bool, reason: String) -> void:
	if not ok:
		failures.append(reason)


func _check_clipping() -> void:
	var triangle := PackedVector2Array([
		Vector2(0.0, 0.0), Vector2(0.0, 1.0), Vector2(1.0, 0.0)
	])
	var partly := WaterMesh._clip_submerged_triangle(triangle,
		PackedFloat32Array([-1.0, 1.0, -1.0]), 0.0)
	_check(partly.size() == 4, "Берег пересекает склон по двум ребрам")
	var wet := 0
	var edge := 0
	for point in partly:
		_check(point.x >= 0.0 and point.y >= 0.0 and
			point.x + point.y <= 1.00001, "Кромка остается внутри клетки")
		_check(-1.0 + 2.0 * point.y <= 0.00001,
			"Водный полигон не перекрывает участок над уровнем воды")
		_check(point.z >= 0.0 and point.z <= 1.0,
			"Глубина береговой фактуры в диапазоне 0..1")
		if point.z < 0.00001:
			edge += 1
		else:
			wet += 1
	_check(edge == 2 and wet == 2,
		"У пересечения есть два края и две подводные вершины")

	var full := WaterMesh._clip_submerged_triangle(triangle,
		PackedFloat32Array([-2.0, -2.0, -2.0]), 0.0)
	var dry := WaterMesh._clip_submerged_triangle(triangle,
		PackedFloat32Array([2.0, 2.0, 2.0]), 0.0)
	_check(full.size() == 3 and dry.is_empty(),
		"Сухие и полностью затопленные треугольники различаются")
	for point in full:
		_check(is_equal_approx(point.z, 1.0),
			"В глубокой воде береговая кромка не появляется")


func _check_world_meshes() -> void:
	var world := WorldMap.new(Config.new(64, 48, 1729, 16, 32))
	var hydro := Hydrology.new(world)
	hydro.rebuild()
	var surface := Surface.new(world, hydro)
	surface.rebuild()
	var map_before: Dictionary = world.to_data()
	var hydro_before: Dictionary = hydro.to_snapshot()
	var surface_before: Dictionary = surface.to_snapshot()
	var coastal_cells := 0
	for y in range(world.config.height):
		for x in range(world.config.width):
			var cell := Vector2i(x, y)
			var index: int = hydro.cell_index(cell)
			if not hydro.has_water(index):
				continue
			if hydro.river_at(index) and not hydro.lake_at(index) and \
					not hydro.ocean_at(index):
				continue
			var level: float = hydro.level_at(index)
			var high := -INF
			var low := INF
			for corner in [
				cell, cell + Vector2i(1, 0),
				cell + Vector2i(0, 1), cell + Vector2i(1, 1)
			]:
				var height: float = world.vertex_at(corner)
				high = maxf(high, height)
				low = minf(low, height)
			if low < level - 0.01 and high > level + 0.01:
				coastal_cells += 1

	var started := Time.get_ticks_usec()
	var vertices_count := 0
	var edge_vertices := 0
	for cy in range(world.config.chunk_count().y):
		for cx in range(world.config.chunk_count().x):
			var mesh: ArrayMesh = WaterMesh.create_mesh(
				world, hydro, Vector2i(cx, cy), surface)
			if mesh.get_surface_count() == 0:
				continue
			var arrays: Array = mesh.surface_get_arrays(0)
			var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
			var uv: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV]
			_check(uv.size() == vertices.size(),
				"Все вершины воды имеют береговые UV")
			_check(vertices.size() <= 256 * 24,
				"Берег не увеличивает сетку больше защитного лимита")
			vertices_count += vertices.size()
			for i in range(mini(vertices.size(), uv.size())):
				var point: Vector3 = vertices[i]
				var depth: float = uv[i].x
				_check(is_finite(point.x) and is_finite(point.y) and
					is_finite(point.z), "Геометрия воды конечна")
				_check(is_finite(depth) and depth >= 0.0 and depth <= 1.0,
					"UV воды содержит допустимую глубину")
				if depth < 0.999:
					edge_vertices += 1

	var elapsed := Time.get_ticks_usec() - started
	_check(coastal_cells > 0, "На тестовой карте есть физическая береговая линия")
	_check(edge_vertices > 0,
		"GPU-полигоны содержат плавную береговую кромку")
	_check(vertices_count > 0, "Вода реально попала в GPU-меши")
	_check(elapsed < 10000000, "Генерация водных чанков укладывается в 10 секунд")
	_check(world.to_data() == map_before and
		hydro.to_snapshot() == hydro_before and
		surface.to_snapshot() == surface_before,
		"Отрисовка не меняет физику, сток, снег и грунты")
	print("Этап 8.2: береговых клеток ", coastal_cells,
		", береговых вершин ", edge_vertices,
		", вершин воды ", vertices_count,
		", время ", elapsed, " мкс")


func _check_shaders() -> void:
	_check(GroundShader is Shader and WaterShader is Shader,
		"Шейдеры грунта и воды загружаются")
	_check(GroundShader.code.contains("ground_steepness") and
		GroundShader.code.contains("strata"),
		"Слоистость гор зависит от уклона, а не новой карты высот")
	_check(WaterShader.code.contains("UV.x") and
		WaterShader.code.contains("ALPHA"),
		"Береговая фактура читает глубину и сохраняет прозрачность")
	_check(not GroundShader.code.contains("VERTEX =") and
		not WaterShader.code.contains("VERTEX ="),
		"Шейдеры не изменяют физические вершины")


func _initialize() -> void:
	_check_clipping()
	_check_world_meshes()
	_check_shaders()
	if not failures.is_empty():
		for reason in failures.slice(0, 20):
			push_error("Этап 8.2: " + reason)
		quit(1)
		return
	print("Этап 8.2: скальные материалы и геометрия берега — успешно.")
	quit(0)
