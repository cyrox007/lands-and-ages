extends SceneTree
## Проверка высот, регионов, сетки чанков и сезонных свойств без игровой сцены.

const Terrain = preload("res://scripts/terrain.gd")
const Climate = preload("res://scripts/climate.gd")
const Chunk = preload("res://scripts/chunk.gd")


func _initialize() -> void:
	call_deferred("_run_checks")


func _run_checks() -> void:
	assert(Terrain.WIDTH == 256 and Terrain.HEIGHT == 192)
	assert(Climate.region_id(0, 0) == Vector2i(0, 0))
	assert(Climate.region_id(255, 191) == Vector2i(3, 2))
	assert(Climate.season_name(1) == "Весна")
	assert(Climate.season_name(25) == "Лето")
	assert(Climate.season_name(49) == "Осень")
	assert(Climate.season_name(73) == "Зима")
	assert(Climate.season_name(97) == "Весна")
	for point in [Vector2i(0, 0), Vector2i(16, 16), Vector2i(128, 96), Vector2i(255, 191)]:
		var h := Terrain.vertex_height(point.x, point.y)
		assert(is_finite(h))
		assert(is_equal_approx(h, Terrain.vertex_height(point.x, point.y)))
		assert(absf(h - Terrain.ground_height(float(point.x), float(point.y))) < 0.0001)
	for day in [1, 25, 49, 73]:
		for x in [3, 65, 129, 194]:
			var surface := Climate.surface_at(x, 90, day)
			assert(float(surface["fertility"]) >= 0.0 and float(surface["fertility"]) <= 1.0)
			assert(float(surface["moisture"]) >= 0.0 and float(surface["moisture"]) <= 1.0)
			assert(surface == Climate.surface_at(x, 90, day))
	var mesh_a := Chunk.create_mesh(0, 0, 1)
	var mesh_b := Chunk.create_mesh(1, 0, 1)
	assert(mesh_a.get_surface_count() == 1)
	var arrays_a := mesh_a.surface_get_arrays(0)
	var arrays_b := mesh_b.surface_get_arrays(0)
	var vertices_a: PackedVector3Array = arrays_a[Mesh.ARRAY_VERTEX]
	var vertices_b: PackedVector3Array = arrays_b[Mesh.ARRAY_VERTEX]
	var indices: PackedInt32Array = arrays_a[Mesh.ARRAY_INDEX]
	assert(vertices_a.size() == 17 * 17)
	assert(indices.size() == 16 * 16 * 6)
	assert(vertices_a[16].distance_to(vertices_b[0]) < 0.0001)
	print("Godot: высоты, 12 регионов, 4 сезона и швы чанков — успешно.")
	quit(0)
