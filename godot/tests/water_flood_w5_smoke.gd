extends SceneTree
## Этап 11.6/W5: визуальный паводок следует реальной глубине и стоку.
## Рендер не создаёт новые разливы и не меняет исходную гидрологию.

const Config = preload("res://scripts/world_config.gd")
const Map = preload("res://scripts/world_map.gd")
const Hydro = preload("res://scripts/hydrology.gd")
const Water = preload("res://scripts/water_mesh.gd")
const WaterShader = preload("res://shaders/natural_water.gdshader")

class ControlledFlood:
	extends RefCounted
	## Изолируем монотонность интенсивности от конкретной формы карты.
	var depth := 0.2
	var pressure := 0.8
	var flooded := true

	func cell_index(cell: Vector2i) -> int:
		## Единственная затопленная клетка находится в начале координат.
		return 0 if cell == Vector2i.ZERO else -1

	func flooded_at(index: int) -> bool:
		## Отрицательный индекс никогда не представляет физическую воду.
		return index == 0 and flooded

	func flood_depth_at(index: int) -> float:
		## Не допускаем глубины вне существующей клетки.
		return depth if index == 0 and flooded else 0.0

	func flow_pressure_at(index: int) -> float:
		## Показатель стока берётся из уже рассчитанной физической модели.
		return pressure if index == 0 and flooded else 0.0


var failures: Array[String] = []


func _check(condition: bool, message: String) -> void:
	## Собираем все ошибки теста до завершения Godot CI.
	if not condition:
		failures.append(message)


func _test_energy() -> void:
	## При неизменной геометрии паводок становится заметнее лишь
	## с увеличением физической глубины или давления на водосборе.
	var flood := ControlledFlood.new()
	var point := Vector2(0.5, 0.5)
	var calm: float = Water._flood_motion_at(flood, point)
	flood.pressure = 2.2
	var stronger_flow: float = Water._flood_motion_at(flood, point)
	flood.depth = 0.9
	var deeper: float = Water._flood_motion_at(flood, point)
	_check(calm > 0.0 and stronger_flow > calm and deeper > stronger_flow,
		"Турбулентность монотонно растёт с реальным давлением и глубиной")
	_check(Water._flood_motion_at(flood, Vector2(8.5, 8.5)) == 0.0,
		"Сухая удалённая клетка не получает паводковую турбулентность")
	flood.flooded = false
	_check(Water._flood_motion_at(flood, point) == 0.0,
		"После отступления паводка сила волн становится нулевой")


func _test_real_flood() -> void:
	## Строим реальную дождевую котловину, без вручную нарисованной воды.
	var world := Map.new(Config.new(12, 12, 9123))
	var heights := {}
	for y in range(13):
		for x in range(13):
			heights[Vector2i(x, y)] = -1.0 if x >= 4 and x <= 8 \
				and y >= 4 and y <= 8 else 2.0
	_check(world.apply_vertex_changes(heights), "Создана физическая котловина")
	var hydro := Hydro.new(world)
	hydro.rebuild()
	_check(hydro.set_rainfall(2.2), "Дождь изменил реальный водосбор")
	_check(int(hydro.water_count()["flooded"]) > 0,
		"После ливня существует физически затопленная пойма")
	var flood_cell := Vector2i(-1, -1)
	for y in range(12):
		for x in range(12):
			var cell := Vector2i(x, y)
			if hydro.flooded_at(hydro.cell_index(cell)):
				flood_cell = cell
				break
		if flood_cell.x >= 0:
			break
	_check(flood_cell.x >= 0, "Найдена реально затопленная клетка")
	if flood_cell.x < 0:
		return

	var world_before: Dictionary = world.to_data()
	var hydro_before: Dictionary = hydro.to_snapshot()
	var point := Vector2(flood_cell) + Vector2(0.5, 0.5)
	_check(Water._flood_motion_at(hydro, point) > 0.0,
		"Визуальная энергия считывается из настоящего паводка")

	# Проверяем именно меш игрового паводка, а не отдельную картинку.
	var tool := SurfaceTool.new()
	tool.begin(Mesh.PRIMITIVE_TRIANGLES)
	var tris: int = Water._flood_cell(tool, world, hydro, flood_cell,
		Color(0.17, 0.34, 0.38), 0.0, {})
	_check(tris > 0, "Реальный паводок создаёт поверхность")
	if tris > 0:
		var arrays: Array = tool.commit_to_arrays()
		var markers: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV2]
		var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		_check(markers.size() == vertices.size(),
			"Метки паводка передаются всем видимым вершинам")
		var moving := 0
		for marker in markers:
			_check(is_equal_approx(marker.x, Water.FLOOD_MARKER_X) and
				marker.y >= 0.0 and marker.y <= 1.0,
				"Пойма отделена от рек и озёр без фиктивных скоростей")
			if marker.y > 0.001:
				moving += 1
		_check(moving > 0,
			"У затопленной поймы действительно есть подвижная поверхность")
	_check(world.to_data() == world_before and
		hydro.to_snapshot() == hydro_before,
		"Визуальная турбулентность не меняет высоты и гидрологию")

	# После уменьшения осадков исчезает именно физическое затопление,
	# и визуальный показатель повторяет это без собственного сохранения.
	_check(hydro.set_rainfall(0.0), "Дождь прекращён физической системой")
	_check(int(hydro.water_count()["flooded"]) == 0,
		"Реальная пойма полностью освободилась от паводка")
	_check(Water._flood_motion_at(hydro, point) == 0.0,
		"После паводка анимированное течение не осталось на суше")


func _test_shader() -> void:
	## Убедимся, что маркеры не воспринимаются как речное направление,
	## а волны и их фильтрация не меняют реальную геометрию воды.
	var code: String = WaterShader.code
	_check(code.contains("flood_marker") and
		code.contains("flood_intensity") and
		code.contains("flood_phase_a") and
		code.contains("fwidth(flood_phase_a)"),
		"Шейдер учитывает тип паводка и фильтрует частоты")
	_check(code.contains("(1.0 - flood_marker)") and
		code.contains("river_phase") and code.contains("wind_phase"),
		"Водный шейдер сохраняет W2/W3 и отделяет паводок от реки")
	_check(code.contains("* liquid") and code.contains("ripple_strength"),
		"Лёд и настройки графики ограничивают только анимацию")
	_check(not code.contains("VERTEX ="),
		"Турбулентность не изменяет физическую высоту воды")


func _initialize() -> void:
	## Реальные гидрологические данные проверяем отдельно от FPS устройств.
	_test_energy()
	_test_real_flood()
	_test_shader()
	if failures.is_empty():
		print("Этап 11.6/W5: физическая паводковая турбулентность — успешно")
		quit(0)
		return
	for reason in failures:
		printerr("Этап 11.6/W5: ", reason)
	quit(1)
