extends SceneTree
## Регрессия визуального рельефа: реальные гребни и овраги, стыки чанков.
## Зелёный headless не означает художественную приёмку реального кадра.

const Config = preload("res://scripts/world_config.gd")
const WorldMap = preload("res://scripts/world_map.gd")
const Hydrology = preload("res://scripts/hydrology.gd")
const Surface = preload("res://scripts/surface.gd")
const Chunk = preload("res://scripts/chunk.gd")
const Features = preload("res://scripts/relief_visual_features.gd")
const GroundShader = preload("res://shaders/natural_ground.gdshader")

var failures: Array[String] = []


func _check(ok: bool, reason: String) -> void:
	## Запоминаем все нарушения, чтобы CI не останавливался на первом.
	if not ok:
		failures.append(reason)


func _initialize() -> void:
	## SceneTree готов к созданию ArrayMesh без игровой сцены.
	_run()


func _run() -> void:
	var world := WorldMap.new(Config.new(32, 24, 1729, 8, 16))
	var point := Vector2i(8, 8)
	var original: float = world.vertex_at(point)
	var initial_shape: Vector2 = Features.sample_at(world, point)

	# Создаём настоящую выпуклую вершину через единственный WorldMap,
	# а не при помощи смещения вершин в шейдере.
	_check(world.set_vertex(point, original + 4.0),
		"Можно создать физический гребень")
	var ridge: Vector2 = Features.sample_at(world, point)
	_check(ridge.x > 0.8 and ridge.y < 0.01,
		"Высокий гребень распознаётся по физическим отметкам")

	# Меняем ту же вершину на реальную впадину: визуальная маска
	# должна сменить знак вместе с высотой, не сохраняя старое значение.
	_check(world.set_vertex(point, original - 4.0),
		"Можно создать физический овраг")
	var ravine: Vector2 = Features.sample_at(world, point)
	_check(ravine.y > 0.8 and ravine.x < 0.01,
		"Врезанный овраг распознаётся по тем же физическим данным")
	_check(initial_shape.x >= 0.0 and initial_shape.y >= 0.0,
		"Обычная карта имеет конечные маски")
	_check(Features.sample_at(world, Vector2i(-1, 3)) == Vector2.ZERO,
		"Вне физической карты маски отсутствуют")

	var hydro := Hydrology.new(world)
	hydro.rebuild()
	var surface := Surface.new(world, hydro)
	surface.rebuild()
	hydro.apply_rainfall_map(surface.runoff_map())
	var before_world: Dictionary = world.to_data()
	var before_ground: Dictionary = surface.to_snapshot()
	var before_water: Dictionary = hydro.to_snapshot()
	var started := Time.get_ticks_usec()

	var a: Array = Chunk.prepare_arrays(0, 1, 1, world, surface, 0, null, hydro)
	var b: Array = Chunk.prepare_arrays(1, 1, 1, world, surface, 0, null, hydro)
	var elapsed := Time.get_ticks_usec() - started
	var a_shape: PackedByteArray = a[Mesh.ARRAY_CUSTOM1]
	var b_shape: PackedByteArray = b[Mesh.ARRAY_CUSTOM1]
	var a_vertices: PackedVector3Array = a[Mesh.ARRAY_VERTEX]
	var b_vertices: PackedVector3Array = b[Mesh.ARRAY_VERTEX]
	_check(a_shape.size() == a_vertices.size() * 4
		and b_shape.size() == b_vertices.size() * 4,
		"Каждой физической и береговой вершине соответствуют четыре байта формы")

	# На общем ребре чанков сравниваем одинаковые физические точки,
	# включая цветовые маски. Сами вершины остаются неизменными.
	for y in range(9):
		var left := y * 9 + 8
		var right := y * 9
		_check(a_vertices[left] == b_vertices[right],
			"Общее ребро рельефа не расходится")
		for channel in range(4):
			_check(a_shape[left * 4 + channel] == b_shape[right * 4 + channel],
				"Маски формы не образуют шва на соседних чанках")

	# Создание GPU-меша должно принимать оба пользовательских канала,
	# без изменения изначального количества высот и индексов.
	var mesh := Chunk.mesh_from_arrays(a)
	_check(mesh.get_surface_count() == 1,
		"Godot принимает дополнительные маски формы")
	var shader: String = GroundShader.code
	_check(shader.contains("ground_shape = CUSTOM1")
		and shader.contains("relief_contrast")
		and shader.contains("float ravine") and shader.contains("float ridge"),
		"PBR использует маски реальных гребней и впадин")
	_check(not shader.contains("VERTEX ="),
		"Шейдер не подменяет физическую поверхность")

	_check(world.to_data() == before_world
		and surface.to_snapshot() == before_ground
		and hydro.to_snapshot() == before_water,
		"Построение масок не изменило карту, грунт или воду")
	print("Рельеф: построение двух чанков — ", elapsed, " мкс")

	if failures.is_empty():
		print("Рельеф: визуальные гребни, овраги и стыки — успешно")
		quit(0)
		return
	for error in failures:
		printerr("Рельеф: ", error)
	quit(1)
