extends SceneTree
## Проверяем береговую субклеточную геометрию и обоснованную влажность.

const Config = preload("res://scripts/world_config.gd")
const WorldMap = preload("res://scripts/world_map.gd")
const Hydro = preload("res://scripts/hydrology.gd")
const Surface = preload("res://scripts/surface.gd")
const Mix = preload("res://scripts/terrain_material_mix.gd")
const Appearance = preload("res://scripts/landscape_appearance.gd")
const Water = preload("res://scripts/water_mesh.gd")
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
	# На седловине билинейная поверхность давала ноль,
	# хотя фактические треугольники земли в центре имеют высоту 1.
	var diagonal: float = Water._terrain_height(-1.0, 1.0, 1.0,
		-1.0, 0.5, 0.5)
	_check(is_equal_approx(diagonal, 1.0),
		"Седловина у воды повторяет фактическую диагональ меша")
	var first: float = Water._terrain_height(0.0, 1.0, 2.0,
		6.0, 0.2, 0.3)
	var second: float = Water._terrain_height(0.0, 1.0, 2.0,
		6.0, 0.8, 0.7)
	_check(is_equal_approx(first, 0.8) and
		is_equal_approx(second, 3.7),
		"Интерполяция использует обе треугольные плоскости")
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
	_test_wetness()
	_test_waves()
	if not errors.is_empty():
		for reason in errors:
			push_error("Берег и влажность: " + reason)
		quit(1)
		return
	print("Берег и влажность: непрерывные кромки и физическая сырость — успешно.")
	quit(0)
