extends SceneTree
## 11.7/RF3: последовательные деформации, водосбор, почвы, ресурсы и полный снимок.

const Config = preload("res://scripts/world_config.gd")
const Map = preload("res://scripts/world_map.gd")
const Hydro = preload("res://scripts/hydrology.gd")
const Surface = preload("res://scripts/surface.gd")
const Climate = preload("res://scripts/climate.gd")
const Nature = preload("res://scripts/nature_registry.gd")
const Weather = preload("res://scripts/weather_events.gd")
const Natural = preload("res://scripts/natural_processes.gd")
const Disasters = preload("res://scripts/natural_disasters.gd")
const Fire = preload("res://scripts/fire_registry.gd")
const Landscape = preload("res://scripts/landscape_events.gd")
const Runner = preload("res://scripts/world_day_runner.gd")
const Save = preload("res://scripts/world_save.gd")

const CENTER := Vector2(42.5, 30.5)
var failures: Array[String] = []


func _check(ok: bool, reason: String) -> void:
	# Ошибки разных слоёв не маскируют друг друга: по одному журналу
	# CI можно отличить несогласованный сток, ресурс или сохранение.
	if not ok:
		failures.append(reason)


func _item(world: RefCounted, cell: Vector2i,
		kind: String, wood: int = 0) -> Dictionary:
	# Детерминированный объект занимает реальную клетку WorldMap;
	# постоянный ID совпадает с существующим форматом NatureRegistry.
	return {
		"id": cell.y * world.config.width + cell.x + 1,
		"kind": kind, "species": "сосна" if kind == "дерево" else (
			"камень" if kind == "валун" else "кустарник"),
		"x": cell.x, "y": cell.y, "age_days": 18 * 96,
		"health": 1000, "wood_units": wood, "fallen_wood": 0,
		"state": "целое", "cut_progress": 0,
		"dead_since_day": -1, "fallen_since_day": -1,
		"fall_angle_deg": -1, "radius": 0.35 if kind == "валун" else 0.17
	}


func _models(seed: int) -> Dictionary:
	# Создаём физический склон с плавным водосбором: кратер и
	# последующие сдвиги вправду меняют маршруты дождевой воды.
	var world := Map.new(Config.new(80, 64, seed, 16, 32))
	var heights := {}
	for y in range(65):
		for x in range(81):
			heights[Vector2i(x, y)] = 12.0 + (80.0 - float(x)) * 0.25
	_check(world.apply_vertex_changes(heights), "Контрольный склон создан")
	world.take_dirty_chunks()
	var hydro := Hydro.new(world)
	hydro.rebuild()
	var surface := Surface.new(world, hydro)
	surface.rebuild()
	var climate := Climate.new(world, hydro)
	climate.rebuild()
	_check(climate.set_day(1), "Начальный календарный день установлен")
	_check(surface.advance_climate_day(climate),
		"Грунт первого дня физически рассчитан")
	_check(hydro.apply_rainfall_map(surface.runoff_map()),
		"Реальный суточный сток подан в водосбор")

	# Для балансовой регрессии фиксируем объекты разных типов без
	# зависимости от случайной плотности леса. Это существующий
	# NatureRegistry, а не отдельная физическая модель растений.
	var nature := Nature.new(world, hydro, surface, climate)
	_check(nature.generate(), "Реестр экосистемы инициализирован")
	nature._objects.clear()
	nature._chunks.clear()
	for entry in [
		_item(world, Vector2i(42, 30), "дерево", 12),
		_item(world, Vector2i(48, 31), "дерево", 18),
		_item(world, Vector2i(44, 32), "кустарник"),
		_item(world, Vector2i(48, 33), "валун"),
		_item(world, Vector2i(75, 59), "дерево", 7)
	]:
		nature._objects[int(entry["id"])] = entry
		nature._index(entry)

	var weather := Weather.new(world, climate, surface, hydro)
	var natural := Natural.new(world, hydro, surface, climate)
	var disasters := Disasters.new(world, hydro, surface, climate)
	var fire := Fire.new(world, hydro, surface, climate, nature)
	return {
		"world": world, "hydro": hydro, "surface": surface,
		"climate": climate, "nature": nature, "weather": weather,
		"natural": natural, "disasters": disasters, "fire": fire,
		"runner": Runner.new(world, hydro, surface, climate,
			weather, natural, disasters, nature, fire)
	}


func _total_height(world: RefCounted) -> float:
	# Кратер и оползень передают породу между вершинами. Суммарный
	# объём проверяем независимо от графики и порядка пересборки.
	var total := 0.0
	for y in range(world.config.height + 1):
		for x in range(world.config.width + 1):
			total += world.vertex_at(Vector2i(x, y))
	return total


func _apply(state: Dictionary, kind: String, point: Vector2,
		radius: float, strength: float, pressure: float) -> Dictionary:
	# Каждый следующий удар действует по уже изменённому рельефу.
	# Сначала применяем атомарный WorldMap, затем физическую реакцию
	# реестра и полный пересчёт связанных слоёв, как в игровой сцене.
	var world: RefCounted = state["world"]
	var before: int = world.revision
	var result: Dictionary = Landscape.new(world).apply(
		kind, point, radius, strength)
	_check(not result.is_empty(), "Событие %s действительно произошло" % kind)
	if result.is_empty():
		return {}
	_check(world.revision == before + 1,
		"Геологическое событие меняет ревизию ровно один раз")
	var damage: Dictionary = state["nature"].apply_landscape_impact(
		kind, point, radius, pressure, state["climate"].day)
	_check(state["runner"].synchronize_world(),
		"После %s синхронизированы физические модели" % kind)
	_check(state["hydro"]._terrain_revision == world.revision
		and state["surface"]._terrain_revision == world.revision
		and state["climate"]._terrain_revision == world.revision,
		"Вода, грунт и климат используют одну ревизию рельефа")
	var index: int = state["hydro"].cell_index(world.config.cell_at(point))
	_check(absf(state["hydro"]._ground[index]
		- world.height_at(Vector2(world.config.cell_at(point))
			+ Vector2(0.5, 0.5))) < 0.0001,
		"Высота дна после деформации совпадает с WorldMap")
	return damage


func _sequence(seed: int) -> Dictionary:
	var state: Dictionary = _models(seed)
	var world: RefCounted = state["world"]
	var hydro: RefCounted = state["hydro"]
	var surface: RefCounted = state["surface"]
	var nature: RefCounted = state["nature"]
	var core := Vector2i(42, 30)
	var index: int = hydro.cell_index(core)
	var outer := Vector2i(48, 31)
	var far := Vector2i(75, 59)
	var outer_id: int = outer.y * world.config.width + outer.x + 1
	var core_id: int = core.y * world.config.width + core.x + 1
	var far_id: int = far.y * world.config.width + far.x + 1
	var far_before: Dictionary = nature.object_at(far_id)
	var starting_wood: int = nature.wood_total()

	# Нанос, снег и влага принадлежат Surface, а не вершинам.
	# Изменение геологии не имеет права обнулять их исторический
	# запас до естественного климатического хода.
	surface._sediment[index] = 0.035
	surface._sediment_balance = 0.035
	surface._snow[index] = 0.4
	surface._moisture[index] = 0.66
	surface._waterlogged[index] = 0.3
	var old_downstream: PackedInt32Array = hydro._downstream.duplicate()
	var before_crater := _total_height(world)
	var first: Dictionary = _apply(state, "кратер", CENTER, 9.0, 2.2, 1.0)
	_check(int(first.get("trees_felled", 0)) == 1,
		"Первый удар валит ближайшее дерево")
	_check(absf(_total_height(world) - before_crater) < 0.01,
		"Кратер сохраняет породу между дном и кольцевым валом")
	_check(hydro._downstream != old_downstream
		or hydro.water_count()["lakes"] > 0,
		"Кратер пересчитывает реальный водосбор или образует озеро")

	var before_slide := _total_height(world)
	_apply(state, "оползень", Vector2(36.5, 30.5), 8.0, 0.8, 0.65)
	_check(absf(_total_height(world) - before_slide) < 0.01,
		"Оползень переносит породу без создания массы")

	var second: Dictionary = _apply(
		state, "просадка", Vector2(49.0, 31.5), 6.0, 1.8, 0.9)
	_check(int(second.get("trees_felled", 0)) >= 1,
		"Второе событие повреждает лес на уже изменённом рельефе")
	_check(nature.object_at(core_id)["state"] == "пень"
		and int(nature.object_at(core_id)["fallen_wood"]) == 12
		and int(nature.object_at(outer_id)["fallen_wood"]) == 18,
		"Последовательные деформации не дублируют лежащую древесину")
	_check(nature.wood_total() == starting_wood,
		"Полный запас древесины сохранился после нескольких событий")
	_check(nature.object_at(far_id) == far_before,
		"Незатронутые объекты в дальнем чанке не повреждены")

	# Должна обновиться базовая порода, но конечные физические
	# слои наносов, снега, влаги и заболачивания не пропадают.
	_check(absf(surface._sediment[index] - 0.035) < 0.0000001
		and absf(surface.sediment_balance() - 0.035) < 0.0000001,
		"После трёх воздействий нет потери учтённых наносов")
	_check(absf(surface._snow[index] - 0.4) < 0.0000001
		and absf(surface._moisture[index] - 0.66) < 0.0000001
		and absf(surface._waterlogged[index] - 0.3) < 0.0000001,
		"Накопленные снег и вода не обнуляются при пересчёте породы")
	var fresh := Surface.new(world, hydro)
	fresh.rebuild()
	for cell in [core, outer, Vector2i(48, 33)]:
		var i: int = hydro.cell_index(cell)
		_check(surface.substrate_at_index(i) == fresh.substrate_at_index(i)
			and absf(surface._depth[i] - fresh._depth[i]) < 0.00001,
			"Геология после серии ударов совпадает с чистым пересчётом")

	# Неправильное событие не должно менять ни ресурс, ни сток,
	# ни ревизию. Не разрешаем подделывать воздействия на лес.
	var saved_state: Dictionary = nature.to_data()
	var saved_geometry: Dictionary = world.to_data()
	var old_revision: int = world.revision
	var invalid: Dictionary = Landscape.new(world).apply(
		"кратер", Vector2(1.5, 1.5), 8.0, 2.0)
	_check(invalid.is_empty() and world.revision == old_revision
		and world.to_data() == saved_geometry
		and nature.to_data() == saved_state,
		"Отвергнутая деформация оставляет весь мир без изменений")
	_check(not state["runner"].synchronize_world(),
		"Без изменённых вершин не выполняется лишний пересчёт")

	# Проверяем глобальную маршрутизацию по данным свежей модели.
	var reference := Hydro.new(world)
	_check(reference.load_snapshot(hydro.to_snapshot()),
		"Водосбор можно восстановить из реальных осадков и высот")
	_check(reference._downstream == hydro._downstream
		and reference._ground == hydro._ground,
		"Локальная пересборка согласована с полным Priority-Flood")
	return state


func _save_and_continue(state: Dictionary) -> Dictionary:
	# WorldSave хранит все модели одним атомарным снимком.
	# После загрузки обе независимые симуляции продолжают календарь
	# с одинаковыми ресурсами, водосбором и геометрией.
	var snapshot: Dictionary = Save.capture(state)
	_check(not snapshot.is_empty(), "Комплексный физический мир сохранён")
	if snapshot.is_empty():
		return {}
	var parsed: Variant = JSON.parse_string(JSON.stringify(snapshot))
	_check(parsed is Dictionary, "Полное сохранение сериализуется в JSON")
	if not (parsed is Dictionary):
		return {}
	var restored: Dictionary = Save.restore(parsed)
	_check(not restored.is_empty(), "Составной мир восстановлен")
	if restored.is_empty():
		return {}
	_check(restored["world"].to_data() == state["world"].to_data()
		and restored["nature"].to_data() == state["nature"].to_data()
		and restored["surface"].to_snapshot() == state["surface"].to_snapshot()
		and restored["hydro"].to_snapshot() == state["hydro"].to_snapshot(),
		"Геометрия, лес, снег, наносы и вода вернулись без потерь")
	var corrupt: Dictionary = parsed.duplicate(true)
	corrupt["hydrology"]["world_signature"] = "посторонняя карта"
	_check(Save.restore(corrupt).is_empty(),
		"Повреждённая подпись гидрологии отклоняется")

	for day in range(2, 6):
		state["runner"].run_day()
		restored["runner"].run_day()
		_check(state["climate"].day == day
			and restored["climate"].day == day,
			"Оба мира вычисляют правильный следующий день")
		_check(state["world"].to_data() == restored["world"].to_data()
			and state["nature"].to_data() == restored["nature"].to_data()
			and state["hydro"].to_snapshot() == restored["hydro"].to_snapshot()
			and state["surface"].to_snapshot() == restored["surface"].to_snapshot(),
			"Повторный суточный расчёт после сохранения детерминирован")
	_check(state["runner"].natural_disasters.advance_day(5).is_empty(),
		"Сохранённое геологическое событие не проигрывается дважды")
	return state["world"].to_data()


func _slow_slide_contract() -> void:
	# Медленный физический оползень раньше не передавался в события
	# леса. Проверяем именно объединяющий контракт Runner, а не
	# повторяем данные от NaturalDisasters в его собственном реестре.
	var state: Dictionary = _models(2411)
	var world: RefCounted = state["world"]
	var nature: RefCounted = state["nature"]
	var source := Vector2i(42, 30)
	var old := nature.object_at(source.y * world.config.width + source.x + 1)
	var none: Array[Dictionary] = []
	_check(Runner.nature_hazards(none, {
		"kind": "оползень", "process": "slide",
		"cell": source, "vertices": 0, "severity": 1.0
	}).is_empty(), "Неудавшаяся геологическая правка не вредит лесу")
	_check(Runner.nature_hazards(none, {
		"kind": "водная эрозия", "process": "water",
		"cell": source, "vertices": 2, "severity": 1.0
	}).is_empty(), "Мелкие речные наносы не выдаются за оползень")
	var impact: Dictionary = Landscape.new(world).apply(
		"оползень", CENTER, 8.0, 0.8)
	_check(not impact.is_empty(), "Медленный оползень реально деформировал склон")
	var hazards: Array[Dictionary] = Runner.nature_hazards(none, {
		"kind": "оползень", "process": "slide",
		"cell": source, "vertices": impact.get("vertices", 0),
		"severity": 1.0, "day": 2
	})
	_check(hazards.size() == 1, "Деформация NaturalProcesses передана природе")
	_check(state["climate"].set_day(2), "Климат продолжил календарь")
	_check(state["surface"].advance_climate_day(state["climate"]),
		"Грунт согласован с новым днём")
	_check(state["runner"].synchronize_world(), "Оползень согласован с водой")
	var strikes: Array[Dictionary] = []
	nature.advance_day(2, hazards, strikes)
	var id: int = int(old["id"])
	_check(nature.object_at(id)["state"] == "пень",
		"Медленный оползень способен повалить дерево")
	_check(nature.wood_total() >= 0
		and int(nature.object_at(id)["fallen_wood"]) == 12,
		"Реальная древесина одного дерева перенесена без дублирования")
	var after: Dictionary = nature.to_data()
	_check(nature.advance_day(2, hazards, strikes) == 0
		and after == nature.to_data(),
		"Повторное применение того же игрового дня запрещено")


func _rockfall_calendar() -> void:
	# Специальный уступ гарантирует реальный риск для даты 13.
	# Без включения 13 в check_slopes весь этот риск был нулевым.
	var world := Map.new(Config.new(32, 32, 4471, 16, 32))
	var heights := {}
	for y in range(33):
		for x in range(33):
			heights[Vector2i(x, y)] = 35.0 \
				- clampf(float(x - 12) * 3.0, 0.0, 30.0)
	_check(world.apply_vertex_changes(heights), "Контрольный скальный уступ создан")
	world.take_dirty_chunks()
	var hydro := Hydro.new(world)
	hydro.rebuild()
	var surface := Surface.new(world, hydro)
	surface.rebuild()
	var climate := Climate.new(world, hydro)
	climate.rebuild()
	var disasters := Disasters.new(world, hydro, surface, climate)
	for day in range(1, 14):
		_check(climate.set_day(day), "Климат принимает день скального обвала")
		_check(surface.advance_climate_day(climate),
			"Грунт обновляет день скального обвала")
		hydro.apply_rainfall_map(surface.runoff_map())
	var rockfall: Dictionary = disasters._candidates(Vector2i.ZERO, true)["обвал"]
	_check(float(rockfall["score"]) >= 0.52,
		"На скальном уступе действительно есть опасность обвала")
	var before: int = world.revision
	var events: Array[Dictionary] = disasters.advance_day(13)
	var found := false
	for event in events:
		if event["kind"] == "обвал":
			found = true
			_check(int(event["vertices"]) > 0
				and world.revision == before + 1,
				"Обвал на 13-й день изменил физические вершины")
	_check(found, "Естественный обвал не пропущен календарём")
	_check(disasters.advance_day(13).is_empty(),
		"Один геологический день не выполняется дважды")


func _initialize() -> void:
	# Два мира с одним seed должны совпасть после всей цепочки
	# воздействий, восстановления и нескольких игровых суток.
	var first: Dictionary = _sequence(1729)
	var second: Dictionary = _sequence(1729)
	_check(first["world"].to_data() == second["world"].to_data()
		and first["nature"].to_data() == second["nature"].to_data(),
		"Одинаковый seed воспроизводит весь геологический цикл")
	_save_and_continue(first)
	_slow_slide_contract()
	_rockfall_calendar()
	if not failures.is_empty():
		for reason in failures:
			push_error("11.7/RF3: " + reason)
		quit(1)
		return
	print("11.7/RF3: цепочки воздействий, водосбор, грунты, ресурсы и JSON — успешно.")
	quit(0)
