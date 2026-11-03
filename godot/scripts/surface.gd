extends RefCounted
## Физическая поверхность: субстрат, почва и изменяемые вода, снег и промерзание.
## Не зависит от камеры, цвета меша и устаревшего climate.gd.

signal surface_changed(revision: int)

const Terrain = preload("res://scripts/terrain.gd")
const FORMAT_VERSION := 2
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


func _init(map: RefCounted, hydrology: RefCounted) -> void:
	world = map
	hydro = hydrology


func _index(cell: Vector2i) -> int:
	if not world.config.contains_cell(cell):
		return -1
	return cell.y * world.config.width + cell.x


func ensure_ready() -> void:
	if _terrain_revision != world.revision \
			or _type.size() != world.config.width * world.config.height:
		rebuild()


func rebuild() -> void:
	# После изменения геометрии пересчитываем породы; временные слои сбрасываются.
	hydro.ensure_ready()
	var count: int = world.config.width * world.config.height
	_type.resize(count)
	_depth.resize(count)
	_fertility.resize(count)
	_porosity.resize(count)
	_moisture.resize(count)
	_snow.resize(count)
	_frost.resize(count)
	_air_temperature.resize(count)
	_air_temperature.fill(12.0)
	_snow.fill(0.0)
	_frost.fill(0.0)
	for y in range(world.config.height):
		for x in range(world.config.width):
			var i: int = y * world.config.width + x
			var a: float = world.vertex_at(Vector2i(x, y))
			var b: float = world.vertex_at(Vector2i(x + 1, y))
			var c: float = world.vertex_at(Vector2i(x, y + 1))
			var d: float = world.vertex_at(Vector2i(x + 1, y + 1))
			var height: float = (a + b + c + d) * 0.25
			var slope: float = Vector2((b + d - a - c) * 0.5,
				(c + d - a - b) * 0.5).length()
			var area: float = Terrain.hash2(floori(float(x) / 18.0),
				floori(float(y) / 18.0), world.config.seed + 7201)
			var detail: float = Terrain.hash2(x, y, world.config.seed + 7202)
			var kind := LOAM
			if slope > 1.75 or (height > 7.5 and area > 0.42):
				kind = ROCK
			elif slope > 0.95 or (height > 4.0 and area > 0.72):
				kind = GRAVEL
			elif area < 0.26:
				kind = SAND
			elif area > 0.70:
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
	_terrain_revision = world.revision
	revision += 1
	surface_changed.emit(revision)


func _apply_weather(i: int, rain: float, air: float) -> void:
	_air_temperature[i] = air
	var melt := 0.0
	if air <= 0.0:
		_snow[i] = clampf(_snow[i] + rain * 0.18, 0.0, 1.0)
		_frost[i] = clampf(_frost[i] + 0.15 + absf(air) * 0.012, 0.0, 1.0)
	else:
		melt = minf(_snow[i], air * 0.075)
		_snow[i] -= melt
		_frost[i] = maxf(0.0, _frost[i] - 0.12 - air * 0.035)
		if air >= 18.0:
			# Суточный шаг: при сильной жаре остаточный снег и лёд невозможны.
			_snow[i] = 0.0
			_frost[i] = 0.0
	var infiltration: float = rain * (0.11 + _porosity[i] * 0.21) \
		* (1.0 - _frost[i] * 0.70) if air > 0.0 else 0.0
	var evaporation: float = 0.018 + maxf(0.0, air) * 0.0035
	var floor_wetness: float = 0.10 + hydro.wetness_at(i) * 0.33
	_moisture[i] = 1.0 if hydro.has_water(i) else clampf(
		maxf(_moisture[i], floor_wetness) + infiltration + melt * 0.52
		- evaporation, 0.0, 1.0)


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
	var growth := _fertility[i] * clampf((wet - 0.12) * 1.8, 0.0, 1.0) * thermal
	return {
		"cell": cell, "substrate": NAMES[_type[i]], "depth": _depth[i],
		"fertility": _fertility[i], "porosity": _porosity[i],
		"moisture": wet, "snow": _snow[i], "frost": _frost[i],
		"muddy": muddy, "cover": cover, "temperature": _air_temperature[i],
		"growth_potential": growth,
		"erosion_risk": clampf((1.0 - _depth[i] / 2.5)
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
	if _snow[i] > 0.12:
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
	return {
		"version": FORMAT_VERSION, "world_signature": JSON.stringify(world.to_data()),
		"day": day, "temperature": temperature, "precipitation": precipitation,
		"moisture": Marshalls.raw_to_base64(water),
		"snow": Marshalls.raw_to_base64(snow),
		"frost": Marshalls.raw_to_base64(frozen),
		"air_temperature": Marshalls.raw_to_base64(air)
	}


func load_data(data: Dictionary) -> bool:
	ensure_ready()
	if data.get("version") != FORMAT_VERSION \
			or data.get("world_signature") != JSON.stringify(world.to_data()):
		return false
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
	day = int(data["day"])
	temperature = temp
	precipitation = rain
	revision += 1
	surface_changed.emit(revision)
	return true
