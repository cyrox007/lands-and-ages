extends SceneTree
## Проверяем береговую субклеточную геометрию и обоснованную влажность.

const Config = preload("res://scripts/world_config.gd")
const WorldMap = preload("res://scripts/world_map.gd")
const Hydro = preload("res://scripts/hydrology.gd")
const Surface = preload("res://scripts/surface.gd")
const Mix = preload("res://scripts/terrain_material_mix.gd")
const Appearance = preload("res://scripts/landscape_appearance.gd")
const Water = preload("res://scripts/water_mesh.gd")
const ShoreVisual = preload("res://scripts/shore_visual.gd")
const Chunk = preload("res://scripts/chunk.gd")
const WaveShader = preload("res://shaders/natural_water.gdshader")

var errors: Array[String] = []


func _check(value: bool, reason: String) -> void:
	if not value:
		errors.append(reason)


func _test_coast() -> void:
	_check(Water.SHORE_SUBDIVISIONS >= 2,
		"Берег делится на несколько субклеточных треугольников")
	var a := Water._terrain_height(-1.0, 1.0, 0.0, 2.0, 0.5, 0.0)
	var b := Water._terrain_height(-1.0, 1.0, 0.0, 2.0, 0.5, 1.0)
	_check(is_equal_approx(a, 0.0) and is_equal_approx(b, 1.0),
		"Интерполяция согласована с высотами физической сетки")
	# На седловине визуальная поверхность теперь плавная: ноль в центре.
	# Вода и грунт используют одну и ту же билинейную сетку.
	var diagonal: float = Water._terrain_height(-1.0, 1.0, 1.0,
		-1.0, 0.5, 0.5)
	_check(is_equal_approx(diagonal, 0.0),
		"Визуальная седловина сглажена независимо от физической диагонали")
	var first: float = Water._terrain_height(0.0, 1.0, 2.0,
		6.0, 0.2, 0.3)
	var second: float = Water._terrain_height(0.0, 1.0, 2.0,
		6.0, 0.8, 0.7)
	_check(is_equal_approx(first, 0.98) and
		is_equal_approx(second, 3.88),
		"Береговая интерполяция непрерывна внутри физических клеток")
	# Общая сторона соседних ячеек не может разойтись.
	for j in range(4):
		var v := float(j) / 3.0
		var left := Water._terrain_height(-2, 1, 2, 3, 1.0, v)
		var right := Water._terrain_height(1, 4, 3, 5, 0.0, v)
		_check(is_equal_approx(left, right),
			"Соседние прибрежные клетки имеют непрерывную общую высоту")
	var world := WorldMap.new(Config.new(32, 32, 1729, 16, 16))
	var tool := SurfaceTool.new()
	tool.begin(Mesh.PRIMITIVE_TRIANGLES)
	var triangles := Water._subdivided_shore(tool, world,
		Vector2i(5, 5), 0.0, Color.BLUE, 0.0,
		-1.0, 1.0, -0.4, 0.9)
	_check(triangles > 2,
		"Прибрежная граница использует несколько полигонов")



func _test_shared_coastal_mesh() -> void:
	var world := WorldMap.new(Config.new(64, 48, 1729, 16, 32))
	var hydro := Hydro.new(world)
	hydro.rebuild()
	var surface := Surface.new(world, hydro)
	surface.rebuild()
	hydro.apply_rainfall_map(surface.runoff_map())
	var before := world.to_data()
	var water_before := hydro.to_snapshot()
	var total_shores := 0
	var subdivisions: int = ShoreVisual.SUBDIVISIONS
	# Проверяем полное покрытие: уточняются только береговые клетки,
	# массивы атрибутов остаются одинакового размера.
	for cy in range(world.config.chunk_count().y):
		for cx in range(world.config.chunk_count().x):
			var bounds: Rect2i = world.config.chunk_rect(Vector2i(cx, cy))
			var shores := 0
			for y in range(bounds.position.y, bounds.end.y):
				for x in range(bounds.position.x, bounds.end.x):
					if ShoreVisual.is_coastal_cell(world, hydro, Vector2i(x, y)):
						shores += 1
			total_shores += shores
			var prepared := Chunk.prepare_arrays(cx, cy, 1, world, null, 0, null, hydro)
			var points: PackedVector3Array = prepared[Mesh.ARRAY_VERTEX]
			var triangles: PackedInt32Array = prepared[Mesh.ARRAY_INDEX]
			var base := (bounds.size.x + 1) * (bounds.size.y + 1)
			_check(points.size() == base + shores * (subdivisions + 1) * (subdivisions + 1),
				"Уточнённые вершины есть только у пересечения суши с водой")
			_check(triangles.size() == bounds.size.x * bounds.size.y * 6 +
				shores * (subdivisions * subdivisions * 6 - 6),
				"Береговая сетка точно заменяет крупные треугольники")
			_check(prepared[Mesh.ARRAY_NORMAL].size() == points.size() and
				prepared[Mesh.ARRAY_COLOR].size() == points.size() and
				prepared[Mesh.ARRAY_TEX_UV].size() == points.size() and
				prepared[Mesh.ARRAY_TEX_UV2].size() == points.size() and
				prepared[Mesh.ARRAY_CUSTOM0].size() == points.size() * 4,
				"Нормали, PBR-веса и условия не отстают от геометрии")
			for index in triangles:
				_check(index >= 0 and index < points.size(),
					"Индекс новой триангуляции попадает в массив вершин")
	_check(total_shores > 0, "В контрольном мире есть пересекаемый морской берег")
	_check(world.to_data() == before and hydro.to_snapshot() == water_before,
		"Уточнение берега не изменяет ни физические высоты, ни воду")
	# Общие рёбра и пересечения с уровнем воды должны оставаться
	# непрерывны даже когда по разные стороны ребра разные чанки.
	for step in range(subdivisions + 1):
		var fraction := float(step) / float(subdivisions)
		var left: float = ShoreVisual.height(-2.0, 1.0, 2.0, 3.0, 1.0, fraction)
		var right: float = ShoreVisual.height(1.0, 4.0, 3.0, 5.0, 0.0, fraction)
		_check(is_equal_approx(left, right),
			"Общее ребро соседних береговых мешей совпадает")
	var level := 0.0
	var h00 := -1.0
	var h10 := 1.0
	var h01 := 1.0
	var h11 := -1.0
	for j in range(subdivisions):
		for i in range(subdivisions):
			var u0 := float(i) / float(subdivisions)
			var v0 := float(j) / float(subdivisions)
			var u1 := float(i + 1) / float(subdivisions)
			var v1 := float(j + 1) / float(subdivisions)
			var h0: float = ShoreVisual.height(h00, h10, h01, h11, u0, v0)
			var h1: float = ShoreVisual.height(h00, h10, h01, h11, u0, v1)
			var h2: float = ShoreVisual.height(h00, h10, h01, h11, u1, v0)
			var tri := PackedVector2Array([Vector2(u0, v0),
				Vector2(u0, v1), Vector2(u1, v0)])
			var clipped := Water._clip_submerged_triangle(tri,
				PackedFloat32Array([h0, h1, h2]), level)
			for point in clipped:
				# Все точки воды являются точно теми же пересечениями,
				# что и пересечения уточнённых треугольников суши.
				if point.z > 0.000001:
					continue
				var edge_hit := false
				for k in range(3):
					var k2 := (k + 1) % 3
					var edge := tri[k2] - tri[k]
					var rel := Vector2(point.x, point.y) - tri[k]
					if absf(edge.cross(rel)) > 0.00001:
						continue
					var length_sq := edge.length_squared()
					var t := clampf(edge.dot(rel) / length_sq, 0.0, 1.0)
					var ground := lerpf([h0, h1, h2][k], [h0, h1, h2][k2], t)
					if absf(ground - level) <= 0.00001:
						edge_hit = true
				_check(edge_hit, "Кромка воды совпадает с уточнённым рельефом")


func _test_wetness() -> void:
	var world := WorldMap.new(Config.new(64, 48, 1729, 16, 32))
	var hydro := Hydro.new(world)
	hydro.rebuild()
	var surface := Surface.new(world, hydro)
	surface.rebuild()
	hydro.apply_rainfall_map(surface.runoff_map())
	var before := world.to_data()
	var water_before := hydro.to_snapshot()
	var surface_before := surface.to_snapshot()
	var found := false
	for y in range(2, world.config.height - 2):
		if found:
			break
		for x in range(2, world.config.width - 2):
			var point := Vector2i(x, y)
			if Appearance._near_water(point, world, hydro).x <= 0.0:
				continue
			var normal := Vector3.UP
			var level := -INF
			for dy in range(-1, 2):
				for dx in range(-1, 2):
					var index := hydro.cell_index(point + Vector2i(dx, dy))
					if hydro.has_water(index):
						level = maxf(level, hydro.level_at(index))
			if not is_finite(level):
				continue
			var near: Dictionary = Mix.sample_at(point, level + 0.03,
				normal, world, surface, hydro)
			var high: Dictionary = Mix.sample_at(point, level + 3.0,
				normal, world, surface, hydro)
			if near["conditions"].y <= 0.01:
				continue
			_check(high["conditions"].y <= 0.001,
				"Высокий берег не получает морской мокрый ореол")
			_check(near["conditions"].y > high["conditions"].y,
				"Мокрая береговая полоса учитывает уровень воды")
			found = true
			break
	_check(found, "На карте есть прибрежная физическая клетка")
	_check(world.to_data() == before and
		hydro.to_snapshot() == water_before and
		surface.to_snapshot() == surface_before,
		"Улучшение материалов не меняет физику")


func _test_waves() -> void:
	var code: String = WaveShader.code
	_check(code.contains("fwidth(phase_a)") and
		code.contains("wave_fade") and code.contains("TIME"),
		"Волны анимируются и ослабляются при экранном алиасинге")
	_check(not code.contains("VERTEX ="),
		"Шейдер воды не изменяет физическую поверхность")


func _initialize() -> void:
	_test_coast()
	_test_shared_coastal_mesh()
	_test_wetness()
	_test_waves()
	if not errors.is_empty():
		for reason in errors:
			push_error("Берег и влажность: " + reason)
		quit(1)
		return
	print("Берег и влажность: непрерывные кромки и физическая сырость — успешно.")
	quit(0)
