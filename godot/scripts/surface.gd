extends RefCounted
## Физическая поверхность: субстрат, почва и изменяемые вода, снег и промерзание.
## Не зависит от камеры, цвета меша и устаревшего climate.gd.

signal surface_changed(revision: int)

const Terrain = preload("res://scripts/terrain.gd")
const Climate = preload("res://scripts/climate.gd")
const FORMAT_VERSION := 3
const SEDIMENT_UNITS := 1000000.0
const ROCK := 0
const GRAVEL := 1
const SAND := 2
const CLAY := 3
const LOAM := 4
const NAMES := ["скала", "щебень", "песок", "глина", "суглинок"]

var world: RefCounted
var hydro: RefCounted
var day := 0
var revision := 0
var temperature := 12.0
var precipitation := 0.0
var _terrain_revision := -1
var _type := PackedByteArray()
var _depth := PackedFloat32Array()
var _fertility := PackedFloat32Array()
var _porosity := PackedFloat32Array()
var _moisture := PackedFloat32Array()
var _snow := PackedFloat32Array()
var _frost := PackedFloat32Array()
var _air_temperature := PackedFloat32Array()
var _runoff := PackedFloat32Array()
var _sediment := PackedFloat32Array()
var _sediment_balance := 0.0
var snow_coverage := 0.0


func _init(map: RefCounted, hydrology: RefCounted) -> void:
	world = map
	hydro = hydrology


static func _geology_field(x: int, y: int, seed: int) -> float:
	# Осадочные области распределены плавно, без случайной клетки-глины
	# посреди независимого песчаного региона.
	var fx := float(x) / 46.0
	var fy := float(y) / 46.0
	var gx := floori(fx)
	var gy := floori(fy)
	var u := smoothstep(0.0, 1.0, fx - float(gx))
	var v := smoothstep(0.0, 1.0, fy - float(gy))
	var north := lerpf(Terrain.hash2(gx, gy, seed + 7201),
		Terrain.hash2(gx + 1, gy, seed + 7201), u)
	var south := lerpf(Terrain.hash2(gx, gy + 1, seed + 7201),
		Terrain.hash2(gx + 1, gy + 1, seed + 7201), u)
	return lerpf(north, south, v)


func _index(cell: Vector2i) -> int:
	if not world.config.contains_cell(cell):
		return -1
	return cell.y * world.config.width + cell.x


func ensure_ready() -> void:
	if _terrain_revision != world.revision \
			or _type.size() != world.config.width * world.config.height:
		rebuild()


func rebuild(affected_chunks: Array[Vector2i] = []) -> void:
	# Геология пересчитывается, но снег и влага вне зоны воздействия остаются.
	hydro.ensure_ready()
	var count: int = world.config.width * world.config.height
	var preserve := _type.size() == count and _terrain_revision >= 0 \
		and not affected_chunks.is_empty()
	# При локальной деформации обрабатываем лишь затронутые чанки.
	# Сезонный покров и накопленные наносы не пересоздаются.
	var affected := PackedByteArray()
	affected.resize(count)
	if preserve:
		for chunk in affected_chunks:
			var bounds: Rect2i = world.config.chunk_rect(chunk)
			for y in range(bounds.position.y, bounds.end.y):
				for x in range(bounds.position.x, bounds.end.x):
					affected[y * world.config.width + x] = 1
	_type.resize(count)
	_depth.resize(count)
	_fertility.resize(count)
	_porosity.resize(count)
	_moisture.resize(count)
	_snow.resize(count)
	_frost.resize(count)
	_air_temperature.resize(count)
	_runoff.resize(count)
	_sediment.resize(count)
	if not preserve:
		_air_temperature.fill(12.0)
		_runoff.fill(0.0)
		_snow.fill(0.0)
		_frost.fill(0.0)
		_sediment.fill(0.0)
		_sediment_balance = 0.0
	for y in range(world.config.height):
		for x in range(world.config.width):
			var i: int = y * world.config.width + x
			if preserve and affected[i] == 0:
				continue
			var a: float = world.vertex_at(Vector2i(x, y))
			var b: float = world.vertex_at(Vector2i(x + 1, y))
			var c: float = world.vertex_at(Vector2i(x, y + 1))
			var d: float = world.vertex_at(Vector2i(x + 1, y + 1))
			var height: float = (a + b + c + d) * 0.25
			var slope: float = Vector2((b + d - a - c) * 0.5,
				(c + d - a - b) * 0.5).length()
			var area: float = _geology_field(x, y, world.config.seed)
			var detail: float = Terrain.hash2(x, y, world.config.seed + 7202)
			var kind := LOAM
			if slope > 1.75 or (height > 7.5 and area > 0.42):
				kind = ROCK
			elif slope > 0.95 or (height > 4.0 and area > 0.72):
				kind = GRAVEL
			elif hydro.wetness_at(i) > 0.65 and slope < 0.3:
				# Тонкодисперсные отложения на мокрых плоских участках.
				kind = CLAY
			elif area < 0.30 and hydro.wetness_at(i) < 0.45:
				kind = SAND
			elif area > 0.72:
				kind = CLAY
			_type[i] = kind
			_depth[i] = 0.0 if kind == ROCK else clampf(
				1.7 - slope * 0.56 - maxf(0.0, height - 4.0) * 0.11
				+ (detail - 0.5) * 0.38, 0.08, 2.5)
			var base_fertility: float = [0.0, 0.18, 0.28, 0.57, 0.70][kind]
			_fertility[i] = clampf(base_fertility * minf(1.0,
				_depth[i] / 0.7) + (detail - 0.5) * 0.12, 0.0, 1.0)
			_porosity[i] = [0.03, 0.72, 0.84, 0.27, 0.56][kind]
			_moisture[i] = 1.0 if hydro.has_water(i) else clampf(
				0.18 + hydro.wetness_at(i) * 0.48 + detail * 0.12, 0.0, 1.0)
			if preserve:
				# Пересчёт породы не означает новый игровой день.
				_moisture[i] = 1.0 if hydro.has_water(i) else _moisture[i]
	_terrain_revision = world.revision
	_update_snow_coverage()
	revision += 1
	surface_changed.emit(revision)


func synchronize_climate(climate: RefCounted) -> void:
	# После изменения рельефа обновляем температуру без нового игрового дня.
	ensure_ready()
	for i in range(_air_temperature.size()):
		var air: float = climate.temperature_at_index(i)
		_air_temperature[i] = air
	# Смена рельефа сама по себе не переключает снег или лёд.
	# Снежный покров меняется только во время физического шага.
	revision += 1
	surface_changed.emit(revision)


func _apply_weather(i: int, rain: float, air: float) -> void:
	_air_temperature[i] = air
	var snow_share: float = Climate.snowfall_fraction(air)
	var snowfall: float = rain * snow_share
	var liquid: float = rain - snowfall
	var melt := 0.0
	if air <= 0.0:
		_snow[i] = clampf(_snow[i] + snowfall * 0.18, 0.0, 1.0)
		_frost[i] = clampf(_frost[i] + 0.15 + absf(air) * 0.012, 0.0, 1.0)
	else:
		# Снег тает по дням; +30 °C ускоряет процесс, но не удаляет
		# накопленный покров мгновенно при смене календарного сезона.
		melt = minf(_snow[i], 0.025 + air * 0.008)
		_snow[i] -= melt
		_frost[i] = maxf(0.0, _frost[i] - 0.03 - air * 0.009)
		if snow_share > 0.0:
			_snow[i] = clampf(_snow[i] + snowfall * 0.18, 0.0, 1.0)
	var infiltration := liquid * (0.11 + _porosity[i] * 0.21) \
		* (1.0 - _frost[i] * 0.70)
	var evaporation: float = 0.018 + maxf(0.0, air) * 0.0035
	var floor_wetness: float = 0.10 + hydro.wetness_at(i) * 0.33
	_moisture[i] = 1.0 if hydro.has_water(i) else clampf(
		maxf(_moisture[i], floor_wetness) + infiltration + melt * 0.52
		- evaporation, 0.0, 1.0)
	# Снег не поступает сразу в реки: сток увеличивается при оттепели.
	_runoff[i] = clampf(liquid + melt * 0.65, 0.0, 3.0)


func _update_snow_coverage() -> void:
	if _snow.is_empty():
		snow_coverage = 0.0
		return
	var snow_cells := 0
	for amount in _snow:
		if amount > 0.12:
			snow_cells += 1
	snow_coverage = float(snow_cells) / float(_snow.size())


func runoff_map() -> PackedFloat32Array:
	return _runoff.duplicate()


func runoff_at_index(index: int) -> float:
	return _runoff[index] if index >= 0 and index < _runoff.size() else 0.0


func transfer_sediment(source: Vector2i, target: Vector2i,
		amount: float) -> bool:
	# Две вершины меняются атомарно, а происхождение наносов хранится
	# отдельно от базовой геологии и самого физического рельефа.
	ensure_ready()
	if not world.config.contains_cell(source) or not world.config.contains_cell(target):
		return false
	if source == target or not is_finite(amount) or amount < 0.0005 or amount > 0.05:
		return false
	var a := _index(source)
	var b := _index(target)
	if _depth[a] + _sediment[a] < amount + 0.01:
		return false
	var source_height: float = world.vertex_at(source)
	var target_height: float = world.vertex_at(target)
	if not world.apply_vertex_changes({
			source: source_height - amount, target: target_height + amount}):
		return false
	# Подписчики WorldMap уже могли перестроить Surface в этом же вызове.
	# Дополнительно обработаем случай изолированного теста без подписчика.
	if _terrain_revision != world.revision:
		var chunks: Array[Vector2i] = [world.config.chunk_of(source)]
		var target_chunk: Vector2i = world.config.chunk_of(target)
		if not chunks.has(target_chunk):
			chunks.append(target_chunk)
		rebuild(chunks)
	_sediment[a] -= amount
	_sediment[b] += amount
	revision += 1
	surface_changed.emit(revision)
	return true


func sediment_balance() -> float:
	ensure_ready()
	# Баланс кэшируется: HUD не обходит десятки тысяч клеток.
	return _sediment_balance


func sediment_color_at(cell: Vector2i) -> Color:
	ensure_ready()
	var i := _index(cell)
	if i < 0:
		return Color.DARK_GRAY
	var amount: float = _sediment[i]
	var base := Color(0.42, 0.42, 0.43)
	if amount > 0.0:
		return base.lerp(Color(0.93, 0.73, 0.38),
			clampf(amount / 0.05, 0.0, 1.0))
	return base.lerp(Color(0.29, 0.25, 0.21),
		clampf(-amount / 0.05, 0.0, 1.0))


func snow_color_at(cell: Vector2i) -> Color:
	# Отдельный обзорный слой показывает постепенное наступление зимы.
	ensure_ready()
	var i := _index(cell)
	if i < 0:
		return Color.DARK_GRAY
	var base := Color(0.23, 0.31, 0.26)
	if hydro.has_water(i):
		base = Color(0.16, 0.37, 0.55).lerp(
			Color(0.66, 0.80, 0.89), _frost[i])
	return base.lerp(Color(0.94, 0.96, 0.98), _snow[i])

func advance_day(rain: float, air_temperature: float) -> bool:
	# Ручной режим оставлен для изолированных тестов этапа 4.
	if not is_finite(rain) or rain < 0.0 or rain > 3.0:
		return false
	if not is_finite(air_temperature) or air_temperature < -60.0 or air_temperature > 60.0:
		return false
	ensure_ready()
	precipitation = rain
	temperature = air_temperature
	for i in range(_type.size()):
		_apply_weather(i, rain, air_temperature)
	day += 1
	_update_snow_coverage()
	revision += 1
	surface_changed.emit(revision)
	return true


func advance_climate_day(climate: RefCounted) -> bool:
	# Климат задаёт местные условия каждой клетки, а не температуру всей карты.
	ensure_ready()
	if climate.day != day + 1:
		return false
	var total_rain := 0.0
	var total_temperature := 0.0
	for i in range(_type.size()):
		var rain: float = climate.precipitation_at_index(i)
		var air: float = climate.temperature_at_index(i)
		if not is_finite(rain) or not is_finite(air):
			return false
		_apply_weather(i, rain, air)
		total_rain += rain
		total_temperature += air
	day = climate.day
	precipitation = total_rain / float(_type.size())
	temperature = total_temperature / float(_type.size())
	_update_snow_coverage()
	revision += 1
	surface_changed.emit(revision)
	return true

func profile_at(cell: Vector2i) -> Dictionary:
	ensure_ready()
	var i := _index(cell)
	if i < 0:
		return {}
	var wet: float = _moisture[i]
	var frozen: bool = _frost[i] > 0.55
	var muddy: bool = (_type[i] == CLAY or _type[i] == LOAM) \
		and wet > 0.67 and not frozen and not hydro.has_water(i)
	var cover := "голый грунт"
	if hydro.has_water(i):
		cover = "лёд" if frozen else "вода"
	elif _snow[i] > 0.12:
		cover = "снег"
	elif _type[i] == ROCK:
		cover = "скала"
	elif muddy:
		cover = "грязь"
	elif wet < 0.24:
		cover = "сухая поверхность"

	var thermal := clampf((_air_temperature[i] + 6.0) / 13.0, 0.0, 1.0) \
		* clampf((46.0 - _air_temperature[i]) / 13.0, 0.0, 1.0)
	var depth := maxf(0.0, _depth[i] + _sediment[i])
	var fertility := clampf(_fertility[i] + maxf(0.0, _sediment[i]) * 0.16,
		0.0, 1.0)
	var growth := fertility * clampf((wet - 0.12) * 1.8, 0.0, 1.0) * thermal
	return {
		"cell": cell, "substrate": NAMES[_type[i]], "depth": depth,
		"base_depth": _depth[i], "sediment": _sediment[i],
		"fertility": fertility, "porosity": _porosity[i],
		"moisture": wet, "snow": _snow[i], "frost": _frost[i],
		"muddy": muddy, "cover": cover, "temperature": _air_temperature[i],
		"growth_potential": growth,
		"erosion_risk": clampf((1.0 - depth / 2.5)
			* (0.25 + wet * 0.5), 0.0, 1.0)
	}


func color_at(cell: Vector2i, mode: int = 0) -> Color:
	ensure_ready()
	var i := _index(cell)
	if i < 0:
		return Color.DARK_GRAY
	if mode == 1:
		return Color(0.57, 0.43, 0.25).lerp(Color(0.11, 0.41, 0.74), _moisture[i])
	var palette := [
		Color(0.40, 0.43, 0.47), Color(0.52, 0.50, 0.46),
		Color(0.73, 0.64, 0.42), Color(0.42, 0.31, 0.26),
		Color(0.40, 0.36, 0.26)
	]
	var color: Color = palette[_type[i]]
	color = color.lerp(Color(0.25, 0.22, 0.17), _moisture[i] * 0.38)
	if _frost[i] > 0.55:
		color = color.lerp(Color(0.69, 0.75, 0.78), _frost[i] * 0.28)
	if _sediment[i] > 0.001:
		color = color.lerp(Color(0.74, 0.59, 0.37),
			clampf(_sediment[i] * 9.0, 0.0, 0.55))
	if _snow[i] > 0.0:
		color = color.lerp(Color(0.91, 0.94, 0.96), _snow[i])
	return color


func to_data() -> Dictionary:
	ensure_ready()
	var water := PackedByteArray()
	var snow := PackedByteArray()
	var frozen := PackedByteArray()
	var air := PackedByteArray()
	air.resize(_type.size())
	water.resize(_type.size())
	snow.resize(_type.size())
	frozen.resize(_type.size())
	for i in range(_type.size()):
		water[i] = roundi(_moisture[i] * 255.0)
		snow[i] = roundi(_snow[i] * 255.0)
		frozen[i] = roundi(_frost[i] * 255.0)
		air[i] = clampi(roundi((_air_temperature[i] + 60.0) / 120.0 * 255.0), 0, 255)
	var sediment_changes := []
	for i in range(_sediment.size()):
		var units := roundi(_sediment[i] * SEDIMENT_UNITS)
		if units != 0:
			sediment_changes.append([i, units])
	return {
		"version": FORMAT_VERSION, "world_signature": JSON.stringify(world.to_data()),
		"sediment_changes": sediment_changes,
		"day": day, "temperature": temperature, "precipitation": precipitation,
		"moisture": Marshalls.raw_to_base64(water),
		"snow": Marshalls.raw_to_base64(snow),
		"frost": Marshalls.raw_to_base64(frozen),
		"air_temperature": Marshalls.raw_to_base64(air)
	}


func load_data(data: Dictionary) -> bool:
	ensure_ready()
	var raw_version = data.get("version")
	if not (raw_version is int or raw_version is float):
		return false
	var version := int(raw_version)
	if float(version) != float(raw_version) \
			or (version != 2 and version != FORMAT_VERSION) \
			or data.get("world_signature") != JSON.stringify(world.to_data()):
		return false
	var sediment_changes: Array = []
	if version == FORMAT_VERSION:
		if not (data.get("sediment_changes") is Array):
			return false
		sediment_changes = data["sediment_changes"]
	if sediment_changes.size() > _type.size():
		return false
	var loaded_sediment := PackedFloat32Array()
	loaded_sediment.resize(_type.size())
	var loaded_balance := 0.0
	var occupied := {}
	for raw in sediment_changes:
		if not (raw is Array) or raw.size() != 2:
			return false
		if not (raw[0] is int or raw[0] is float) \
				or not (raw[1] is int or raw[1] is float):
			return false
		var raw_index := float(raw[0])
		var raw_units := float(raw[1])
		if not is_finite(raw_index) or not is_finite(raw_units) \
				or raw_index != float(int(raw_index)) \
				or raw_units != float(int(raw_units)):
			return false
		var index := int(raw_index)
		var units := int(raw_units)
		if index < 0 or index >= _type.size() or occupied.has(index):
			return false
		if abs(units) > 100000000:
			return false
		occupied[index] = true
		loaded_sediment[index] = float(units) / SEDIMENT_UNITS
		loaded_balance += loaded_sediment[index]
	if not (data.get("day") is int or data.get("day") is float):
		return false
	var saved_day: float = float(data["day"])
	if not is_finite(saved_day) or saved_day < 0.0 or saved_day != float(int(saved_day)):
		return false
	if not (data.get("temperature") is float or data.get("temperature") is int) \
			or not (data.get("precipitation") is float or data.get("precipitation") is int):
		return false
	var temp: float = float(data["temperature"])
	var rain: float = float(data["precipitation"])
	if not is_finite(temp) or temp < -60.0 or temp > 60.0 \
			or not is_finite(rain) or rain < 0.0 or rain > 3.0:
		return false
	for field in ["moisture", "snow", "frost", "air_temperature"]:
		if not (data.get(field) is String):
			return false
	var water: PackedByteArray = Marshalls.base64_to_raw(data["moisture"])
	var snow: PackedByteArray = Marshalls.base64_to_raw(data["snow"])
	var frozen: PackedByteArray = Marshalls.base64_to_raw(data["frost"])
	var air: PackedByteArray = Marshalls.base64_to_raw(data["air_temperature"])
	if water.size() != _type.size() or snow.size() != _type.size() \
			or frozen.size() != _type.size() or air.size() != _type.size():
		return false
	for i in range(_type.size()):
		_moisture[i] = float(water[i]) / 255.0
		_snow[i] = float(snow[i]) / 255.0
		_frost[i] = float(frozen[i]) / 255.0
		_air_temperature[i] = float(air[i]) / 255.0 * 120.0 - 60.0
	_sediment = loaded_sediment
	_sediment_balance = loaded_balance
	day = int(data["day"])
	temperature = temp
	precipitation = rain
	_update_snow_coverage()
	revision += 1
	surface_changed.emit(revision)
	return true
