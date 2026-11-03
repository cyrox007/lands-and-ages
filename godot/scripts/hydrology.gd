extends RefCounted
## Гидрология поверх физического WorldMap: бассейны, сток, реки и озёра.
## Очерёдность обхода фиксирована, вода не определяет высоту грунта.

signal water_changed(revision: int)

const Boundary = preload("res://scripts/world_boundary.gd")
const RIVER_THRESHOLD := 180.0
const LAKE_THRESHOLD := 0.06
const FLOOD_START := 0.95
const MAX_FLOOD_STEPS := 2
const DIRECTIONS := [
	Vector2i(-1, 0), Vector2i(0, -1),
	Vector2i(1, 0), Vector2i(0, 1)
]

var world: RefCounted
var rainfall := 1.0
var revision := 0
var ocean_revision := 0
var full_rebuilds := 0
var flow_updates := 0
var last_ground_cells := 0
var _geometry_dirty := {}
var last_changed_chunks: Array[Vector2i] = []
var _pending_changed_chunks := {}
var _terrain_revision := -1
var _width := 0
var _height := 0
var _ground := PackedFloat32Array()
var _spill := PackedFloat32Array()
var _downstream := PackedInt32Array()
var _outlet := PackedInt32Array()
var _order := PackedInt32Array()
var _rank := PackedInt32Array()
var _catchment := PackedFloat32Array()
var _discharge := PackedFloat32Array()
var _local_rain := PackedFloat32Array()
var _river := PackedByteArray()
var _ocean := PackedByteArray()
var _lake := PackedByteArray()
var _flood := PackedByteArray()
var _water_level := PackedFloat32Array()
var _wetness := PackedFloat32Array()
var _heap: Array[int] = []
var _summary := {"lakes": 0, "rivers": 0, "flooded": 0, "ocean": 0}


func _init(source: RefCounted) -> void:
	world = source
	# Отдельный журнал изменений высот живёт до полной перестройки стока.
	# Графическая очередь может очищаться независимо от гидрологии.
	world.vertices_changed.connect(_on_vertices_changed)


func _on_vertices_changed(chunks: Array[Vector2i], _revision: int) -> void:
	for chunk in chunks:
		_geometry_dirty[chunk] = true


func cell_index(cell: Vector2i) -> int:
	if not world.config.contains_cell(cell):
		return -1
	return cell.y * world.config.width + cell.x


func cell_from_index(index: int) -> Vector2i:
	if index < 0 or index >= _width * _height:
		return Vector2i(-1, -1)
	return Vector2i(index % _width, index / _width)


func _precedes(a: int, b: int) -> bool:
	if _spill[a] == _spill[b]:
		return a < b
	return _spill[a] < _spill[b]


func _push(index: int) -> void:
	_heap.append(index)
	var pos := _heap.size() - 1
	while pos > 0:
		var parent := (pos - 1) / 2
		if not _precedes(index, _heap[parent]):
			break
		_heap[pos] = _heap[parent]
		pos = parent
	_heap[pos] = index


func _pop() -> int:
	var first := _heap[0]
	var last: int = _heap.pop_back()
	if _heap.is_empty():
		return first
	var pos := 0
	var count := _heap.size()
	while 2 * pos + 1 < count:
		var child := 2 * pos + 1
		if child + 1 < count and _precedes(_heap[child + 1], _heap[child]):
			child += 1
		if not _precedes(_heap[child], last):
			break
		_heap[pos] = _heap[child]
		pos = child
	_heap[pos] = last
	return first


func _seed_border(index: int, visited: PackedByteArray) -> void:
	if visited[index] != 0:
		return
	visited[index] = 1
	_spill[index] = _ground[index]
	_outlet[index] = index
	_push(index)


func rebuild() -> void:
	var previous_ocean := _ocean.duplicate()
	var previous_lake := _lake.duplicate()
	var previous_river := _river.duplicate()
	var previous_wetness := _wetness.duplicate()
	var previous_level := _water_level.duplicate()
	full_rebuilds += 1
	_width = world.config.width
	_height = world.config.height
	var count := _width * _height
	var partial_ground := _terrain_revision >= 0 \
		and _ground.size() == count and not _geometry_dirty.is_empty()
	_ground.resize(count)
	last_ground_cells = 0
	_spill.resize(count)
	_downstream.resize(count)
	_downstream.fill(-1)
	_outlet.resize(count)
	_outlet.fill(-1)
	_rank.resize(count)
	_catchment.resize(count)
	_catchment.fill(1.0)
	_order.clear()
	_heap.clear()
	var visited := PackedByteArray()
	visited.resize(count)

	# Меняем высоты только в соседних с деформацией чанках.
	# Сам Priority-Flood остаётся глобальным: водоразделы могут сдвинуться далеко.
	if partial_ground:
		for chunk in _geometry_dirty.keys():
			var bounds: Rect2i = world.config.chunk_rect(chunk)
			for y in range(bounds.position.y, bounds.end.y):
				for x in range(bounds.position.x, bounds.end.x):
					_ground[y * _width + x] = world.height_at(
						Vector2(float(x) + 0.5, float(y) + 0.5))
					last_ground_cells += 1
	else:
		for y in range(_height):
			for x in range(_width):
				_ground[y * _width + x] = world.height_at(
					Vector2(float(x) + 0.5, float(y) + 0.5))
		last_ground_cells = count
	_geometry_dirty.clear()

	# Priority-flood: внешняя граница — выходы водосбора.
	# Каждая вновь открытая клетка связывается с уже извлечённой из очереди.
	for x in range(_width):
		_seed_border(x, visited)
		_seed_border((_height - 1) * _width + x, visited)
	for y in range(_height):
		_seed_border(y * _width, visited)
		_seed_border(y * _width + _width - 1, visited)

	while not _heap.is_empty():
		var current := _pop()
		_rank[current] = _order.size()
		_order.append(current)
		var cx := current % _width
		var cy := current / _width
		for offset in DIRECTIONS:
			var nx: int = cx + offset.x
			var ny: int = cy + offset.y
			if nx < 0 or ny < 0 or nx >= _width or ny >= _height:
				continue
			var next: int = ny * _width + nx
			if visited[next] != 0:
				continue
			visited[next] = 1
			_spill[next] = maxf(_ground[next], _spill[current])
			_downstream[next] = current
			_outlet[next] = _outlet[current]
			_push(next)

	# Порядок обхода даёт DAG даже на совершенно плоских участках.
	# Площадь водосбора течёт строго от более позднего узла к раннему.
	for step in range(_order.size() - 1, -1, -1):
		var current := _order[step]
		var lower := _downstream[current]
		if lower >= 0:
			_catchment[lower] += _catchment[current]

	_terrain_revision = world.revision
	if _local_rain.size() != count:
		_local_rain.clear()
	_recalculate_flow()
	_mark_ocean()
	if previous_ocean != _ocean:
		ocean_revision += 1
	_recalculate_water()
	# Даже маленькая правка рельефа может перенаправить реку далеко.
	# Сообщаем Surface все изменённые водные чанки, а не только место удара.
	last_changed_chunks.clear()
	if previous_wetness.size() == count:
		var dirty := {}
		for i in range(count):
			var had_water: bool = not is_nan(previous_level[i])
			var has_water_now: bool = not is_nan(_water_level[i])
			if had_water != has_water_now \
					or previous_ocean[i] != _ocean[i] \
					or previous_lake[i] != _lake[i] \
					or previous_river[i] != _river[i] \
					or not is_equal_approx(previous_wetness[i], _wetness[i]):
				var cell := Vector2i(i % _width, i / _width)
				dirty[world.config.chunk_of(cell)] = true
		for chunk in dirty.keys():
			last_changed_chunks.append(chunk)
			_pending_changed_chunks[chunk] = true
	revision += 1
	water_changed.emit(revision)


func take_changed_water_chunks() -> Array[Vector2i]:
	# Если физические события запросили гидрологию несколько раз за
	# сутки, все удалённые изменения воды дойдут до грунтов.
	var result: Array[Vector2i] = []
	for chunk in _pending_changed_chunks.keys():
		result.append(chunk)
	_pending_changed_chunks.clear()
	return result


func ensure_ready() -> void:
	if _terrain_revision != world.revision or _ground.size() != world.config.width * world.config.height:
		rebuild()


func set_rainfall(value: float) -> bool:
	if not is_finite(value) or value < 0.0 or value > 3.0:
		return false
	if is_equal_approx(value, rainfall) and _local_rain.is_empty():
		return false
	rainfall = value
	_local_rain.clear()
	ensure_ready()
	_recalculate_flow()
	_recalculate_water()
	revision += 1
	water_changed.emit(revision)
	return true


func apply_rainfall_map(values: PackedFloat32Array) -> bool:
	# Пространственные осадки питают водосборы; геометрия русел не меняется.
	ensure_ready()
	if values.size() != _ground.size():
		return false
	var total := 0.0
	for amount in values:
		if not is_finite(amount) or amount < 0.0 or amount > 3.0:
			return false
		total += amount
	_local_rain = values.duplicate()
	rainfall = total / float(values.size())
	_recalculate_flow()
	_recalculate_water()
	revision += 1
	water_changed.emit(revision)
	return true


func _recalculate_flow() -> void:
	flow_updates += 1
	_discharge.resize(_catchment.size())
	if _local_rain.is_empty():
		for i in range(_discharge.size()):
			_discharge[i] = _catchment[i] * rainfall
		return
	for i in range(_discharge.size()):
		# При отсутствии дождя реки не исчезают за одни сутки:
		# постоянный грунтовый приток — упрощение до модели подземных вод.
		_discharge[i] = 0.55 + _local_rain[i]
	for step in range(_order.size() - 1, -1, -1):
		var i: int = _order[step]
		var lower: int = _downstream[i]
		if lower >= 0:
			_discharge[lower] += _discharge[i]


func _mark_ocean() -> void:
	_ocean.resize(_ground.size())
	_ocean.fill(0)
	# Море заполняет только отрицательные отметки, связанные с краем.
	var queue: Array[int] = []
	for y in range(_height):
		for x in range(_width):
			if x > 0 and y > 0 and x < _width - 1 and y < _height - 1:
				continue
			var i := y * _width + x
			if _ground[i] < Boundary.SEA_LEVEL:
				_ocean[i] = 1
				queue.append(i)
	var cursor := 0
	while cursor < queue.size():
		var current := queue[cursor]
		cursor += 1
		var x := current % _width
		var y := current / _width
		for offset in DIRECTIONS:
			var nx: int = x + offset.x
			var ny: int = y + offset.y
			if nx < 0 or ny < 0 or nx >= _width or ny >= _height:
				continue
			var next: int = ny * _width + nx
			if _ocean[next] != 0 or _ground[next] >= Boundary.SEA_LEVEL:
				continue
			_ocean[next] = 1
			queue.append(next)


func _recalculate_water() -> void:
	var count := _width * _height
	_river.resize(count)
	_river.fill(0)
	_lake.resize(count)
	_lake.fill(0)
	_flood.resize(count)
	_flood.fill(0)
	_water_level.resize(count)
	_water_level.fill(NAN)
	_wetness.resize(count)
	_wetness.fill(clampf(rainfall * 0.15, 0.0, 1.0))
	if not _local_rain.is_empty():
		for i in range(count):
			_wetness[i] = clampf(_local_rain[i] * 0.25, 0.0, 1.0)

	var sources: Array[int] = []
	var flood_sources: Array[int] = []
	for i in range(count):
		if _ocean[i] != 0:
			_water_level[i] = Boundary.SEA_LEVEL
			_wetness[i] = 1.0
			sources.append(i)
			continue
		var lake_depth := _spill[i] - _ground[i]
		var is_lake := lake_depth > LAKE_THRESHOLD
		var is_river := _discharge[i] >= RIVER_THRESHOLD
		if not is_lake and not is_river:
			continue
		_lake[i] = int(is_lake)
		_river[i] = int(is_river)
		# Уровень зависит от реальных осадков всего водосбора,
		# а не среднего дождя по карте, который скрывал ливни.
		var pressure := _discharge[i] / maxf(1.0, _catchment[i])
		var pulse := clampf((pressure - FLOOD_START) / 1.30, 0.0, 1.0)
		_water_level[i] = _spill[i] + 0.04 + pulse * 0.72
		_wetness[i] = 1.0
		if pulse > 0.13:
			flood_sources.append(i)

	# Разлив распространяется только от реального водного источника.
	# За два шага по пойме он не перепрыгивает через высокий берег.
	if not flood_sources.is_empty():
		var distance := PackedByteArray()
		distance.resize(count)
		distance.fill(255)
		for index in flood_sources:
			distance[index] = 0
		var cursor := 0
		while cursor < flood_sources.size():
			var current := flood_sources[cursor]
			cursor += 1
			if distance[current] >= MAX_FLOOD_STEPS:
				continue
			var x := current % _width
			var y := current / _width
			for offset in DIRECTIONS:
				var nx: int = x + offset.x
				var ny: int = y + offset.y
				if nx < 0 or ny < 0 or nx >= _width or ny >= _height:
					continue
				var near: int = ny * _width + nx
				if _ocean[near] != 0:
					continue
				var level := _water_level[current] - 0.025
				if _ground[near] >= level - 0.01:
					continue
				if is_nan(_water_level[near]) or level > _water_level[near]:
					_water_level[near] = level
				if _lake[near] == 0 and _river[near] == 0:
					_flood[near] = 1
				if distance[near] > distance[current] + 1:
					distance[near] = distance[current] + 1
					flood_sources.append(near)

	# Счётчики вычисляются при изменении водного режима, а не каждый кадр.
	var lakes := 0
	var rivers := 0
	var floods := 0
	var ocean := 0
	for i in range(count):
		lakes += int(_lake[i] != 0)
		rivers += int(_river[i] != 0 and _lake[i] == 0)
		floods += int(_flood[i] != 0)
		ocean += int(_ocean[i] != 0)
	_summary = {"lakes": lakes, "rivers": rivers, "flooded": floods, "ocean": ocean}

	# Влажность здесь — признак соседства воды, а не свойства почвы.
	for i in range(count):
		if not is_nan(_water_level[i]):
			continue
		var x := i % _width
		var y := i / _width
		for offset in DIRECTIONS:
			var nx: int = x + offset.x
			var ny: int = y + offset.y
			if nx < 0 or ny < 0 or nx >= _width or ny >= _height:
				continue
			if not is_nan(_water_level[ny * _width + nx]):
				_wetness[i] = maxf(_wetness[i], 0.72)
				break


func water_at(cell: Vector2i) -> Dictionary:
	ensure_ready()
	var i := cell_index(cell)
	if i < 0:
		return {}
	var surface := _water_level[i]
	return {
		"cell": cell,
		"ground": _ground[i],
		"spill": _spill[i],
		"downstream": cell_from_index(_downstream[i]),
		"outlet": cell_from_index(_outlet[i]),
		"order": _rank[i],
		"catchment": _catchment[i],
		"discharge": _discharge[i],
		"lake": _lake[i] != 0,
		"river": _river[i] != 0,
		"ocean": _ocean[i] != 0,
		"flooded": _flood[i] != 0,
		"water_level": surface if not is_nan(surface) else null,
		"depth": maxf(0.0, surface - _ground[i]) if not is_nan(surface) else 0.0,
		"wetness": _wetness[i]
	}


func has_water(index: int) -> bool:
	return index >= 0 and index < _water_level.size() and not is_nan(_water_level[index])


func wetness_at(index: int) -> float:
	if index < 0 or index >= _wetness.size():
		return 0.0
	return _wetness[index]


func ocean_at(index: int) -> bool:
	return index >= 0 and index < _ocean.size() and _ocean[index] != 0


func lake_at(index: int) -> bool:
	return index >= 0 and index < _lake.size() and _lake[index] != 0


func river_at(index: int) -> bool:
	return index >= 0 and index < _river.size() and _river[index] != 0


func level_at(index: int) -> float:
	if not has_water(index):
		return NAN
	return _water_level[index]


func flood_depth_at(index: int) -> float:
	ensure_ready()
	if index < 0 or index >= _flood.size() or _flood[index] == 0:
		return 0.0
	return maxf(0.0, _water_level[index] - _ground[index])


func flow_pressure_at(index: int) -> float:
	ensure_ready()
	if index < 0 or index >= _discharge.size():
		return 0.0
	return _discharge[index] / maxf(1.0, _catchment[index])


func river_mouth_at(index: int) -> bool:
	ensure_ready()
	if index < 0 or index >= _downstream.size() or _river[index] == 0:
		return false
	var next := _downstream[index]
	return next >= 0 and _ocean[next] != 0


func downstream_of(index: int) -> int:
	if index < 0 or index >= _downstream.size():
		return -1
	return _downstream[index]


func outlet_count() -> int:
	ensure_ready()
	var result := 0
	for i in range(_downstream.size()):
		if _downstream[i] == -1:
			result += 1
	return result


func water_count() -> Dictionary:
	ensure_ready()
	return _summary.duplicate()


func to_data() -> Dictionary:
	# Потоки, озёра и бассейны восстанавливаются из seed и состояния вершин.
	return {"version": 1, "rainfall": rainfall, "world_revision": world.revision}


func load_data(data: Dictionary) -> bool:
	if data.get("version") != 1 or not (data.get("rainfall") is float or data.get("rainfall") is int):
		return false
	var value := float(data["rainfall"])
	if not is_finite(value) or value < 0.0 or value > 3.0:
		return false
	rainfall = value
	rebuild()
	return true
