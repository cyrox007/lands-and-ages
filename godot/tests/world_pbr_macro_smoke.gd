extends SceneTree
## Этап 9.2: пространственное разнообразие PBR без швов и изменения физики.

const Config = preload("res://scripts/world_config.gd")
const WorldMap = preload("res://scripts/world_map.gd")
const Hydro = preload("res://scripts/hydrology.gd")
const Surface = preload("res://scripts/surface.gd")
const Chunk = preload("res://scripts/chunk.gd")
const View = preload("res://scripts/world.gd")
const GroundShader = preload("res://shaders/natural_ground.gdshader")

var failures: Array[String] = []


func _check(ok: bool, reason: String) -> void:
	if not ok:
		failures.append(reason)


func _check_shader() -> void:
	var code: String = GroundShader.code
	_check(code.contains("terrain_albedo") and
		code.contains("terrain_normal_roughness"),
		"Реальные цветовые и нормальные атласы сохранены")
	_check(code.contains("terrain_noise") and
		code.contains("domain_warp") and code.contains("ground_position.xz"),
		"Сдвиг текстур зависит от непрерывных мировых координат")
	_check(code.contains("float mixing") and
		code.contains("float variation") and
		code.contains("float maximum"),
		"Границы смешивания изменяются только в переходных областях")
	_check(code.contains("triplanar_normal") and
		code.contains("triplanar_roughness") and
		code.contains("normal_x") and code.contains("normal_z"),
		"Трипланарная проекция переносит и микрорельеф, и шероховатость")
	_check(code.contains("if (detail_strength >") and
		code.contains("if (material == 3"),
		"Дальние масштабы экономят вычисления, сложные проекции только у скал")
	_check(not code.contains("VERTEX ="),
		"Шейдер не деформирует физические вершины")


func _check_adaptive_detail() -> void:
	var scene := View.new()
	scene._setup_materials()
	var camera := Camera3D.new()
	scene.add_child(camera)
	scene._camera = camera

	var previous := 2.0
	for size in [16.0, 32.0, 66.0, 90.0, 105.0]:
		camera.size = size
		scene._update_material_detail()
		var macro: float = scene._ground_material.get_shader_parameter(
			"macro_strength")
		var detail: float = scene._ground_material.get_shader_parameter(
			"detail_strength")
		_check(macro >= 0.0 and macro <= 1.0 and macro <= previous,
			"Макродетализация постепенно отключается при отдалении")
		_check(is_equal_approx(macro, detail),
			"Цена шумового смешивания согласована с качеством рендера")
		previous = macro
	_check(is_equal_approx(previous, 0.0),
		"На максимальном отдалении нет дорогостоящего макрошумa")
	scene.free()


func _check_chunk_seams() -> void:
	var world := WorldMap.new(Config.new(64, 48, 1729, 16, 32))
	var hydro := Hydro.new(world)
	hydro.rebuild()
	var surface := Surface.new(world, hydro)
	surface.rebuild()
	hydro.apply_rainfall_map(surface.runoff_map())

	var before_world: Dictionary = world.to_data()
	var before_surface: Dictionary = surface.to_snapshot()
	var before_water: Dictionary = hydro.to_snapshot()

	var left := Chunk.create_mesh(1, 1, 1, world, surface, 0, null, hydro)
	var right := Chunk.create_mesh(2, 1, 1, world, surface, 0, null, hydro)
	var a: Array = left.surface_get_arrays(0)
	var b: Array = right.surface_get_arrays(0)

	var shared := 0
	for index in range(17):
		var left_index := index * 17 + 16
		var right_index := index * 17
		_check(a[Mesh.ARRAY_VERTEX][left_index] ==
			b[Mesh.ARRAY_VERTEX][right_index],
			"Общие вершины рельефа остались одинаковыми")
		_check(a[Mesh.ARRAY_COLOR][left_index].is_equal_approx(
			b[Mesh.ARRAY_COLOR][right_index]) and
			a[Mesh.ARRAY_TEX_UV][left_index].is_equal_approx(
			b[Mesh.ARRAY_TEX_UV][right_index]) and
			a[Mesh.ARRAY_TEX_UV2][left_index].is_equal_approx(
			b[Mesh.ARRAY_TEX_UV2][right_index]),
			"Все шесть масок на общей вершине совпадают")
		shared += 1

	_check(before_world == world.to_data() and
		before_surface == surface.to_snapshot() and
		before_water == hydro.to_snapshot(),
		"Текстурное разнообразие не меняет физический мир")
	print("Этап 9.2: сопоставлено ", shared,
		" общих вершин, высоты и физические снимки неизменны")


func _initialize() -> void:
	_check_shader()
	_check_adaptive_detail()
	_check_chunk_seams()
	if not failures.is_empty():
		for reason in failures.slice(0, 20):
			push_error("Этап 9.2: " + reason)
		quit(1)
		return
	print("Этап 9.2: макрофактура, переходы, трипланарные скалы — успешно.")
	quit(0)
