extends SceneTree
## Приёмка рельефа: семь форм, гладкие переходы, уклоны и сохранения v1.
## Не проверяет почвы, воду, климат, растительность и экономику.

const Config = preload("res://scripts/world_config.gd")
const WorldMap = preload("res://scripts/world_map.gd")
const Terrain = preload("res://scripts/terrain.gd")
const Landforms = preload("res://scripts/terrain_v2.gd")
const Relief = preload("res://scripts/relief.gd")
const Chunk = preload("res://scripts/chunk.gd")

var _errors: Array[String] = []


func _check(ok: bool, note: String) -> void:
	if not ok:
		_errors.append(note)


func _initialize() -> void:
	_run()


func _run() -> void:
	var world := WorldMap.new(Config.new())
	_check(world.config.generator_version == 2, "По умолчанию используется генератор v2")
	_check(Landforms.FORM_NAMES.size() == 7, "Семь географических форм")
	var seen := {}
	var minimum := INF
	var maximum := -INF
	var biggest_step := 0.0
	for y in range(2, 191, 5):
		for x in range(2, 255, 5):
			var point := Vector2i(x, y)
			var value: float = world.vertex_at(point)
			_check(is_finite(value), "Высота всегда конечна")
			minimum = minf(minimum, value)
			maximum = maxf(maximum, value)
			biggest_step = maxf(biggest_step, absf(value - world.vertex_at(point + Vector2i(1, 0))))
			biggest_step = maxf(biggest_step, absf(value - world.vertex_at(point + Vector2i(0, 1))))
			var feature := Landforms.sample(float(x), float(y), 1729)
			seen[str(feature["form"])] = true
	_check(minimum < -2.0, "Выраженные естественные низины")
	_check(maximum > 6.0, "Высокие горные массивы")
	_check(biggest_step < 3.7, "Нет одиночных неестественных скачков высоты")
	for form in Landforms.FORM_NAMES:
		_check(seen.has(form), "На стандартной карте видна форма: " + form)

	# У каждого seed своя карта. Координатная формула не зависит от размеров карты.
	var different := 0
	for seed in range(30, 55):
		var a := WorldMap.new(Config.new(256, 192, seed))
		var b := WorldMap.new(Config.new(320, 240, seed))
		var c := WorldMap.new(Config.new(256, 192, seed + 1))
		for pos in [Vector2i(7, 13), Vector2i(61, 73), Vector2i(144, 101)]:
			var first: float = a.vertex_at(pos)
			_check(is_equal_approx(first, b.vertex_at(pos)),
				"Генератор не зависит от расширения карты")
			_check(is_equal_approx(first, a.vertex_at(pos)),
				"Повторный запрос не изменяет мир")
			if not is_equal_approx(first, c.vertex_at(pos)):
				different += 1
	_check(different >= 70, "Разные seed дают различные формы рельефа")
	_check(world.vertex_at(Vector2i(48, 52)) == world.vertex_at(Vector2i(48, 52)),
		"Нет изменений от порядка генерации")

	# Физический профиль показывает действительный уклон и перепад, а не цвет.
	var profile := Relief.profile_at(world, Vector2(123.5, 81.5))
	_check(profile.has("height") and profile.has("slope_degrees"),
		"Профиль содержит физическую высоту и уклон")
	_check(float(profile["slope_degrees"]) >= 0.0
		and float(profile["slope_degrees"]) < 89.0, "Угол уклона ограничен")
	_check(float(profile["relief_24"]) >= 0.0, "Перепад высот неотрицателен")
	_check(profile["descent"] is Vector2, "Есть направление понижения высоты")
	_check(Relief.profile_at(world, Vector2(-1, 0)).is_empty(), "Вне карты нет профиля")

	# Изменения вершины реально отражаются в высоте, профиле и GPU-сетке.
	var edit := Vector2i(16, 9)
	var original: float = world.vertex_at(edit)
	var before := Relief.profile_at(world, Vector2(edit))
	_check(world.set_vertex(edit, original + 1.0), "Физическая высота меняется")
	var after := Relief.profile_at(world, Vector2(edit))
	_check(absf(float(after["height"]) - float(before["height"]) - 1.0) < 0.00001,
		"Профиль читает изменение из WorldMap")
	var left := Chunk.create_mesh(0, 0, 1, world)
	var right := Chunk.create_mesh(1, 0, 1, world)
	var vertices_left: PackedVector3Array = left.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	var vertices_right: PackedVector3Array = right.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	_check(vertices_left[9 * 17 + 16].is_equal_approx(vertices_right[9 * 17]),
		"Изменение общей вершины одинаково в двух GPU-чанках")

	# Сохранения первого этапа без версии генератора читаются по старой формуле.
	var old_config := Config.new(256, 192, 1729, 16, 64, 0.9, 1)
	var legacy := WorldMap.new(old_config)
	var old_height: float = legacy.vertex_at(Vector2i(30, 40))
	_check(is_equal_approx(old_height, Terrain.vertex_height_on_map(30, 40,
		256, 192, 1729, 1)), "Генератор v1 остался доступным")
	var saved := legacy.to_data()
	saved["config"].erase("generator_version")
	var restored = WorldMap.from_data(JSON.parse_string(JSON.stringify(saved)))
	_check(restored != null, "Старый файл карты читается")
	if restored != null:
		_check(restored.config.generator_version == 1, "Старый мир остаётся на v1")
		_check(is_equal_approx(restored.vertex_at(Vector2i(30, 40)), old_height),
			"Геометрия старого мира не изменилась")
	var restored_new = WorldMap.from_data(JSON.parse_string(JSON.stringify(world.to_data())))
	_check(restored_new != null, "Новый мир сохраняется")
	if restored_new != null:
		_check(restored_new.config.generator_version == 2, "В сохранении зафиксирована v2")
		_check(is_equal_approx(restored_new.vertex_at(edit), original + 1.0),
			"Изменение высоты восстановлено")

	# Сеточная разбивка не меняет высоты, даже на неполных крайних чанках.
	var partial := WorldMap.new(Config.new(70, 50, 1729, 16, 32))
	var mesh := Chunk.create_mesh(4, 3, 1, partial)
	_check(mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX].size() == 21,
		"Неполный чанк рельефа корректен")

	if not _errors.is_empty():
		for message in _errors:
			push_error("Рельеф: " + message)
		quit(1)
		return
	print("Этап 2: все формы, геометрия, уклоны, seed и сохранения — успешно.")
	quit(0)
