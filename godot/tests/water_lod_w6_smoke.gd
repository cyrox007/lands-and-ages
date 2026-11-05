extends SceneTree
## Этап 11.6/W6: дальний LOD и игровые часы водной анимации.
## Смена масштаба и скорости изображения не меняет физическое состояние.

const Config = preload("res://scripts/world_config.gd")
const Map = preload("res://scripts/world_map.gd")
const Hydro = preload("res://scripts/hydrology.gd")
const Surface = preload("res://scripts/surface.gd")
const View = preload("res://scripts/world.gd")
const WaterShader = preload("res://shaders/natural_water.gdshader")

var failures: Array[String] = []


func _check(valid: bool, reason: String) -> void:
	## Собираем ошибки и выдаём их единым результатом CI.
	if not valid:
		failures.append(reason)


func _test_zoom(view: Node3D, camera: Camera3D) -> void:
	## Используем штатный метод изменения детализации сцены.
	## Не перестраиваем меши при визуальной смене масштаба.
	var previous := -1.0
	for size in [24.0, 44.0, 58.0, 76.0, 96.0, 160.0]:
		camera.size = size
		view._update_material_detail()
		var near: float = view._water_material.get_shader_parameter(
			"ripple_strength")
		var far: float = view._water_material.get_shader_parameter(
			"far_glint_strength")
		_check(near >= 0.0 and near <= 1.0 and
			far >= 0.0 and far <= 1.0,
			"Коэффициенты близкого и дальнего LOD ограничены")
		_check(is_equal_approx(near + far, 1.0),
			"Крупные блики плавно заменяют мелкую рябь")
		_check(far >= previous,
			"При удалении камеры доля дальнего освещения не уменьшается")
		previous = far
	_check(previous > 0.99,
		"На обзорном масштабе вода остаётся с крупными бликами")


func _test_time(view: Node3D) -> void:
	## Проверяем именно передаваемый шейдеру параметр времени.
	## delta уже учитывает настройку Engine.time_scale игрового дерева.
	view._advance_water_animation(0.25)
	var first: float = view._water_material.get_shader_parameter("wave_time")
	view._advance_water_animation(0.50)
	var second: float = view._water_material.get_shader_parameter("wave_time")
	_check(is_equal_approx(first, 0.25) and
		is_equal_approx(second, 0.75),
		"Кадровые часы продвигаются на переданное время")
	view._advance_water_animation(0.0)
	view._advance_water_animation(-5.0)
	view._advance_water_animation(NAN)
	_check(is_equal_approx(view._water_animation_time, second),
		"Остановка и некорректное delta не сдвигают анимацию")
	_check(view.process_mode == Node.PROCESS_MODE_INHERIT,
		"При паузе дерева сцены обычный _process не продолжает время")


func _test_shader() -> void:
	## Мировые фазы общие для соседних чанков и не сбрасываются при LOD.
	## Антиалиасинг ограничивает дорогую мелкую анимацию вдали.
	var code: String = WaterShader.code
	_check(code.contains("uniform float wave_time") and
		not code.contains("TIME"),
		"Все волны используют управляемые часы вместо глобального TIME")
	_check(code.contains("far_glint_strength") and
		code.contains("far_phase") and code.contains("fwidth(far_phase)"),
		"Дальние блики фильтруются по экранной частоте")
	_check(code.contains("water_position") and code.contains("wave_fade") and
		code.contains("river_phase") and code.contains("flood_phase_a"),
		"LOD сохраняет непрерывность русел, волн и паводков")
	_check(code.contains("far_glint") and code.contains("* liquid"),
		"Лёд гасит дальние жидкие блики")
	_check(not code.contains("VERTEX ="),
		"Дальний водный эффект не смещает физическую поверхность")


func _run() -> void:
	## Сравниваем снимки реального мира до и после всех GPU-параметров.
	var world := Map.new(Config.new(64, 48, 1729, 16, 32))
	var hydro := Hydro.new(world)
	hydro.rebuild()
	var surface := Surface.new(world, hydro)
	surface.rebuild()
	hydro.apply_rainfall_map(surface.runoff_map())
	var before_world: Dictionary = world.to_data()
	var before_water: Dictionary = hydro.to_snapshot()
	var before_surface: Dictionary = surface.to_snapshot()

	var view := View.new()
	var camera := Camera3D.new()
	view.add_child(camera)
	view._world_model = world
	view._camera = camera
	view._center = Vector2(24.0, 24.0)
	view._water_material = ShaderMaterial.new()
	view._water_material.shader = WaterShader

	_test_zoom(view, camera)
	_test_time(view)
	_test_shader()
	_check(world.to_data() == before_world and
		hydro.to_snapshot() == before_water and
		surface.to_snapshot() == before_surface,
		"Смена LOD и скорости анимации не меняет физику карты")
	view.free()

	if failures.is_empty():
		print("Этап 11.6/W6: дальний LOD и часы воды — успешно")
		quit(0)
		return
	for reason in failures:
		printerr("Этап 11.6/W6: ", reason)
	quit(1)


func _initialize() -> void:
	## Сначала проверяем кодовые контракты; FPS устройств — отдельно.
	_run()
