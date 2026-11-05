extends SceneTree
## Этап 9.3: влажность, прибрежные покрытия и промерзание используют физику.

const Config = preload("res://scripts/world_config.gd")
const WorldMap = preload("res://scripts/world_map.gd")
const Hydrology = preload("res://scripts/hydrology.gd")
const Surface = preload("res://scripts/surface.gd")
const Chunk = preload("res://scripts/chunk.gd")
const MaterialMix = preload("res://scripts/terrain_material_mix.gd")
const WaterMesh = preload("res://scripts/water_mesh.gd")
const GroundShader = preload("res://shaders/natural_ground.gdshader")
const WaterShader = preload("res://shaders/natural_water.gdshader")

var failures: Array[String] = []


func _check(valid: bool, reason: String) -> void:
	if not valid:
		failures.append(reason)


func _models() -> Dictionary:
	var world := WorldMap.new(Config.new(64, 48, 1729, 16, 32))
	var hydro := Hydrology.new(world)
	hydro.rebuild()
	var surface := Surface.new(world, hydro)
	surface.rebuild()
	hydro.apply_rainfall_map(surface.runoff_map())
	return {"world": world, "hydro": hydro, "surface": surface}


func _check_texture_channels(state: Dictionary) -> void:
	var world: RefCounted = state["world"]
	var surface: RefCounted = state["surface"]
	var hydro: RefCounted = state["hydro"]
	var a := Chunk.create_mesh(1, 1, 1, world, surface, 0, null, hydro)
	var b := Chunk.create_mesh(2, 1, 1, world, surface, 0, null, hydro)
	var left: Array = a.surface_get_arrays(0)
	var right: Array = b.surface_get_arrays(0)
	var custom_a: PackedByteArray = left[Mesh.ARRAY_CUSTOM0]
	var custom_b: PackedByteArray = right[Mesh.ARRAY_CUSTOM0]
	_check(custom_a.size() >= 289 * 4 and custom_b.size() >= 289 * 4,
		"Четыре физических канала упакованы в четыре байта на вершину")
	var format: int = a.surface_get_format(0)
	_check((format & Mesh.ARRAY_FORMAT_CUSTOM0) != 0 and
		((format >> Mesh.ARRAY_FORMAT_CUSTOM0_SHIFT) &
		Mesh.ARRAY_FORMAT_CUSTOM_MASK) == Mesh.ARRAY_CUSTOM_RGBA8_UNORM,
		"GPU-канал CUSTOM0 читается как нормализованный RGBA8")
	for row in range(17):
		for channel in range(4):
			var ia := (row * 17 + 16) * 4 + channel
			var ib := row * 17 * 4 + channel
			_check(custom_a[ia] == custom_b[ib],
				"Физические каналы на общей границе двух чанков совпадают")
	var debug := Chunk.create_mesh(1, 1, 1, world, surface, 2, null, hydro)
	var neutral: PackedByteArray = debug.surface_get_arrays(0)[Mesh.ARRAY_CUSTOM0]
	_check(neutral.size() == 289 * 4 and neutral[0] == 0,
		"Диагностические режимы сохраняют нейтральный канал")


func _check_seasons_and_moisture(state: Dictionary) -> void:
	var world: RefCounted = state["world"]
	var surface: RefCounted = state["surface"]
	var hydro: RefCounted = state["hydro"]
	var point := Vector2i(-1, -1)
	for y in range(2, world.config.height - 2):
		for x in range(2, world.config.width - 2):
			var candidate := Vector2i(x, y)
			var safe := true
			for dy in [-1, 0]:
				for dx in [-1, 0]:
					safe = safe and not hydro.has_water(
						hydro.cell_index(candidate + Vector2i(dx, dy)))
			if safe:
				point = candidate
				break
		if point.x >= 0:
			break
	_check(point.x >= 0, "Найден участок сухой суши")
	if point.x < 0:
		return

	var original := {}
	var affected: Array[int] = []
	for dy in [-1, 0]:
		for dx in [-1, 0]:
			var index: int = hydro.cell_index(point + Vector2i(dx, dy))
			affected.append(index)
			original[index] = Vector4(surface._moisture[index],
				surface._frost[index], surface._snow[index],
				surface._waterlogged[index])
			surface._moisture[index] = 0.0
			surface._frost[index] = 0.0
			surface._snow[index] = 0.0
			surface._waterlogged[index] = 0.0

	var normal: Vector3 = world.normal_at(point)
	var height: float = world.vertex_at(point)
	var dry: Dictionary = MaterialMix.sample_at(
		point, height, normal, world, surface, hydro)
	for index in affected:
		surface._moisture[index] = 1.0
	var wet: Dictionary = MaterialMix.sample_at(
		point, height, normal, world, surface, hydro)
	_check(wet["conditions"].x > dry["conditions"].x + 0.4,
		"Мокрая почва темнеет из-за физической влаги, а не случайной карты")

	for index in affected:
		surface._frost[index] = 1.0
		surface._snow[index] = 1.0
	var winter: Dictionary = MaterialMix.sample_at(
		point, height, normal, world, surface, hydro)
	_check(winter["conditions"].z > wet["conditions"].z + 0.4,
		"Физический мороз передаётся в шейдер")
	_check(winter["weights"][MaterialMix.SNOW] >
		wet["weights"][MaterialMix.SNOW] + 0.4,
		"Снежная фактура подменяет грунт зимой")

	for index in affected:
		var saved: Vector4 = original[index]
		surface._moisture[index] = saved.x
		surface._frost[index] = saved.y
		surface._snow[index] = saved.z
		surface._waterlogged[index] = saved.w


func _check_ice_geometry(state: Dictionary) -> void:
	var world: RefCounted = state["world"]
	var hydro: RefCounted = state["hydro"]
	var surface: RefCounted = state["surface"]
	var found := Vector2i(-1, -1)
	for y in range(world.config.height):
		for x in range(world.config.width):
			var cell := Vector2i(x, y)
			var index: int = hydro.cell_index(cell)
			if hydro.ocean_at(index) or hydro.lake_at(index):
				found = cell
				break
		if found.x >= 0:
			break
	_check(found.x >= 0, "В тестовой карте есть водоём")
	if found.x < 0:
		return

	var index: int = hydro.cell_index(found)
	var before: float = surface._frost[index]
	surface._frost[index] = 1.0
	var coord := Vector2i(int(found.x / 16), int(found.y / 16))
	var mesh := WaterMesh.create_mesh(world, hydro, coord, surface)
	surface._frost[index] = before
	_check(mesh.get_surface_count() == 1, "Ледяная вода сохраняет меш")
	if mesh.get_surface_count() == 0:
		return
	var uv: PackedVector2Array = mesh.surface_get_arrays(0)[Mesh.ARRAY_TEX_UV]
	var icy := 0
	for pair in uv:
		_check(pair.x >= 0.0 and pair.x <= 1.0 and
			pair.y >= 0.0 and pair.y <= 1.0,
			"Глубина берега и степень льда остаются в диапазоне 0..1")
		if pair.y > 0.99:
			icy += 1
	_check(icy > 0, "Физический мороз достиг UV воды")


func _check_shaders() -> void:
	var land: String = GroundShader.code
	var water: String = WaterShader.code
	_check(land.contains("ground_conditions = CUSTOM0") and
		land.contains("wet_material") and land.contains("coastal_wet"),
		"Влажная почва и пляж читают физические RGBA8-параметры")
	_check(land.contains("snow_border") and land.contains("snow"),
		"Переход снега смягчается без независимой снежной карты")
	_check(water.contains("UV.x") and water.contains("UV.y") and
		water.contains("foam") and water.contains("liquid"),
		"Береговая пена и лёд зависят от глубины и промерзания")
	_check(water.contains("ripple_strength >") and
		water.contains("liquid >") and water.contains("wave_time"),
		"Сильный мороз или отдаление подавляют рябь")
	_check(not land.contains("VERTEX =") and not water.contains("VERTEX ="),
		"Художественные эффекты не меняют физическую геометрию")


func _initialize() -> void:
	var state := _models()
	var world: RefCounted = state["world"]
	var hydro: RefCounted = state["hydro"]
	var surface: RefCounted = state["surface"]
	var before_world: Dictionary = world.to_data()
	var before_water: Dictionary = hydro.to_snapshot()
	var before_surface: Dictionary = surface.to_snapshot()
	_check_texture_channels(state)
	_check_seasons_and_moisture(state)
	_check_ice_geometry(state)
	_check_shaders()
	_check(before_world == world.to_data() and
		before_water == hydro.to_snapshot() and
		before_surface == surface.to_snapshot(),
		"После проверок физические снимки остались неизменны")
	if not failures.is_empty():
		for reason in failures.slice(0, 20):
			push_error("Этап 9.3: " + reason)
		quit(1)
		return
	print("Этап 9.3: влажность, снег, пляжи, пена и лёд — успешно.")
	quit(0)
