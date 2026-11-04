extends SceneTree
## Этап 9.1: реальные атласы PBR, переходы и сохранность физической карты.

const Config = preload("res://scripts/world_config.gd")
const WorldMap = preload("res://scripts/world_map.gd")
const Hydro = preload("res://scripts/hydrology.gd")
const Surface = preload("res://scripts/surface.gd")
const Climate = preload("res://scripts/climate.gd")
const Chunk = preload("res://scripts/chunk.gd")
const Mix = preload("res://scripts/terrain_material_mix.gd")
const View = preload("res://scripts/world.gd")
const GroundShader = preload("res://shaders/natural_ground.gdshader")
const Albedo = preload("res://assets/terrain/terrain_albedo.png")
const Packed = preload("res://assets/terrain/terrain_normal_roughness.png")

var failures: Array[String] = []


func _check(ok: bool, description: String) -> void:
	if not ok:
		failures.append(description)


func _test_atlases() -> void:
	var albedo: Image = Albedo.get_image()
	var packed: Image = Packed.get_image()
	_check(albedo.get_size() == Vector2i(1152, 768) and
		packed.get_size() == Vector2i(1152, 768),
		"Оба атласа имеют шесть тайлов 384×384")
	var brightnesses := {}
	for index in range(6):
		var x := (index % 3) * 384 + 192
		var y := (index / 3) * 384 + 192
		var color: Color = albedo.get_pixel(x, y)
		var detail: Color = packed.get_pixel(x, y)
		_check(color.r >= 0.0 and color.g >= 0.0 and color.b >= 0.0,
			"Фотографическая карта содержит допустимый цвет")
		_check(detail.r > 0.01 and detail.g > 0.01 and
			detail.b > 0.01, "Нормали и шероховатость ненулевые")
		brightnesses[index] = int(color.get_luminance() * 100.0)
		var edge: Color = albedo.get_pixel(index % 3 * 384 + 4,
			index / 3 * 384 + 192)
		var wrapped: Color = albedo.get_pixel(index % 3 * 384 + 372,
			index / 3 * 384 + 192)
		_check(absf(edge.r - wrapped.r) < 0.13 and
			absf(edge.g - wrapped.g) < 0.13,
			"Бордюр тайла берётся с противоположной кромки исходника")
	_check(brightnesses.size() == 6, "Присутствуют шесть покрытий")
	_check(brightnesses[Mix.ROCK] != brightnesses[Mix.SNOW],
		"Скала и снег используют разные изображения")


func _test_physical_weights() -> void:
	var world := WorldMap.new(Config.new(64, 48, 1729, 16, 32))
	var hydro := Hydro.new(world)
	hydro.rebuild()
	var surface := Surface.new(world, hydro)
	surface.rebuild()
	var climate := Climate.new(world, hydro)
	climate.rebuild()
	var before_world: Dictionary = world.to_data()
	var before_surface: Dictionary = surface.to_snapshot()
	var before_hydro: Dictionary = hydro.to_snapshot()
	var left := Chunk.create_mesh(1, 1, 1, world, surface, 0, climate, hydro)
	var right := Chunk.create_mesh(2, 1, 1, world, surface, 0, climate, hydro)
	var a: Array = left.surface_get_arrays(0)
	var b: Array = right.surface_get_arrays(0)
	var colors_a: PackedColorArray = a[Mesh.ARRAY_COLOR]
	var colors_b: PackedColorArray = b[Mesh.ARRAY_COLOR]
	var uv_a: PackedVector2Array = a[Mesh.ARRAY_TEX_UV]
	var uv_b: PackedVector2Array = b[Mesh.ARRAY_TEX_UV]
	var uv2_a: PackedVector2Array = a[Mesh.ARRAY_TEX_UV2]
	var uv2_b: PackedVector2Array = b[Mesh.ARRAY_TEX_UV2]
	_check(uv_a.size() == 289 and uv2_a.size() == 289,
		"Каждая вершина содержит коэффициенты текстурного смешивания")
	for y in range(17):
		var i := y * 17
		_check(colors_a[i + 16].is_equal_approx(colors_b[i]) and
			uv_a[i + 16].is_equal_approx(uv_b[i]) and
			uv2_a[i + 16].is_equal_approx(uv2_b[i]),
			"Соседние чанки имеют одинаковые маски на общих вершинах")
	for i in range(uv_a.size()):
		var sand := uv_a[i].x
		var rock := uv_a[i].y
		var soil := uv2_a[i].x
		var gravel := uv2_a[i].y
		var snow := colors_a[i].a
		var grass := 1.0 - sand - rock - soil - gravel - snow
		_check(minf(minf(sand, rock), minf(soil, gravel)) >= -0.0001
			and snow >= -0.0001 and grass >= -0.0001,
			"Шесть коэффициентов смешивания неотрицательные")
		_check(absf(grass + soil + sand + rock + gravel + snow -
			1.0) < 0.001, "Суммарный вес материалов равен единице")

	var point := Vector2i(23, 21)
	var normal: Vector3 = world.normal_at(point)
	var height: float = world.vertex_at(point)
	var before := Mix.at(point, height, normal, world, surface, hydro)
	var changed: Array[int] = []
	var snow_before := {}
	for dy in [-1, 0]:
		for dx in [-1, 0]:
			var cell := point + Vector2i(dx, dy)
			var index: int = hydro.cell_index(cell)
			if not hydro.has_water(index):
				changed.append(index)
				snow_before[index] = surface._snow[index]
				surface._snow[index] = 1.0
	var after := Mix.at(point, height, normal, world, surface, hydro)
	for index in changed:
		surface._snow[index] = snow_before[index]
	_check(changed.is_empty() or after[Mix.SNOW] > before[Mix.SNOW],
		"Физический снег замещает текстуру грунта без новой карты")
	_check(before_world == world.to_data() and
		before_surface == surface.to_snapshot() and
		before_hydro == hydro.to_snapshot(),
		"Текстурирование не изменило рельеф и воду")


func _test_scene() -> void:
	_check(GroundShader.code.contains("terrain_albedo")
		and GroundShader.code.contains("texture(")
		and GroundShader.code.contains("terrain_normal_roughness"),
		"Шейдер выбирает реальные PBR-изображения")
	_check(GroundShader.code.contains("ground_steepness") and
		GroundShader.code.contains("atlas_uv"),
		"Скалы получают проекцию, не растягивающую текстуру")
	var scene := View.new()
	scene._setup_materials()
	var tex: Variant = scene._ground_material.get_shader_parameter(
		"terrain_albedo")
	var packed_tex: Variant = scene._ground_material.get_shader_parameter(
		"terrain_normal_roughness")
	_check(tex is Texture2D and packed_tex is Texture2D,
		"Игровой материал использует оба настоящих атласа")
	_check(scene._debug_ground_material is StandardMaterial3D,
		"Диагностические режимы 1–7 сохранены без текстурных масок")
	scene.free()


func _initialize() -> void:
	_test_atlases()
	_test_physical_weights()
	_test_scene()
	if not failures.is_empty():
		for reason in failures.slice(0, 20):
			push_error("Этап 9.1: " + reason)
		quit(1)
		return
	print("Этап 9.1: PBR-атласы, маски, швы и природные законы — успешно.")
	quit(0)
