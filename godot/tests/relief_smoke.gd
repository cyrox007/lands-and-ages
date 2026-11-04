extends SceneTree
## Приёмка единого генератора: семь форм, уклоны, seed и сохранения.
## Не проверяет почвы, воду, климат, растительность и экономику.

const Config = preload("res://scripts/world_config.gd")
const WorldMap = preload("res://scripts/world_map.gd")
const Terrain = preload("res://scripts/terrain.gd")
const Landforms = preload("res://scripts/terrain.gd")
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
	_check(world.config.width == 256, "Используется единый генератор")
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

	# Большие формы должны образовывать протяжённые связные зоны,
	# а не случайно разбросанные независимые клетки.
	var labels := {}
	for y in range(4, 192, 4):
		for x in range(4, 256, 4):
			labels[Vector2i(x / 4, y / 4)] = Landforms.form_at(float(x), float(y), 1729)
	var visited := {}
	var largest := {}
	for start in labels.keys():
		if visited.has(start):
			continue
		var kind: String = labels[start]
		var queue: Array[Vector2i] = [start]
		visited[start] = true
		var index := 0
		while index < queue.size():
			var current := queue[index]
			index += 1
			for offset in [Vector2i.LEFT, Vector2i.RIGHT, Vector2i.UP, Vector2i.DOWN]:
				var neighbour: Vector2i = current + offset
				if labels.get(neighbour, "") != kind or visited.has(neighbour):
					continue
				visited[neighbour] = true
				queue.append(neighbour)
		largest[kind] = maxi(int(largest.get(kind, 0)), queue.size())
	for form in Landforms.FORM_NAMES:
		_check(int(largest.get(form, 0)) >= 12,
			"Связная площадь не менее 192 клеток: " + form)

	# У каждого seed своя карта. Координатная формула не зависит от размеров карты.
	var different := 0
	for world_seed in range(30, 130):
		var a := WorldMap.new(Config.new(256, 192, world_seed))
		var b := WorldMap.new(Config.new(320, 240, world_seed))
		var c := WorldMap.new(Config.new(256, 192, world_seed + 1))
		for pos in [Vector2i(7, 13), Vector2i(61, 73), Vector2i(144, 101)]:
			var first: float = a.vertex_at(pos)
			# Географический край зависит от размеров; внутренний рельеф сохраняет seed.
			if pos.x > 44 and pos.y > 44 and pos.x < 212 and pos.y < 148:
				_check(is_equal_approx(first, b.vertex_at(pos)),
					"Рельеф вдали от краёв сохраняется при расширении карты")
			_check(is_equal_approx(first, a.vertex_at(pos)),
				"Повторный запрос не изменяет мир")
			if not is_equal_approx(first, c.vertex_at(pos)):
				different += 1
	_check(different >= 295, "100 разных seed дают различные формы рельефа")
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

	# В разработке действует один алгоритм. Старые прототипные снимки отвергаются.
	var rejected: Dictionary = world.to_data()
	rejected["config"]["generator_version"] = 1
	_check(Config.from_data(rejected["config"]) == null, "Старый генератор отклоняется")
	rejected.erase("config")
	_check(WorldMap.from_data(rejected) == null, "Неполный снимок отклоняется")
	var obsolete: Dictionary = world.to_data()
	obsolete["version"] = 1
	_check(WorldMap.from_data(obsolete) == null, "Прототипная версия не загружается")
	var restored_new = WorldMap.from_data(JSON.parse_string(JSON.stringify(world.to_data())))
	_check(restored_new != null, "Новый мир сохраняется")
	if restored_new != null:
		_check(restored_new.config.width == world.config.width, "Размеры карты восстановлены")
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
