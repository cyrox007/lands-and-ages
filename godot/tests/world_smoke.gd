extends SceneTree
## Регрессия исходного GPU-полигона после объединения климатических алгоритмов.

const Terrain = preload("res://scripts/terrain.gd")
const Climate = preload("res://scripts/climate.gd")
const Chunk = preload("res://scripts/chunk.gd")
const Config = preload("res://scripts/world_config.gd")
const WorldMap = preload("res://scripts/world_map.gd")
const Hydrology = preload("res://scripts/hydrology.gd")
const Surface = preload("res://scripts/surface.gd")

var failures: Array[String] = []


func _check(ok: bool, message: String) -> void:
	if not ok:
		failures.append(message)


func _initialize() -> void:
	var world := WorldMap.new(Config.new())
	var hydro := Hydrology.new(world)
	hydro.rebuild()
	var surface := Surface.new(world, hydro)
	surface.rebuild()
	var climate := Climate.new(world, hydro)
	climate.rebuild()
	_check(Terrain.WIDTH == 256 and Terrain.HEIGHT == 192,
		"Испытательная карта сохраняет размеры")
	_check(Climate.season_name(0) == "весна"
		and Climate.season_name(24) == "лето"
		and Climate.season_name(48) == "осень"
		and Climate.season_name(72) == "зима"
		and Climate.season_name(96) == "весна",
		"Все четыре сезона упорядочены")

	for point in [Vector2i(0, 0), Vector2i(16, 16),
			Vector2i(128, 96), Vector2i(255, 191)]:
		var elevation: float = world.vertex_at(point)
		_check(is_finite(elevation) and is_equal_approx(elevation,
			Terrain.vertex_height(point.x, point.y)), "Геометрия детерминирована")
		var weather: Dictionary = climate.weather_at(Vector2i(
			mini(point.x, 255), mini(point.y, 191)))
		_check(is_finite(float(weather["temperature"])), "Климат конечный")

	var mesh_a := Chunk.create_mesh(0, 0, 1, world, surface, 4, climate)
	var mesh_b := Chunk.create_mesh(1, 0, 1, world, surface, 4, climate)
	_check(mesh_a.get_surface_count() == 1, "Чанк создаёт GPU-меш")
	var vertices_a: PackedVector3Array = mesh_a.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	var vertices_b: PackedVector3Array = mesh_b.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	_check(vertices_a.size() == 289, "Полный чанк имеет 17×17 вершин")
	_check(vertices_a[16].distance_to(vertices_b[0]) < 0.0001,
		"Общие вершины чанков не имеют швов")
	_check(mesh_a.surface_get_arrays(0)[Mesh.ARRAY_INDEX].size() == 1536,
		"Треугольники чанка не изменились")

	if not failures.is_empty():
		for message in failures:
			push_error("Godot-тест: " + message)
		quit(1)
		return
	print("Godot: рельеф, GPU-чанки, климат и швы — успешно.")
	quit(0)
