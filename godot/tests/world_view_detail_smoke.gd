extends SceneTree
## Этап 8.3: масштаб камеры влияет только на видимые чанки и GPU-детали.
## Все высоты и природные снимки остаются неизменными.

const Config = preload("res://scripts/world_config.gd")
const WorldMap = preload("res://scripts/world_map.gd")
const View = preload("res://scripts/world.gd")
const GroundShader = preload("res://shaders/natural_ground.gdshader")
const WaterShader = preload("res://shaders/natural_water.gdshader")

var failures: Array[String] = []


func _check(valid: bool, description: String) -> void:
	if not valid:
		failures.append(description)


func _check_thresholds() -> void:
	var near: float = View._detail_for_zoom(16.0)
	var medium: float = View._detail_for_zoom(66.0)
	var far: float = View._detail_for_zoom(105.0)
	_check(is_equal_approx(near, 1.0) and is_equal_approx(far, 0.0),
		"Ближняя детализация максимальна, дальняя отключена")
	_check(medium > far and medium < near,
		"Переход детализации непрерывен между масштабами")
	var close_radius: int = View._radius_for_zoom(16.0, 16.0 / 9.0, 16)
	var distant_radius: int = View._radius_for_zoom(105.0, 16.0 / 9.0, 16)
	_check(close_radius < distant_radius and close_radius >= 2,
		"Количество видимых чанков растёт при отдалении камеры")
	_check(View._radius_for_zoom(66.0, 2.4, 16) >
		View._radius_for_zoom(66.0, 1.0, 16),
		"Широкий экран загружает больше областей по диагонали")
	_check(View._radius_for_zoom(66.0, 16.0 / 9.0, 32) <
		View._radius_for_zoom(66.0, 16.0 / 9.0, 8),
		"Расчёт радиуса зависит от реального размера чанка")


func _check_scene() -> void:
	var map := WorldMap.new(Config.new(256, 192, 1729, 16, 64))
	var map_before: Dictionary = map.to_data()
	var heights := PackedFloat32Array()
	for point in [Vector2i(0, 0), Vector2i(84, 43),
			Vector2i(128, 96), Vector2i(256, 192)]:
		heights.append(map.vertex_at(point))

	var view := View.new()
	view._world_model = map
	view._center = Vector2(128.0, 96.0)
	view._camera = Camera3D.new()
	view.add_child(view._camera)
	view._setup_materials()
	var ground_before: ShaderMaterial = view._ground_material
	var water_before: ShaderMaterial = view._water_material

	view._camera.size = 16.0
	view._change_zoom(1.0)
	var near_count: int = view._pending.size()
	_check(near_count > 0, "Ближняя карта формирует GPU-очередь")
	_check(is_equal_approx(float(view._ground_material.get_shader_parameter(
		"detail_strength")), 1.0),
		"На ближнем масштабе включена фактура грунта")
	_check(is_equal_approx(float(view._water_material.get_shader_parameter(
		"ripple_strength")), 1.0),
		"На ближнем масштабе включена рябь воды")

	view._change_zoom(100.0)
	var far_count: int = view._pending.size()
	_check(far_count > near_count and far_count <=
		map.config.chunk_count().x * map.config.chunk_count().y,
		"Дальняя камера покрывает больше карты без выхода за её границы")
	_check(is_equal_approx(float(view._ground_material.get_shader_parameter(
		"detail_strength")), 0.0),
		"Дорогая фактура грунта отключается вдали")
	_check(is_equal_approx(float(view._water_material.get_shader_parameter(
		"ripple_strength")), 0.0),
		"Мелкая рябь воды отключается вдали")

	var seen := {}
	for coord in view._pending:
		_check(not seen.has(coord), "В GPU-очереди нет повторов координат")
		seen[coord] = true
		_check(map.config.chunk_rect(coord).has_area(),
			"Отдаление не запрашивает чанки за границами мира")

	view._change_zoom(0.01)
	_check(view._pending.size() == near_count,
		"После приближения лишние далёкие чанки исключены из очереди")
	_check(view._ground_material == ground_before and
		view._water_material == water_before,
		"При изменении масштаба материалы переиспользуются")

	_check(map.to_data() == map_before,
		"Управление камерой не затрагивает сериализацию и высоты")
	var corners := [
		Vector2i(0, 0), Vector2i(84, 43),
		Vector2i(128, 96), Vector2i(256, 192)
	]
	for i in range(corners.size()):
		_check(is_equal_approx(map.vertex_at(corners[i]), heights[i]),
			"Данные общей физической поверхности не меняются")
	_check(view._view_mode == 0,
		"Основной вид природного мира сохранён")
	print("Этап 8.3: чанков вблизи ", near_count,
		", вдали ", far_count,
		", размер карты ", map.config.width, "×", map.config.height)
	view.free()


func _check_shaders() -> void:
	_check(GroundShader is Shader and WaterShader is Shader,
		"Грунтовый и водный шейдеры загружаются")
	_check(GroundShader.code.contains("uniform float detail_strength") and
		GroundShader.code.contains("if (detail_strength >"),
		"Грунтовый шум пропускается при низкой детализации")
	_check(WaterShader.code.contains("uniform float ripple_strength") and
		WaterShader.code.contains("if (ripple_strength >"),
		"Рябь отключается без переключения материала")
	_check(not GroundShader.code.contains("VERTEX =") and
		not WaterShader.code.contains("VERTEX ="),
		"Шейдеры не меняют физические координаты вершин")


func _initialize() -> void:
	_check_thresholds()
	_check_scene()
	_check_shaders()
	if not failures.is_empty():
		for reason in failures.slice(0, 20):
			push_error("Этап 8.3: " + reason)
		quit(1)
		return
	print("Этап 8.3: масштаб, нагрузка GPU и сохранность карты — успешно.")
	quit(0)
