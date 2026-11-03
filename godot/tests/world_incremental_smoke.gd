extends SceneTree
## Этап 6.6: проверка локальности и точного совпадения с полным расчётом.

const Config = preload("res://scripts/world_config.gd")
const Map = preload("res://scripts/world_map.gd")
const Hydrology = preload("res://scripts/hydrology.gd")
const Climate = preload("res://scripts/climate.gd")
const Surface = preload("res://scripts/surface.gd")
const View = preload("res://scripts/world.gd")

var failures: Array[String] = []


func _check(valid: bool, reason: String) -> void:
	if not valid:
		failures.append(reason)


func _make_state(width: int, height: int, seed: int) -> Dictionary:
	var map := Map.new(Config.new(width, height, seed, 16, 32))
	var hydro := Hydrology.new(map)
	hydro.rebuild()
	var surface := Surface.new(map, hydro)
	surface.rebuild()
	var climate := Climate.new(map, hydro)
	climate.rebuild()
	climate.set_day(1)
	surface.advance_climate_day(climate)
	hydro.apply_rainfall_map(surface.runoff_map())
	return {
		"map": map, "hydro": hydro,
		"climate": climate, "surface": surface
	}


func _safe_cell(state: Dictionary) -> Vector2i:
	var map: RefCounted = state["map"]
	var hydro: RefCounted = state["hydro"]
	for y in range(18, map.config.height - 18):
		for x in range(18, map.config.width - 18):
			var cell := Vector2i(x, y)
			if not hydro.has_water(hydro.cell_index(cell)) \
					and map.vertex_at(cell) > 2.0:
				return cell
	return Vector2i(-1, -1)


func _compare(a: Dictionary, b: Dictionary) -> void:
	var map: RefCounted = a["map"]
	for y in range(map.config.height):
		for x in range(map.config.width):
			var cell := Vector2i(x, y)
			var wa: Dictionary = a["climate"].weather_at(cell)
			var wb: Dictionary = b["climate"].weather_at(cell)
			for key in ["temperature", "annual_temperature", "humidity",
					"precipitation", "wind_speed", "storm_intensity",
					"marine_influence"]:
				_check(absf(float(wa[key]) - float(wb[key])) < 0.00001,
					"Локальный климат совпадает с полным: %s" % key)
			var sa: Dictionary = a["surface"].profile_at(cell)
			var sb: Dictionary = b["surface"].profile_at(cell)
			for key in ["depth", "moisture", "snow", "frost",
					"waterlogging", "fertility"]:
				_check(absf(float(sa[key]) - float(sb[key])) < 0.00001,
					"Локальная поверхность совпадает с полной: %s" % key)
			_check(sa["substrate"] == sb["substrate"],
				"В изменённых водосборах сохраняется та же порода")


func _incremental_and_reference() -> void:
	var a := _make_state(128, 96, 1729)
	var b := _make_state(128, 96, 1729)
	var map: RefCounted = a["map"]
	var cell: Vector2i = _safe_cell(a)
	_check(cell.x >= 0, "На карте найден устойчивый сухопутный участок")
	if cell.x < 0:
		return
	var before: float = map.vertex_at(cell)
	_check(a["map"].set_vertex(cell, before + 0.05),
		"Небольшая правка рельефа принята в рабочем мире")
	_check(b["map"].set_vertex(cell, before + 0.05),
		"Та же правка принята в эталонном мире")

	var start_partial := Time.get_ticks_usec()
	a["hydro"].ensure_ready()
	var dirty: Array[Vector2i] = a["map"].take_dirty_chunks()
	for chunk in a["hydro"].last_changed_chunks:
		if not dirty.has(chunk):
			dirty.append(chunk)
	a["climate"].rebuild(dirty)
	a["surface"].rebuild(dirty)
	a["surface"].synchronize_climate(a["climate"],
		a["climate"].last_updated_rows)
	var elapsed_partial := Time.get_ticks_usec() - start_partial

	var start_full := Time.get_ticks_usec()
	b["hydro"].ensure_ready()
	b["climate"].rebuild()
	b["surface"].rebuild()
	b["surface"].synchronize_climate(b["climate"])
	var elapsed_full := Time.get_ticks_usec() - start_full

	_check(a["climate"].partial_rebuilds == 1,
		"Если морская связность сохранена, климат считает только строки")
	_check(a["surface"].partial_rebuilds == 1,
		"Малый ландшафтный пакет не пересчитывает все грунты")
	_check(a["surface"].last_rebuilt_cells < 128 * 96,
		"Число рассчитанных клеток меньше размера мира")
	_check(a["climate"].last_rebuild_rows < 96,
		"Число рассчитанных строк климата меньше высоты мира")
	_check(a["hydro"].full_rebuilds == 2,
		"Речной водосбор перестраивается ровно один раз для изменения")
	_compare(a, b)
	print("Этап 6.6, 128×96: локально=", elapsed_partial,
		" мкс, полный расчёт=", elapsed_full,
		" мкс, почва=", a["surface"].last_rebuilt_cells,
		" клеток, климат=", a["climate"].last_rebuild_rows, " строк")


func _ocean_fallback() -> void:
	var map := Map.new(Config.new(24, 24, 9102, 8, 16))
	var flat := {}
	for y in range(25):
		for x in range(25):
			flat[Vector2i(x, y)] = 3.0
	_check(map.apply_vertex_changes(flat), "Подготовлена суша без моря")
	map.take_dirty_chunks()
	var hydro := Hydrology.new(map)
	hydro.rebuild()
	var climate := Climate.new(map, hydro)
	climate.rebuild()
	var before: int = hydro.ocean_revision
	var shore := {
		Vector2i(0, 0): -2.0,
		Vector2i(0, 1): -2.0,
		Vector2i(1, 0): -2.0,
		Vector2i(1, 1): -2.0
	}
	_check(map.apply_vertex_changes(shore), "Физически создано новое море")
	var chunks: Array[Vector2i] = map.take_dirty_chunks()
	hydro.ensure_ready()
	_check(hydro.ocean_revision > before,
		"Топология морской связи имеет отдельную ревизию")
	climate.rebuild(chunks)
	_check(climate.full_rebuilds == 2 and climate.partial_rebuilds == 0,
		"Изменение береговой линии включает полный перерасчёт морского климата")
	_check(hydro.ocean_at(hydro.cell_index(Vector2i(0, 0))),
		"Новая вода действительно связана с краем карты")


func _batch_and_render_queue() -> void:
	var state := _make_state(64, 48, 321)
	var map: RefCounted = state["map"]
	var hydro: RefCounted = state["hydro"]
	var view := View.new()
	view._world_model = map
	view._hydro = hydro
	view._climate = state["climate"]
	view._surface = state["surface"]
	view._center = Vector2(31, 24)
	view._refresh_visible(true)
	var initial := view._pending.size()
	_check(initial > 0, "Камера поставила видимые чанки в очередь")
	var visible: Vector2i = view._pending[0]
	var placeholder := Node3D.new()
	view._active[visible] = placeholder
	view._refresh_visible(true)
	view._refresh_visible(true)
	_check(view._active.has(visible) and view._active[visible] == placeholder,
		"Видимый чанк не удаляется до построения замены")
	_check(view._pending.size() == initial,
		"Повторная инвалидизация не создаёт дублей GPU-чанков")
	var p := Vector2i(19, 20)
	var q := Vector2i(27, 24)
	map.vertices_changed.connect(view._on_world_changed)
	_check(map.set_vertex(p, map.vertex_at(p) + 0.04), "Первое изменение принято")
	_check(map.set_vertex(q, map.vertex_at(q) + 0.04), "Второе изменение принято")
	_check(view._terrain_dirty.size() >= 1, "Деформации накапливаются")
	var builds: int = hydro.full_rebuilds
	view._flush_world_changes()
	_check(hydro.full_rebuilds == builds + 1,
		"Несколько правок объединены в один полный пересчёт водосбора")
	_check(view._terrain_dirty.is_empty(),
		"После обработки очередь физических правок очищена")
	_check(view._pending.size() == initial,
		"GPU-очередь не дублируется при нескольких событиях")
	placeholder.free()
	view.free()


func _weather_does_not_change_rock() -> void:
	var state := _make_state(32, 32, 581)
	var map: RefCounted = state["map"]
	var hydro: RefCounted = state["hydro"]
	var surface: RefCounted = state["surface"]
	var climate: RefCounted = state["climate"]
	var original := {}
	for y in range(map.config.height):
		for x in range(map.config.width):
			var cell := Vector2i(x, y)
			original[cell] = surface.profile_at(cell)["substrate"]
	for day in range(2, 8):
		climate.set_day(day)
		surface.advance_climate_day(climate)
		hydro.apply_rainfall_map(surface.runoff_map())
	var dry_cell := Vector2i(-1, -1)
	for y in range(map.config.height):
		for x in range(map.config.width):
			var cell := Vector2i(x, y)
			if not hydro.has_water(hydro.cell_index(cell)):
				dry_cell = cell
				break
		if dry_cell.x >= 0:
			break
	_check(dry_cell.x >= 0, "Существует суша для проверки накопленной влаги")
	if dry_cell.x < 0:
		return
	var wet: float = surface.profile_at(dry_cell)["moisture"]
	surface.rebuild()
	for y in range(map.config.height):
		for x in range(map.config.width):
			var cell := Vector2i(x, y)
			_check(surface.profile_at(cell)["substrate"] == original[cell],
				"Дождь не превращает геологическую основу в другую породу")
	_check(absf(float(surface.profile_at(dry_cell)["moisture"]) - wet) < 0.00001,
		"Геологический пересчёт сохраняет историю влажности")


func _initialize() -> void:
	_incremental_and_reference()
	_ocean_fallback()
	_batch_and_render_queue()
	_weather_does_not_change_rock()
	if not failures.is_empty():
		for failure in failures.slice(0, 20):
			push_error("Этап 6.6: " + failure)
		print("Ошибок локальной приёмки: ", failures.size())
		quit(1)
		return
	print("Этап 6.6: локальные грунты, климат, водосбор и GPU-очередь — успешно.")
	quit(0)
