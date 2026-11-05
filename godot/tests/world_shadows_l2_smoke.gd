extends SceneTree
## Этап 11.2/L2: тени рельефа и леса зависят от камеры, не от физики.
## Проверяем ограничение числа теневых чанков и смену режима.

const Shadow = preload("res://scripts/world_shadow_lod.gd")
const View = preload("res://scripts/world.gd")
const Config = preload("res://scripts/world_config.gd")
const Map = preload("res://scripts/world_map.gd")
const Hydro = preload("res://scripts/hydrology.gd")
const Surface = preload("res://scripts/surface.gd")

var failures: Array[String] = []


func _check(ok: bool, description: String) -> void:
	## Не прерываем тест на первом нарушении, чтобы увидеть весь
	## набор ошибок при смене масштаба и дальних видов.
	if not ok:
		failures.append(description)


func _chunk() -> Node3D:
	## Создаём типовой контейнер: грунт, вода и сгруппированная природа.
	## Физическая сетка для проверки свойств теней здесь не нужна.
	var result := Node3D.new()
	var ground := MeshInstance3D.new()
	ground.name = "Рельеф"
	result.add_child(ground)
	var water := MeshInstance3D.new()
	water.name = "Поверхностная вода"
	result.add_child(water)
	var forest := Node3D.new()
	forest.name = "Природные объекты"
	result.add_child(forest)
	var trees := MultiMeshInstance3D.new()
	trees.name = "Деревья"
	forest.add_child(trees)
	return result


func _test_chunk_budget() -> void:
	## Вблизи кастеров строго ограниченное количество — максимум
	## 25 грунтовых и 9 лесных чанков на всей огромной карте.
	var ground_total := 0
	var forest_total := 0
	for y in range(-30, 31):
		for x in range(-30, 31):
			var coord := Vector2i(x, y)
			ground_total += int(Shadow.chunk_casts(coord, Vector2i.ZERO, 32.0, 0))
			forest_total += int(Shadow.chunk_casts(coord, Vector2i.ZERO, 32.0, 0, true))
	_check(ground_total == 25 and forest_total == 9,
		"Количество затеняющих чанков не зависит от площади мира")
	_check(not Shadow.active(96.0, 0) and not Shadow.active(32.0, 2),
		"Дальняя камера и диагностические режимы не запрашивают карты теней")

	var node := _chunk()
	Shadow.configure_chunk(node, true, true)
	var ground := node.get_node("Рельеф") as MeshInstance3D
	var water := node.get_node("Поверхностная вода") as MeshInstance3D
	var forest := node.get_node("Природные объекты/Деревья") as MultiMeshInstance3D
	_check(ground.cast_shadow == GeometryInstance3D.SHADOW_CASTING_SETTING_ON,
		"Грунт отбрасывает тени в ближнем масштабе")
	_check(forest.cast_shadow == GeometryInstance3D.SHADOW_CASTING_SETTING_ON,
		"Инстансированные деревья отбрасывают тени без отдельных узлов")
	_check(water.cast_shadow == GeometryInstance3D.SHADOW_CASTING_SETTING_ON,
		"Ближняя тень не меняет настройку водной геометрии")
	Shadow.configure_chunk(node, false, false)
	_check(ground.cast_shadow == GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		and forest.cast_shadow == GeometryInstance3D.SHADOW_CASTING_SETTING_OFF,
		"При отдалении тени физически отключаются в рендере")
	node.free()


func _test_camera() -> void:
	## Проверяем настройку общего направленного света и чанков на
	## одной карте, сравнивая состояние мира до и после смены масштаба.
	var world := Map.new(Config.new(32, 24, 1729, 8, 16))
	var hydro := Hydro.new(world)
	hydro.rebuild()
	var surface := Surface.new(world, hydro)
	surface.rebuild()
	hydro.apply_rainfall_map(surface.runoff_map())
	var before_world: Dictionary = world.to_data()
	var before_water: Dictionary = hydro.to_snapshot()
	var before_ground: Dictionary = surface.to_snapshot()

	var view := View.new()
	view._world_model = world
	view._center = Vector2(12.0, 12.0)
	view._setup_environment()
	var camera := Camera3D.new()
	view.add_child(camera)
	view._camera = camera
	camera.size = 32.0
	view._active[Vector2i(1, 1)] = _chunk()
	view._active[Vector2i(9, 9)] = _chunk()
	view._update_shadow_lod()
	_check(view._world_light.shadow_enabled,
		"Приближённая камера включает реальные тени")
	_check((view._active[Vector2i(1, 1)] as Node3D).get_node("Рельеф").cast_shadow
		== GeometryInstance3D.SHADOW_CASTING_SETTING_ON,
		"Ближний чанк участвует в карте теней")
	_check((view._active[Vector2i(9, 9)] as Node3D).get_node("Рельеф").cast_shadow
		== GeometryInstance3D.SHADOW_CASTING_SETTING_OFF,
		"Дальний чанк не нагружает карту теней")

	camera.size = 96.0
	view._update_shadow_lod()
	_check(not view._world_light.shadow_enabled,
		"Панорамный масштаб выключает направленную карту теней")
	_check((view._active[Vector2i(1, 1)] as Node3D).get_node("Рельеф").cast_shadow
		== GeometryInstance3D.SHADOW_CASTING_SETTING_OFF,
		"Лес и скалы больше не отбрасывают дорогостоящие тени издали")

	for chunk in view._active.values():
		(chunk as Node3D).free()
	view._active.clear()
	view.free()
	_check(world.to_data() == before_world and hydro.to_snapshot() == before_water
		and surface.to_snapshot() == before_ground,
		"Настройка теней не меняет рельеф, почвы или гидрологию")


func _initialize() -> void:
	## Проверки можно выполнить без GUI и видеокарты; визуальную
	## выразительность и FPS затем оцениваем отдельно в реальном рендере.
	_test_chunk_budget()
	_test_camera()
	if failures.is_empty():
		print("Этап 11.2/L2: ограниченные тени рельефа и леса — успешно")
		quit(0)
		return
	for reason in failures:
		printerr("Этап 11.2/L2: ", reason)
	quit(1)
