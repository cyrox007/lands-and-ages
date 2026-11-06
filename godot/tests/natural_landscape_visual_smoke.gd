extends SceneTree
## Этап 8.1: внешний вид использует прежние законы и общие вершины.

const Config = preload("res://scripts/world_config.gd")
const Map = preload("res://scripts/world_map.gd")
const Hydro = preload("res://scripts/hydrology.gd")
const Surface = preload("res://scripts/surface.gd")
const Climate = preload("res://scripts/climate.gd")
const Chunk = preload("res://scripts/chunk.gd")
const Appearance = preload("res://scripts/landscape_appearance.gd")
const Scene = preload("res://scripts/world.gd")
const GroundShader = preload("res://shaders/natural_ground.gdshader")
const WaterShader = preload("res://shaders/natural_water.gdshader")

var failures: Array[String] = []


func _check(ok: bool, reason: String) -> void:
	if not ok:
		failures.append(reason)


func _make_world() -> Dictionary:
	var world := Map.new(Config.new(64, 48, 1729, 16, 32))
	var hydro := Hydro.new(world)
	hydro.rebuild()
	var surface := Surface.new(world, hydro)
	surface.rebuild()
	var climate := Climate.new(world, hydro)
	climate.rebuild()
	climate.set_day(1)
	surface.advance_climate_day(climate)
	hydro.apply_rainfall_map(surface.runoff_map())
	return {
		"world": world, "hydro": hydro, "surface": surface,
		"climate": climate
	}


func _mesh(state: Dictionary, x: int, y: int, mode: int) -> ArrayMesh:
	return Chunk.create_mesh(x, y, 1, state["world"], state["surface"],
		mode, state["climate"], state["hydro"])


func _check_visual(state: Dictionary) -> void:
	var map: RefCounted = state["world"]
	var hydro: RefCounted = state["hydro"]
	var surface: RefCounted = state["surface"]
	var baseline: Dictionary = map.to_data()
	var soil_before: Dictionary = surface.to_snapshot()
	var rivers_before: Dictionary = hydro.to_snapshot()
	var start := Time.get_ticks_usec()
	var left := _mesh(state, 1, 1, 0)
	var right := _mesh(state, 2, 1, 0)
	var elapsed := Time.get_ticks_usec() - start
	_check(left.get_surface_count() == 1 and right.get_surface_count() == 1,
		"Природный режим строит оба GPU-чанка")
	if left.get_surface_count() < 1 or right.get_surface_count() < 1:
		return
	var a: Array = left.surface_get_arrays(0)
	var b: Array = right.surface_get_arrays(0)
	var colors_a: PackedColorArray = a[Mesh.ARRAY_COLOR]
	var colors_b: PackedColorArray = b[Mesh.ARRAY_COLOR]
	_check(colors_a.size() >= 289 and colors_b.size() >= 289,
		"Первая сетка 17×17 сохранена; только берег получает уточнение")
	for y in range(17):
		var i := y * 17
		_check(colors_a[i + 16].is_equal_approx(colors_b[i]),
			"Природный цвет общей вершины одинаков с обеих сторон чанка")
		_check(a[Mesh.ARRAY_VERTEX][i + 16] ==
			b[Mesh.ARRAY_VERTEX][i],
			"Положение общей вершины осталось неизменным")
	for color in colors_a:
		_check(is_finite(color.r) and is_finite(color.g)
			and is_finite(color.b) and color.r >= 0.0 and color.g >= 0.0
			and color.b >= 0.0 and color.r <= 1.0 and color.g <= 1.0
			and color.b <= 1.0,
			"В GPU нет бесконечных значений или выходов цвета за диапазон")
	var variety := {}
	for c in colors_a:
		var key := Vector3i(int(c.r * 40.0), int(c.g * 40.0),
			int(c.b * 40.0))
		variety[key] = true
	_check(variety.size() >= 3,
		"Физическая поверхность имеет реальные цветовые переходы")
	var climate_mesh := _mesh(state, 1, 1, 4)
	var climate_colors: PackedColorArray = climate_mesh.surface_get_arrays(0)[
		Mesh.ARRAY_COLOR]
	_check(colors_a != climate_colors,
		"Основной вид не подменяется диагностикой климата")
	_check(baseline == map.to_data() and soil_before == surface.to_snapshot()
		and rivers_before == hydro.to_snapshot(),
		"Построение материала не меняет физический мир")
	_check(elapsed < 5000000,
		"Построение двух GPU-чанков укладывается в защитный бюджет 5 секунд")
	print("Этап 8.1: два чанка построены за ", elapsed,
		" мкс, цветовых оттенков ", variety.size())


func _check_snow_and_shore(state: Dictionary) -> void:
	var world: RefCounted = state["world"]
	var surface: RefCounted = state["surface"]
	var hydro: RefCounted = state["hydro"]
	var center := Vector2i(23, 21)
	var normal: Vector3 = world.normal_at(center)
	var height: float = world.vertex_at(center)
	var before: Color = Appearance.color_at(center, height, normal,
		world, surface, hydro)
	var index: int = hydro.cell_index(center)
	var previous: float = surface._snow[index]
	surface._snow[index] = 1.0
	var snowy: Color = Appearance.color_at(center, height, normal,
		world, surface, hydro)
	surface._snow[index] = previous
	if not hydro.has_water(index):
		_check(snowy.r + snowy.g + snowy.b > before.r + before.g + before.b,
			"Настоящий снег осветляет природный материал")
	var adjacent := Vector2i(-1, -1)
	for y in range(1, world.config.height - 1):
		for x in range(1, world.config.width - 1):
			var cell := Vector2i(x, y)
			var nearby: Vector3 = Appearance.near_water(cell, world, hydro)
			if not hydro.has_water(hydro.cell_index(cell)) \
					and (nearby.x > 0.0 or nearby.y > 0.0):
				adjacent = cell
				break
		if adjacent.x >= 0:
			break
	_check(adjacent.x >= 0, "На карте найден береговой переход")
	if adjacent.x >= 0:
		var factors: Vector3 = Appearance.near_water(adjacent, world, hydro)
		_check(factors.x >= 0.0 and factors.y >= 0.0,
			"Береговая фактура зависит от физической воды")


func _check_shaders_and_scene() -> void:
	_check(GroundShader is Shader and WaterShader is Shader,
		"Природные шейдеры загружены из файлов проекта")
	_check(GroundShader.code.contains("MODEL_MATRIX")
		and GroundShader.code.contains("ALBEDO"),
		"Шейдер грунта использует мировые координаты без текстурных швов")
	_check(WaterShader.code.contains("ALPHA")
		and WaterShader.code.contains("wave_time"),
		"Водная рябь работает без изменения физической поверхности")
	var scene := Scene.new()
	_check(scene._view_mode == 0,
		"Игра открывает природный мир, а не диагностический слой")
	scene._setup_materials()
	_check(scene._ground_material is ShaderMaterial
		and scene._ground_material.shader == GroundShader,
		"Основной материал использует GPU-шейдер")
	_check(scene._debug_ground_material is StandardMaterial3D,
		"Семь прежних диагностических режимов сохранены")
	_check(scene._water_material.shader == WaterShader,
		"Реки и озёра получают единый художественный материал")
	scene.free()


func _initialize() -> void:
	var state := _make_world()
	_check_visual(state)
	_check_snow_and_shore(state)
	_check_shaders_and_scene()
	if not failures.is_empty():
		for reason in failures.slice(0, 20):
			push_error("Этап 8.1: " + reason)
		quit(1)
		return
	print("Этап 8.1: визуальная поверхность, GPU-шейдеры и границы — успешно.")
	quit(0)
