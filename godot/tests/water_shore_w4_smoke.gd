extends SceneTree
## Этап 11.6/W4: реальные берега получают непрерывную пену и блики.
## Визуальная анимация не имеет права изменять гидрологию и поверхность.

const Config = preload("res://scripts/world_config.gd")
const Map = preload("res://scripts/world_map.gd")
const Hydro = preload("res://scripts/hydrology.gd")
const Surface = preload("res://scripts/surface.gd")
const Water = preload("res://scripts/water_mesh.gd")
const WaterShader = preload("res://shaders/natural_water.gdshader")

var failures: Array[String] = []


func _check(condition: bool, reason: String) -> void:
	## Собираем все нарушения в одном результате CI.
	if not condition:
		failures.append(reason)


func _test_shore(world: RefCounted, water_kind: Vector2,
		label: String) -> void:
	## Создаём обрезанную береговую кромку со склоном по четырём высотам.
	## Реальная вода рисуется тем же методом без дополнительного меша пены.
	var tool := SurfaceTool.new()
	tool.begin(Mesh.PRIMITIVE_TRIANGLES)
	var triangles: int = Water._subdivided_shore(tool, world,
		Vector2i(5, 5), 0.0, Color(0.2, 0.4, 0.5, 0.9), 0.0,
		-1.0, 1.0, -0.4, 0.9, water_kind)
	_check(triangles > 2, label + ": берег разбит на физически обрезанные треугольники")
	if triangles <= 2:
		return
	var arrays: Array = tool.commit_to_arrays()
	var uv: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV]
	var kinds: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV2]
	var positions: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	_check(uv.size() == positions.size() and kinds.size() == positions.size(),
		label + ": одинаковое число вершин и водных атрибутов")
	var boundary := 0
	var shallow := 0
	for i in range(uv.size()):
		# Из UV.x шейдер получает только действительную геометрическую
		# глубину, а из UV2 — маркер воды, не физическую скорость.
		_check(kinds[i] == water_kind,
			label + ": метка стоячей воды не теряется на краю берега")
		_check(uv[i].x >= 0.0 and uv[i].x <= 1.0,
			label + ": глубина физической кромки нормализована")
		if uv[i].x <= 0.0001:
			boundary += 1
		elif uv[i].x < 0.35:
			shallow += 1
	_check(boundary > 0 and shallow > 0,
		label + ": есть и линия обрезки, и настоящая зона прибоя")


func _test_shader() -> void:
	## Шейдер использует мировые координаты и фильтрует частоты,
	## поэтому ему не нужны квадратные декали, разбитые по чанкам.
	var code: String = WaterShader.code
	_check(code.contains("fwidth(UV.x)") and
		code.contains("fwidth(crest_phase)") and
		code.contains("water_position"),
		"Пена фильтруется по масштабу и непрерывна в мировых координатах")
	_check(code.contains("foam_band") and
		code.contains("standing") and
		code.contains("shoreline_foam") and
		code.contains("shoreline_glint") and
		code.contains("shoreline_wash"),
		"Пена, блики и мелководная волна зависят от реального берега")
	_check(code.contains("wind_strength") and code.contains("storm_strength"),
		"Движение берегового фронта связано с климатическим ветром и штормом")
	_check(code.contains("river_phase") and code.contains("wind_phase"),
		"Пена не удаляет течения рек и предыдущие ветровые волны")
	_check(code.contains("shoreline_foam * 0.15") and
		code.contains("liquid") and code.contains("ice"),
		"Лёд сохраняет независимую шероховатость и гасит жидкую пену")
	_check(not code.contains("VERTEX ="),
		"Шейдер не меняет высоту и объём воды")


func _run() -> void:
	## Снимки физики сравниваем вокруг всех графических вызовов.
	var world := Map.new(Config.new(64, 48, 1729, 16, 32))
	var hydro := Hydro.new(world)
	hydro.rebuild()
	var surface := Surface.new(world, hydro)
	surface.rebuild()
	hydro.apply_rainfall_map(surface.runoff_map())
	var world_before: Dictionary = world.to_data()
	var hydro_before: Dictionary = hydro.to_snapshot()
	var surface_before: Dictionary = surface.to_snapshot()

	_test_shore(world, Water.STANDING_OCEAN, "Морской берег")
	_test_shore(world, Water.STANDING_LAKE, "Озёрный берег")
	_test_shader()
	_check(world.to_data() == world_before and
		hydro.to_snapshot() == hydro_before and
		surface.to_snapshot() == surface_before,
		"Пена и отражения не меняют рельеф, гидрологию и грунт")

	if failures.is_empty():
		print("Этап 11.6/W4: береговая пена и блики — успешно")
		quit(0)
		return
	for reason in failures:
		printerr("Этап 11.6/W4: ", reason)
	quit(1)


func _initialize() -> void:
	## Автономный тест: графические PNG и аппаратные FPS проверяются отдельно.
	_run()
