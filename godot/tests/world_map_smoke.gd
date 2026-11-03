extends SceneTree
## Приёмка этапа 1: координаты, границы, регионы, чанки, seed и изменения.

const Config = preload("res://scripts/world_config.gd")
const WorldMap = preload("res://scripts/world_map.gd")
const Chunk = preload("res://scripts/chunk.gd")
var _failures: Array[String] = []


func _expect(condition: bool, description: String) -> void:
	if not condition:
		_failures.append(description)


func _initialize() -> void:
	_run()


func _run() -> void:
	var cfg = Config.new()
	_expect(cfg.width == 256 and cfg.height == 192, "Размер исходного мира")
	_expect(cfg.chunk_count() == Vector2i(16, 12), "Число чанков")
	_expect(cfg.region_count() == Vector2i(4, 3), "Двенадцать природных регионов")
	_expect(cfg.contains_cell(Vector2i(255, 191)), "Последняя клетка допустима")
	_expect(not cfg.contains_cell(Vector2i(256, 191)), "Правая граница закрыта")
	_expect(not cfg.contains_cell(Vector2i(-1, 0)), "Отрицательная клетка отклонена")
	_expect(cfg.contains_vertex(Vector2i(256, 192)), "Верхняя граница сетки вершин")
	_expect(not cfg.contains_vertex(Vector2i(257, 192)), "Лишняя вершина отклонена")
	_expect(not cfg.contains_point(Vector2(256.0, 20.0)), "Край точки не включён")
	_expect(cfg.cell_at(Vector2(13.8, 2.9)) == Vector2i(13, 2), "Дробные координаты")
	_expect(cfg.cell_at(Vector2(-0.01, 5.0)) == Vector2i(-1, -1), "Точка за границей")
	_expect(cfg.chunk_of(Vector2i(16, 16)) == Vector2i(1, 1), "Адрес чанка")
	_expect(cfg.region_of(Vector2i(64, 64)) == Vector2i(1, 1), "Адрес региона")
	_expect(cfg.region_rect(Vector2i(3, 2)).size == Vector2i(64, 64),
		"Размер края региона")
	_expect(cfg.chunk_rect(Vector2i(0, 0)).end == Vector2i(16, 16),
		"Непересекающиеся границы чанков")
	_expect(cfg.region_seed(Vector2i(2, 1)) == cfg.region_seed(Vector2i(2, 1)),
		"Повторяемый seed региона")
	_expect(cfg.region_seed(Vector2i(1, 1)) != cfg.region_seed(Vector2i(2, 1)),
		"Независимые seed регионов")
	_expect(cfg.region_seed(Vector2i(4, 0)) == -1, "Некорректный регион")

	var scene_position: Vector3 = cfg.to_scene(Vector2(23.25, 31.5), 4.5)
	_expect(scene_position.is_equal_approx(Vector3(23.25, 4.05, 31.5)),
		"Единицы высоты сцены")
	_expect(cfg.from_scene(scene_position).is_equal_approx(Vector3(23.25, 31.5, 4.5)),
		"Обратное преобразование координат")

	var partial = Config.new(70, 50, 9123, 16, 32, 1.25)
	_expect(partial.chunk_count() == Vector2i(5, 4), "Неполные чанки")
	_expect(partial.region_count() == Vector2i(3, 2), "Неполные регионы")
	_expect(partial.chunk_rect(Vector2i(4, 3)) == Rect2i(64, 48, 6, 2),
		"Правый нижний чанк не выходит за мир")
	_expect(partial.region_rect(Vector2i(2, 1)) == Rect2i(64, 32, 6, 18),
		"Правый нижний регион не выходит за мир")
	_expect(not partial.chunk_rect(Vector2i(5, 0)).has_area(),
		"Не существует чанка за пределами")
	var partial_map = WorldMap.new(partial)
	_expect(is_nan(partial_map.vertex_at(Vector2i(71, 0))),
		"Высота вершины за пределами не подменяется ближайшей")
	_expect(is_nan(partial_map.height_at(Vector2(70, 49))),
		"Высота за пределами не подменяется ближайшей")
	_expect(partial_map.height_at(Vector2(69.5, 49.5)) > -100.0,
		"Граница частичного чанка доступна")
	_expect(partial_map.chunk_at(Vector2i(69, 49))["id"] == 19,
		"Уникальный ID последнего чанка")
	_expect(partial_map.region_at(Vector2i(69, 49))["id"] == 5,
		"Уникальный ID последнего региона")
	_expect(partial_map.region_at(Vector2i(69, 49))["bounds"] == Rect2i(64, 32, 6, 18),
		"Геометрия последнего региона")
	_expect(partial_map.region_at(Vector2i(-1, 0)).is_empty(),
		"За пределами природного региона нет")
	var partial_mesh: ArrayMesh = Chunk.create_mesh(4, 3, 1, partial_map)
	var mesh_arrays := partial_mesh.surface_get_arrays(0)
	_expect(mesh_arrays[Mesh.ARRAY_VERTEX].size() == 21,
		"Последний чанк содержит 7×3 вершин")
	_expect(mesh_arrays[Mesh.ARRAY_INDEX].size() == 72,
		"Последний чанк содержит 12 треугольников")

	var original := WorldMap.new(cfg)
	var same := WorldMap.new(Config.new())
	var changed_seed := WorldMap.new(Config.new(256, 192, 1730))
	var sample := Vector2i(73, 41)
	_expect(is_equal_approx(original.vertex_at(sample), same.vertex_at(sample)),
		"Повторяемость высоты одного seed")
	_expect(not is_equal_approx(original.vertex_at(sample), changed_seed.vertex_at(sample)),
		"Разные seed дают разные высоты")
	_expect(is_equal_approx(original.vertex_at(Vector2i(5, 2)),
		same.vertex_at(Vector2i(5, 2))), "Порядок чтения не меняет генерацию")
	_expect(is_equal_approx(original.height_at(Vector2(12.5, 9.25)),
		same.height_at(Vector2(12.5, 9.25))), "Повторяемость непрерывной высоты")

	var coord := Vector2i(16, 9)
	var baseline: float = original.vertex_at(coord)
	var observed: Array[Dictionary] = []
	original.vertices_changed.connect(func(chunks: Array[Vector2i], index: int) -> void:
		observed.append({"chunks": chunks.duplicate(), "revision": index}))
	_expect(original.set_vertex(coord, baseline + 1.5), "Изменение вершины применилось")
	_expect(original.revision == 1, "Ревизия увеличилась один раз")
	_expect(observed.size() == 1, "Событие об изменении создано")
	_expect(observed[0]["chunks"] == [Vector2i(0, 0), Vector2i(1, 0)],
		"Общая вершина меняет оба соседних чанка")
	_expect(original.take_dirty_chunks() == [Vector2i(0, 0), Vector2i(1, 0)],
		"Список изменённых чанков извлекается один раз")
	_expect(original.take_dirty_chunks().is_empty(), "Очередь изменений очищается")
	_expect(not original.set_vertex(coord, baseline + 1.5), "Повтор не создаёт событие")
	_expect(not original.set_vertex(Vector2i(-1, 5), 2.0), "Изменение вне мира запрещено")
	_expect(not original.set_vertex(coord, INF), "Бесконечная высота запрещена")
	_expect(not original.set_vertex(coord, 1000.0), "Недопустимая высота запрещена")
	_expect(original.revision == 1, "Ошибки не увеличивают ревизию")

	var current: float = original.vertex_at(coord)
	var rejected := {Vector2i(5, 5): 3.0, Vector2i(999, 999): 4.0}
	_expect(not original.apply_vertex_changes(rejected), "Пакет с ошибкой отклонён")
	_expect(original.revision == 1, "Отклонённый пакет не меняет ревизию")
	_expect(is_equal_approx(original.vertex_at(coord), current), "Сохранена предыдущая вершина")
	var mesh_left := Chunk.create_mesh(0, 0, 1, original)
	var mesh_right := Chunk.create_mesh(1, 0, 1, original)
	var left_vertices: PackedVector3Array = mesh_left.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	var right_vertices: PackedVector3Array = mesh_right.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	_expect(left_vertices[9 * 17 + 16].is_equal_approx(right_vertices[9 * 17]),
		"Стыки двух GPU-чанков читают одну вершину")
	_expect(is_equal_approx(original.height_at(Vector2(coord)), current),
		"Непрерывная высота знает об изменениях")
	_expect(original.changed_vertex_count() == 1, "Изменения хранятся разреженно")

	var serialized := JSON.stringify(original.to_data())
	var parsed = JSON.parse_string(serialized)
	var restored = WorldMap.from_data(parsed)
	_expect(restored != null, "Загрузка корректного формата")
	if restored != null:
		_expect(restored.to_data() == original.to_data(), "Полная обратимость данных карты")
		_expect(is_equal_approx(restored.vertex_at(coord), current), "Высота пережила загрузку")
		_expect(restored.revision == 0, "Загрузка не считается событием игрового времени")
	var duplicate: Dictionary = original.to_data().duplicate(true)
	duplicate["vertices"].append(duplicate["vertices"][0])
	_expect(WorldMap.from_data(duplicate) == null, "Повторяющаяся вершина запрещена")
	_expect(WorldMap.from_data({"version": 100, "config": cfg.to_data(), "vertices": []}) == null,
		"Неизвестная версия отклонена")
	_expect(Config.from_data({"width": 0, "height": 20}) == null,
		"Неполная конфигурация не принимается")
	_expect(original.set_vertex(coord, baseline), "Можно вернуть исходную высоту")
	_expect(original.changed_vertex_count() == 0, "Возврат высоты очищает изменение")

	if not _failures.is_empty():
		for message in _failures:
			push_error("Этап 1: " + message)
		quit(1)
		return
	print("Этап 1: размеры, координаты, регионы, чанки, seed, правки и сохранение — успешно.")
	quit(0)
