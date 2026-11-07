extends SceneTree
## R4a: скальный материал читается из физической поверхности.
## Контроль не подменяет художественную приёмку реального кадра.

const Config = preload("res://scripts/world_config.gd")
const Map = preload("res://scripts/world_map.gd")
const Hydro = preload("res://scripts/hydrology.gd")
const Surface = preload("res://scripts/surface.gd")
const Chunk = preload("res://scripts/chunk.gd")
const Mix = preload("res://scripts/terrain_material_mix.gd")
const View = preload("res://scripts/world.gd")
const GroundShader = preload("res://shaders/natural_ground.gdshader")

var failures: Array[String] = []


func _check(ok: bool, reason: String) -> void:
	# Продолжаем проверки даже после первой ошибки, чтобы
	# один прогон показал все нарушенные инварианты.
	if not ok:
		failures.append(reason)


func _check_shader_and_scene() -> void:
	# Шейдер использует реальные веса ROCK, нормали и высоты;
	# отдельной геометрии и выдуманного снега нет.
	var source: String = GroundShader.code
	_check(source.contains("uniform float rock_face_detail") and
		source.contains("rock / sum") and
		source.contains("ground_steepness") and
		source.contains("ground_position.y * 1.46") and
		source.contains("face_quality") and
		source.contains("face_joint"),
		"Слои и трещины привязаны к физическому камню и геометрии")
	_check(source.contains("if (rock_face > 0.035 && face_quality > 0.015)") and
		source.contains("fwidth(phase)") and
		not source.contains("VERTEX ="),
		"Мелкие детали отключаются по LOD без подмены высот")
	var scene := View.new()
	scene._setup_materials()
	var detail: Variant = scene._ground_material.get_shader_parameter(
		"rock_face_detail")
	_check(detail is float and is_equal_approx(detail, 1.0),
		"Новый каменный материал включён в игровом World")
	scene._ground_material.set_shader_parameter("rock_face_detail", 0.0)
	_check(is_equal_approx(scene._ground_material.get_shader_parameter(
		"rock_face_detail"), 0.0),
		"Для фиксированных кадров доступна исходная версия материала")
	scene.free()


func _check_physical_sources() -> void:
	# Подготавливаем физический мир с реальными склонами и
	# береговой водой. Снимки сохраняем до построения мешей.
	var world := Map.new(Config.new(96, 80, 1729, 16, 32))
	var hydro := Hydro.new(world)
	hydro.rebuild()
	var surface := Surface.new(world, hydro)
	surface.rebuild()
	hydro.apply_rainfall_map(surface.runoff_map())
	var before_world: Dictionary = world.to_data()
	var before_surface: Dictionary = surface.to_snapshot()
	var before_hydro: Dictionary = hydro.to_snapshot()

	# Сравниваем физический вес камня при разной крутизне
	# одного и того же участка. Шейдер только отображает вес.
	var cell := Vector2i(30, 28)
	var height: float = world.vertex_at(cell)
	var flat: PackedFloat32Array = Mix.at(cell, height, Vector3.UP,
		world, surface, hydro)
	var steep: PackedFloat32Array = Mix.at(cell, height,
		Vector3(0.93, 0.37, 0.0).normalized(), world, surface, hydro)
	_check(steep[Mix.ROCK] >= flat[Mix.ROCK],
		"Крутой физический склон не теряет покрытие ROCK")
	# Общая граница двух чанков остаётся неизменной, так как
	# художественная детализация работает только во фрагменте.
	var a: Array = Chunk.prepare_arrays(1, 1, 1, world, surface,
		0, null, hydro)
	var b: Array = Chunk.prepare_arrays(2, 1, 1, world, surface,
		0, null, hydro)
	var va: PackedVector3Array = a[Mesh.ARRAY_VERTEX]
	var vb: PackedVector3Array = b[Mesh.ARRAY_VERTEX]
	var weights_a: PackedVector2Array = a[Mesh.ARRAY_TEX_UV]
	var weights_b: PackedVector2Array = b[Mesh.ARRAY_TEX_UV]
	for y in range(17):
		var ia := y * 17 + 16
		var ib := y * 17
		_check(va[ia].is_equal_approx(vb[ib]) and
			weights_a[ia].is_equal_approx(weights_b[ib]),
			"Скалы не изменяют физический шов между чанками")
	_check(before_world == world.to_data() and
		before_surface == surface.to_snapshot() and
		before_hydro == hydro.to_snapshot(),
		"Материал не изменяет рельеф, почву и воду")


func _initialize() -> void:
	# Запускаем оба независимых набора тестов и возвращаем
	# ненулевой код CI при любом нарушении.
	_check_shader_and_scene()
	_check_physical_sources()
	if failures.is_empty():
		print("R4a: физические скалы, материал, LOD и швы — успешно")
		quit(0)
		return
	for reason in failures:
		push_error("R4a: " + reason)
	quit(1)
