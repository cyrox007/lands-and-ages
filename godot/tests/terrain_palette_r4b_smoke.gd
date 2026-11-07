extends SceneTree
## R4b — регрессия окраски физической карты шестью PBR-материалами.
## Проверяет подключение палитры, непрерывность чанков и сохранность природы.

const Config = preload("res://scripts/world_config.gd")
const WorldMap = preload("res://scripts/world_map.gd")
const Hydrology = preload("res://scripts/hydrology.gd")
const Surface = preload("res://scripts/surface.gd")
const Chunk = preload("res://scripts/chunk.gd")
const Mix = preload("res://scripts/terrain_material_mix.gd")
const View = preload("res://scripts/world.gd")
const GroundShader = preload("res://shaders/natural_ground.gdshader")

var failures: Array[String] = []


func _check(valid: bool, explanation: String) -> void:
	# Собираем полный список отклонений в одном запуске, а не
	# прекращаем проверку после первой ошибки материала.
	if not valid:
		failures.append(explanation)


func _test_palette_connection() -> void:
	# Палитра обязана работать с уже имеющимися слоями PBR.
	# Снег остаётся своим материалом, а высоты берём из WorldMap.
	var code: String = GroundShader.code
	_check(code.contains("uniform float terrain_palette_strength") and
		code.contains("vec3 material_palette(int material)") and
		code.contains("material_palette(material)"),
		"Палитра подключена к настоящим PBR-покрытиям")
	_check(code.contains("float exposed_rock = rock / sum") and
		code.contains("float scree = gravel / sum") and
		code.contains("float earthy = (grass + soil) / sum") and
		code.contains("rock_scree_border"),
		"Скала, осыпь и земля окрашиваются по реальным весам")
	_check(code.contains("return vec3(1.0); // Реальный снег") and
		code.contains("float wet =") and
		not code.contains("VERTEX ="),
		"Снег и влажность сохранены, геометрия не подменяется")
	var view := View.new()
	view._setup_materials()
	var parameter: Variant = view._ground_material.get_shader_parameter(
		"terrain_palette_strength")
	_check(parameter is float and is_equal_approx(parameter, 1.0),
		"Палитра включена в настоящем игровом World")
	view._ground_material.set_shader_parameter("terrain_palette_strength", 0.0)
	_check(is_equal_approx(view._ground_material.get_shader_parameter(
		"terrain_palette_strength"), 0.0),
		"Палитру можно выключить для парного сравнения R4a")
	view.free()


func _test_physics_and_seams() -> void:
	# Воспроизводим физические грунты и сток, запоминаем их
	# снимки, затем строим две соседние игровые поверхности.
	var world := WorldMap.new(Config.new(64, 48, 1729, 16, 32))
	var hydro := Hydrology.new(world)
	hydro.rebuild()
	var surface := Surface.new(world, hydro)
	surface.rebuild()
	hydro.apply_rainfall_map(surface.runoff_map())
	var before_world: Dictionary = world.to_data()
	var before_surface: Dictionary = surface.to_snapshot()
	var before_water: Dictionary = hydro.to_snapshot()
	var left: Array = Chunk.prepare_arrays(1, 1, 1,
		world, surface, 0, null, hydro)
	var right: Array = Chunk.prepare_arrays(2, 1, 1,
		world, surface, 0, null, hydro)
	var vertices_left: PackedVector3Array = left[Mesh.ARRAY_VERTEX]
	var vertices_right: PackedVector3Array = right[Mesh.ARRAY_VERTEX]
	var uv_left: PackedVector2Array = left[Mesh.ARRAY_TEX_UV]
	var uv_right: PackedVector2Array = right[Mesh.ARRAY_TEX_UV]
	var uv2_left: PackedVector2Array = left[Mesh.ARRAY_TEX_UV2]
	var uv2_right: PackedVector2Array = right[Mesh.ARRAY_TEX_UV2]
	var color_left: PackedColorArray = left[Mesh.ARRAY_COLOR]
	var color_right: PackedColorArray = right[Mesh.ARRAY_COLOR]
	for y in range(17):
		# Каждый физический край читается из одного источника:
		# цветовая доработка шейдера не имеет права менять UV.
		var ia := y * 17 + 16
		var ib := y * 17
		_check(vertices_left[ia].is_equal_approx(vertices_right[ib]) and
			uv_left[ia].is_equal_approx(uv_right[ib]) and
			uv2_left[ia].is_equal_approx(uv2_right[ib]) and
			color_left[ia].is_equal_approx(color_right[ib]),
			"Соседние чанки не расходятся по физическим маскам и высотам")

	# Для проверки естественного смешивания сравниваем долю
	# настоящего камня на ровной и крутой физической нормали.
	var cell := Vector2i(27, 18)
	var height: float = world.vertex_at(cell)
	var flat: PackedFloat32Array = Mix.at(cell, height, Vector3.UP,
		world, surface, hydro)
	var slope: PackedFloat32Array = Mix.at(cell, height,
		Vector3(0.9, 0.44, 0.0).normalized(), world, surface, hydro)
	_check(slope[Mix.ROCK] >= flat[Mix.ROCK],
		"Откос физически содержит не меньше скалы, чем ровная почва")
	var total := 0.0
	for weight in flat:
		total += weight
	_check(is_equal_approx(total, 1.0),
		"Сумма шести исходных PBR-весов равна единице")
	_check(before_world == world.to_data() and
		before_surface == surface.to_snapshot() and
		before_water == hydro.to_snapshot(),
		"Окраска не изменила карту, воду и природную поверхность")


func _initialize() -> void:
	# Передаём ненулевой код CI при ошибках, выводим сообщения
	# на русском языке вместе с конкретным инвариантом.
	_test_palette_connection()
	_test_physics_and_seams()
	if failures.is_empty():
		print("R4b: палитра, физическая поверхность и швы — успешно")
		quit(0)
		return
	for problem in failures:
		push_error("R4b: " + problem)
	quit(1)
