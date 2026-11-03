extends SceneTree
## Приёмка событий: атомарные правки, регионы, баланс грунта и пересчёт мира.

const Config = preload("res://scripts/world_config.gd")
const WorldMap = preload("res://scripts/world_map.gd")
const Hydrology = preload("res://scripts/hydrology.gd")
const Surface = preload("res://scripts/surface.gd")
const Climate = preload("res://scripts/climate.gd")
const Landscape = preload("res://scripts/landscape_events.gd")
const Chunk = preload("res://scripts/chunk.gd")

var failures: Array[String] = []


func _check(condition: bool, reason: String) -> void:
	if not condition:
		failures.append(reason)


func _initialize() -> void:
	_run()


func _run() -> void:
	var cfg := Config.new(72, 54, 1729, 16, 32)
	var world := WorldMap.new(cfg)
	var hydro := Hydrology.new(world)
	hydro.rebuild()
	var surface := Surface.new(world, hydro)
	surface.rebuild()
	var climate := Climate.new(world, hydro)
	climate.rebuild()
	var events := Landscape.new(world)

	# Сохраняем снег в удалённой точке для проверки локальности воздействия.
	var far := Vector2i(66, 4)
	surface.advance_day(1.0, -12.0)
	surface.advance_day(1.0, -12.0)
	var snow_before: float = surface.profile_at(far)["snow"]
	var old_far_height: float = world.vertex_at(far)
	var center := Vector2(26.0, 28.0)
	var center_vertex := Vector2i(26, 28)
	var old_center_height: float = world.vertex_at(center_vertex)
	var signals := {"count": 0}
	world.vertices_changed.connect(func(_chunks: Array[Vector2i], _revision: int) -> void:
		signals["count"] = int(signals["count"]) + 1
	)
	var first: Dictionary = events.apply("поднятие", center, 20.0, 4.0)
	_check(not first.is_empty(), "Региональное поднятие принято")
	_check(int(first.get("vertices", 0)) > 100, "Изменяется целый район, не клетка")
	var changes: Array[Vector2i] = world.take_dirty_chunks()
	_check(changes.size() > 1 and int(signals["count"]) == 1,
		"Событие пересекает чанки и оповещает подписчиков один раз")
	_check(world.vertex_at(center_vertex) > old_center_height + 3.9,
		"Высота центра физически выросла")
	_check(is_equal_approx(world.vertex_at(far), old_far_height),
		"Дальняя часть карты не изменилась")
	var updated_revision: int = world.revision
	_check(events.apply("поднятие", Vector2(26, 28), INF, 1.0).is_empty()
		and events.apply("неизвестно", center, 12.0, 1.0).is_empty()
		and events.apply("просадка", center, 12.0, 999.0).is_empty()
		and events.apply("эрозия", Vector2(-4, 10), 12.0, 1.0).is_empty(),
		"Неправильные и бесконечные события отвергаются")
	_check(world.revision == updated_revision,
		"Недопустимое воздействие не изменяет мир")

	# Зависимые данные не хранят собственные копии высот.
	hydro.rebuild()
	climate.rebuild()
	_check(hydro.apply_rainfall_map(climate.rainfall_map()),
		"Реки обновляют сток после изменения долины")
	surface.rebuild(changes)
	surface.synchronize_climate(climate)
	_check(is_equal_approx(float(hydro.water_at(center_vertex)["ground"]),
		world.height_at(center + Vector2(0.5, 0.5))),
		"Вода использует новые высоты")
	_check(is_equal_approx(float(surface.profile_at(far)["snow"]), snow_before),
		"Локальное изменение не стирает снег на другой стороне мира")
	_check(climate.weather_at(center_vertex).has("temperature"),
		"Климат перестраивается по новому рельефу")

	# Проверяем непрерывность геометрии на стыке изменённых чанков.
	var left := Chunk.create_mesh(1, 1, 1, world, surface, 0, climate)
	var right := Chunk.create_mesh(2, 1, 1, world, surface, 0, climate)
	var a: PackedVector3Array = left.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	var b: PackedVector3Array = right.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	for row in range(17):
		_check(a[row * 17 + 16].distance_to(b[row * 17]) < 0.0001,
			"На границах GPU-чанков нет разрывов")

	var saved: Dictionary = JSON.parse_string(JSON.stringify(world.to_data()))
	var loaded := WorldMap.from_data(saved)
	_check(loaded != null, "Географические изменения сохраняются")
	if loaded != null:
		_check(is_equal_approx(loaded.vertex_at(center_vertex),
			world.vertex_at(center_vertex)), "Высота восстановлена из снимка")
		_check(loaded.changed_vertex_count() == world.changed_vertex_count(),
			"В снимке сохранены все изменённые вершины")

	# Перемещение грунта не создаёт новый объём рельефа.
	var downhill := Vector2i(-1, -1)
	for y in range(14, 42):
		for x in range(14, 52):
			if downhill.x >= 0:
				break
			var normal: Vector3 = world.normal_at(Vector2i(x, y))
			if Vector2(normal.x, normal.z).length() > 0.15:
				downhill = Vector2i(x, y)
		if downhill.x >= 0:
			break
	_check(downhill.x >= 0, "Есть склон для испытательного оползня")
	if downhill.x >= 0:
		var before := 0.0
		for y in range(cfg.height + 1):
			for x in range(cfg.width + 1):
				before += world.vertex_at(Vector2i(x, y))
		var slide: Dictionary = events.apply("оползень", Vector2(downhill), 11.0, 2.0)
		_check(not slide.is_empty(), "Оползень меняет высоты на склоне")
		var after := 0.0
		for y in range(cfg.height + 1):
			for x in range(cfg.width + 1):
				after += world.vertex_at(Vector2i(x, y))
		_check(absf(after - before) < 0.02,
			"Оползень переносит грунт, почти не изменяя общий объём")

	var before_erosion: int = world.revision
	var erosion: Dictionary = events.apply("эрозия", center, 15.0, 1.0)
	_check(not erosion.is_empty() and world.revision == before_erosion + 1,
		"Эрозия выполняется отдельной атомарной правкой")
	_check(not events.apply("поднятие", center, 150.0, 1.0).has("vertices"),
		"Защита от чрезмерно большого события")

	if not failures.is_empty():
		for message in failures:
			push_error("Процессы: " + message)
		quit(1)
		return
	print("Этап 6.1: изменение региона, сохранения, гидрология, климат и швы — успешно.")
	quit(0)
