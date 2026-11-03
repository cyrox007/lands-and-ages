extends SceneTree
## Проверка высот, регионов, сетки чанков и сезонных свойств без игровой сцены.

const Terrain = preload("res://scripts/terrain.gd")
const Climate = preload("res://scripts/climate.gd")
const Chunk = preload("res://scripts/chunk.gd")


var _failures: Array[String] = []
var _counter := 0


func _expect(condition: bool, explanation: String = "") -> void:
	_counter += 1
	if not condition:
		_failures.append(explanation if not explanation.is_empty() else "Проверка %d" % _counter)


func _initialize() -> void:
	print("Godot: начало проверки геометрии и климата.")
	_run_checks()


func _run_checks() -> void:
	_expect(Terrain.WIDTH == 256 and Terrain.HEIGHT == 192)
	_expect(Climate.region_id(0, 0) == Vector2i(0, 0))
	_expect(Climate.region_id(255, 191) == Vector2i(3, 2))
	_expect(Climate.season_name(1) == "Весна")
	_expect(Climate.season_name(25) == "Лето")
	_expect(Climate.season_name(49) == "Осень")
	_expect(Climate.season_name(73) == "Зима")
	_expect(Climate.season_name(97) == "Весна")
	for point in [Vector2i(0, 0), Vector2i(16, 16), Vector2i(128, 96), Vector2i(255, 191)]:
		var h := Terrain.vertex_height(point.x, point.y)
		_expect(is_finite(h))
		_expect(is_equal_approx(h, Terrain.vertex_height(point.x, point.y)))
		_expect(absf(h - Terrain.ground_height(float(point.x), float(point.y))) < 0.0001)
	for day in [1, 25, 49, 73]:
		for x in [3, 65, 129, 194]:
			var surface := Climate.surface_at(x, 90, day)
			_expect(float(surface["fertility"]) >= 0.0 and float(surface["fertility"]) <= 1.0)
			_expect(float(surface["moisture"]) >= 0.0 and float(surface["moisture"]) <= 1.0)
			_expect(surface == Climate.surface_at(x, 90, day))
	var mesh_a := Chunk.create_mesh(0, 0, 1)
	var mesh_b := Chunk.create_mesh(1, 0, 1)
	_expect(mesh_a.get_surface_count() == 1)
	var arrays_a := mesh_a.surface_get_arrays(0)
	var arrays_b := mesh_b.surface_get_arrays(0)
	var vertices_a: PackedVector3Array = arrays_a[Mesh.ARRAY_VERTEX]
	var vertices_b: PackedVector3Array = arrays_b[Mesh.ARRAY_VERTEX]
	var indices: PackedInt32Array = arrays_a[Mesh.ARRAY_INDEX]
	_expect(vertices_a.size() == 17 * 17)
	_expect(indices.size() == 16 * 16 * 6)
	_expect(vertices_a[16].distance_to(vertices_b[0]) < 0.0001)
	if not _failures.is_empty():
		for message in _failures:
			push_error("Godot-тест: " + message)
		quit(1)
		return
	print("Godot: высоты, 12 регионов, 4 сезона и швы чанков — успешно.")
	quit(0)
