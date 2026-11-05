extends SceneTree
## Этап 11.2/L3: панорамная светотень от реального солнца.
## Никакие дополнительные теневые карты, высоты или коллизии не создаются.

const Config = preload("res://scripts/world_config.gd")
const Map = preload("res://scripts/world_map.gd")
const Hydro = preload("res://scripts/hydrology.gd")
const Surface = preload("res://scripts/surface.gd")
const View = preload("res://scripts/world.gd")
const GroundShader = preload("res://shaders/natural_ground.gdshader")
const ShadowLOD = preload("res://scripts/world_shadow_lod.gd")

var failures: Array[String] = []


func _check(valid: bool, reason: String) -> void:
	## Не скрываем несколько ошибок за первым исключением.
	if not valid:
		failures.append(reason)


func _test_scene(world: RefCounted) -> void:
	## Проверяем настоящий источник DirectionalLight3D и общий PBR.
	## Никакой второй источник света для имитации теней не создаём.
	var view := View.new()
	view._world_model = world
	view._center = Vector2(16.0, 12.0)
	view._setup_environment()
	view._setup_materials()
	var camera := Camera3D.new()
	view.add_child(camera)
	view._camera = camera
	var sun: Vector3 = view._world_light.global_transform.basis.z.normalized()
	var transferred: Vector3 = view._ground_material.get_shader_parameter(
		"far_light_direction")
	_check(transferred.distance_to(sun) < 0.00001,
		"Направление дальнего затенения соответствует реальному солнцу")
	_check(sun.length() > 0.99 and sun.y > 0.0,
		"Солнечный вектор направлен над горизонтом")

	# Смена камеры управляет только качеством шейдера.
	# Дальняя светотень не запрашивает дорогое теневое освещение.
	for zoom in [32.0, 58.0, 76.0, 96.0, 160.0]:
		camera.size = zoom
		view._update_material_detail()
		var detail: float = view._ground_material.get_shader_parameter(
			"detail_strength")
		_check(is_equal_approx(detail, View._detail_for_zoom(zoom)),
			"Панорамная светотень плавно зависит от масштаба")
		_check(view._world_light.shadow_enabled == ShadowLOD.active(zoom, 0),
			"Карты геометрических теней не включаются в далёком масштабе")
	_check(is_equal_approx(float(view._ground_material.get_shader_parameter(
		"relief_contrast")) if view._ground_material.get_shader_parameter(
		"relief_contrast") != null else 0.72, 0.72),
		"Базовая сила рельефа сохранилась без нового профиля физики")
	view.free()


func _test_shader() -> void:
	## Форма долин и гор читается из WorldMap через нормали и CUSTOM1.
	## Художественное сравнение реальных PNG остаётся отдельной приёмкой.
	var code: String = GroundShader.code
	_check(code.contains("far_light_direction") and
		code.contains("ground_world_normal") and
		code.contains("sun_facing") and code.contains("slope_light"),
		"Теневая сторона зависит от физической нормали и солнечного вектора")
	_check(code.contains("far_blend") and
		code.contains("detail_strength") and code.contains("far_relief"),
		"Шейдер плавно усиливает панорамные формы только при отдалении")
	_check(code.contains("ground_shape = CUSTOM1") and
		code.contains("ridge") and code.contains("ravine"),
		"Гребни и овраги читаются из одного физического рельефа")
	_check(not code.contains("VERTEX =") and
		not code.contains("shadow_sampler"),
		"Дальняя светотень не меняет геометрию и не требует карт теней")


func _run() -> void:
	## Проверяем, что настройка света не изменяет физические снимки.
	var world := Map.new(Config.new(32, 24, 1729, 8, 16))
	var hydro := Hydro.new(world)
	hydro.rebuild()
	var surface := Surface.new(world, hydro)
	surface.rebuild()
	hydro.apply_rainfall_map(surface.runoff_map())
	var world_before: Dictionary = world.to_data()
	var hydro_before: Dictionary = hydro.to_snapshot()
	var surface_before: Dictionary = surface.to_snapshot()
	_test_scene(world)
	_test_shader()
	_check(world.to_data() == world_before and
		hydro.to_snapshot() == hydro_before and
		surface.to_snapshot() == surface_before,
		"Светотень не изменяет физику высот, воды и грунта")
	if failures.is_empty():
		print("Этап 11.2/L3: дальняя светотень по физике — успешно")
		quit(0)
		return
	for reason in failures:
		printerr("Этап 11.2/L3: ", reason)
	quit(1)


func _initialize() -> void:
	## Технический smoke запускается без графического интерфейса.
	_run()
