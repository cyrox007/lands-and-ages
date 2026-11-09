extends SceneTree
## 11/CLIMATE-DIRTY: после локального изменения высот климат
## должен точно совпасть с полной перестройкой той же карты,
## при этом очередь грязных чанков для рендера сохраняется.

const Config = preload("res://scripts/world_config.gd")
const Map = preload("res://scripts/world_map.gd")
const Hydro = preload("res://scripts/hydrology.gd")
const Climate = preload("res://scripts/climate.gd")
const SIZE := Vector2i(256, 192)
var failures: Array[String] = []


func _check(ok: bool, reason: String) -> void:
	# Регистрируем и геометрические, и численные нарушения:
	# одинаковая картинка при потерянной очереди чанков неверна.
	if not ok:
		failures.append(reason)


func _compare(a: RefCounted, b: RefCounted, label: String) -> void:
	# Климат хранит четыре долговременных средних слоя и
	# четыре погодных слоя дня. Сверяем ВСЕ клетки без допуска.
	for field in ["_mean", "_humidity", "_altitude", "_marine",
			"_temperature", "_rain", "_wind", "_storm"]:
		_check(a.get(field) == b.get(field),
			"Климат совпадает после " + label + ": " + field)


func _run() -> void:
	var world := Map.new(Config.new(SIZE.x, SIZE.y, 1729, 16, 32))
	var hydro := Hydro.new(world)
	hydro.rebuild()
	var partial := Climate.new(world, hydro)
	partial.rebuild()
	partial.set_day(4)
	# Подбираем настоящую сушу достаточно далеко от края:
	# микроскопическая деформация не должна создавать новое море.
	var cell := Vector2i(-1, -1)
	for y in range(32, SIZE.y - 32):
		if cell.x >= 0:
			break
		for x in range(32, SIZE.x - 32):
			var candidate := Vector2i(x, y)
			var index: int = hydro.cell_index(candidate)
			if not hydro.has_water(index) and \
					world.vertex_at(candidate) > 2.5:
				cell = candidate
				break
	_check(cell.x >= 0, "Найден сухой участок для локального сдвига")
	if cell.x < 0:
		quit(1)
		return

	var before := world.vertex_at(cell)
	var change := {cell: before + 0.025}
	_check(world.apply_vertex_changes(change),
		"Проверена настоящая атомарная правка высоты")
	var pending: Array[Vector2i] = world.peek_dirty_chunks()
	_check(not pending.is_empty(),
		"Чанки изменения доступны без потребления очереди")
	var previous_partials: int = partial.partial_rebuilds
	# Это тот же вызов, который выполняет NaturalDisasters
	# сразу после эрозии в обычном WorldDayRunner.
	partial.ensure_ready()
	_check(partial.partial_rebuilds == previous_partials + 1,
		"Климат обновил только затронутые строки после геологии")
	_check(partial.last_rebuild_rows < SIZE.y,
		"Частичная перестройка не трогает всю карту")
	_check(world.peek_dirty_chunks() == pending,
		"Климат не забирает очередь графических обновлений")

	# Независимый эталон полностью пересоздаёт климат той же
	# изменённой физической карты. Данные должны совпасть везде.
	var full := Climate.new(world, hydro)
	full.rebuild()
	full.set_day(partial.day)
	_compare(partial, full, "частичной перестройки")
	_check(world.take_dirty_chunks() == pending,
		"WorldDayRunner всё ещё получает ВСЕ изменённые чанки")
	_check(world.peek_dirty_chunks().is_empty(),
		"Очередь очищается только при явном take_dirty_chunks")
	print("CLIMATE-DIRTY: строк пересчитано=", partial.last_rebuild_rows,
		" из ", SIZE.y, ", чанков=", pending.size())
	if not failures.is_empty():
		for reason in failures:
			push_error("CLIMATE-DIRTY: " + reason)
		quit(1)
		return
	print("CLIMATE-DIRTY: мировые поля, климат и очередь чанков — успешно")
	quit(0)


func _initialize() -> void:
	call_deferred("_run")
