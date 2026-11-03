extends RefCounted
## Климат — непрерывные поля температуры и влаги поверх единого мира.
## Биом вытекает из среднего климата, воды и грунта, а не выбирается случайно.

signal weather_changed(day: int)

const Terrain = preload("res://scripts/terrain.gd")
const SEASON_DAYS := 24
const YEAR_DAYS := 96
const SEASONS := ["весна", "лето", "осень", "зима"]
const FORMAT_VERSION := 1
const WIND_STEP := 0.28
const DIRECTIONS := [
	Vector2i(-1, 0), Vector2i(1, 0),
	Vector2i(0, -1), Vector2i(0, 1)
]

var world: RefCounted
var hydro: RefCounted
var day := 0
var revision := 0
var _terrain_revision := -1
var _width := 0
var _height := 0
var _mean := PackedFloat32Array()
var _humidity := PackedFloat32Array()
var _altitude := PackedFloat32Array()
var _marine := PackedFloat32Array()
var _temperature := PackedFloat32Array()
var _rain := PackedFloat32Array()


func _init(map: RefCounted, water: RefCounted) -> void:
	world = map
	hydro = water


static func season_name(index: int) -> String:
	return SEASONS[posmod(index / SEASON_DAYS, SEASONS.size())]


static func _smooth_noise(x: float, y: float, seed: int) -> float:
	var x0 := floori(x)
	var y0 := floori(y)
	var u := smoothstep(0.0, 1.0, x - float(x0))
	var v := smoothstep(0.0, 1.0, y - float(y0))
	var a := lerpf(Terrain.hash2(x0, y0, seed),
		Terrain.hash2(x0 + 1, y0, seed), u)
	var b := lerpf(Terrain.hash2(x0, y0 + 1, seed),
		Terrain.hash2(x0 + 1, y0 + 1, seed), u)
	return lerpf(a, b, v) * 2.0 - 1.0


func _index(cell: Vector2i) -> int:
	if not world.config.contains_cell(cell):
		return -1
	return cell.y * world.config.width + cell.x


func ensure_ready() -> void:
	if _terrain_revision != world.revision or _width != world.config.width \
			or _height != world.config.height:
		rebuild()


func rebuild() -> void:
	hydro.ensure_ready()
	_width = world.config.width
	_height = world.config.height
	var count := _width * _height
	_mean.resize(count)
	_humidity.resize(count)
	_altitude.resize(count)
	_marine.resize(count)
	_temperature.resize(count)
	_rain.resize(count)

	# Морское влияние распространяется от фактического моря по клеткам,
	# а не выбирается по случайным прямоугольным регионам.
	var distance := PackedInt32Array()
	distance.resize(count)
	distance.fill(999999)
	var queue: Array[int] = []
	for i in range(count):
		if hydro.ocean_at(i):
			distance[i] = 0
			queue.append(i)
	var pointer := 0
	while pointer < queue.size():
		var current: int = queue[pointer]
		pointer += 1
		var x: int = current % _width
		var y: int = current / _width
		for direction in DIRECTIONS:
			var nx: int = x + direction.x
			var ny: int = y + direction.y
			if nx < 0 or ny < 0 or nx >= _width or ny >= _height:
				continue
			var next: int = ny * _width + nx
			if distance[next] > distance[current] + 1:
				distance[next] = distance[current] + 1
				queue.append(next)

	# Преобладающий западный ветер: наветренные склоны получают влагу,
	# а за протяжёнными хребтами возникает плавная дождевая тень.
	for y in range(_height):
		var peak := -100.0
		var previous := 0.0
		for x in range(_width):
			var i := y * _width + x
			var height: float = world.height_at(Vector2(x + 0.5, y + 0.5))
			_altitude[i] = height
			var latitude := (float(y) + 0.5) / float(_height)
			var marine := exp(-float(distance[i]) / 42.0)
			_marine[i] = marine
			var relief_shadow := clampf((peak - height - 1.0) * 0.065, 0.0, 0.38)
			var windward := clampf((height - previous) * 0.018, 0.0, 0.12)
			var broad := _smooth_noise(x / 90.0, y / 90.0, world.config.seed + 314)
			_mean[i] = lerpf(-9.0, 27.0, latitude) \
				- maxf(0.0, height) * 0.78 + broad * 1.8
			_humidity[i] = clampf(0.45 + marine * 0.40 \
				- (1.0 - marine) * 0.24 * latitude \
				- relief_shadow + windward + broad * 0.055, 0.05, 0.97)
			peak = maxf(height, peak - WIND_STEP)
			previous = height
	_terrain_revision = world.revision
	_calculate_day()


func _calculate_day() -> void:
	# Волны медленно перемещаются в пространстве, а не выпадают из
	# независимого генератора для каждой клетки.
	for y in range(_height):
		var latitude := (float(y) + 0.5) / float(_height)
		for x in range(_width):
			var i := y * _width + x
			var season := sin(TAU * float(day) / float(YEAR_DAYS))
			var amplitude := lerpf(13.0, 6.0, latitude) * \
				(1.0 - _marine[i] * 0.28)
			var front := _smooth_noise((float(x) + float(day) * 1.8) / 55.0,
				(float(y) - float(day) * 0.65) / 49.0, world.config.seed + 990)
			var local := _smooth_noise((float(x) + float(day) * 0.7) / 38.0,
				(float(y) + float(day) * 0.4) / 38.0, world.config.seed + 991)
			_temperature[i] = _mean[i] + season * amplitude + front * 3.1
			var threshold := 0.11 - _humidity[i] * 0.20
			_rain[i] = clampf(maxf(0.0, local * 0.9 + front * 0.4 - threshold)
				* _humidity[i] * 2.5, 0.0, 3.0)
	revision += 1
	weather_changed.emit(day)


func set_day(next_day: int) -> bool:
	if next_day < 0 or next_day > 10000000:
		return false
	ensure_ready()
	day = next_day
	_calculate_day()
	return true


func temperature_at_index(i: int) -> float:
	return _temperature[i] if i >= 0 and i < _temperature.size() else NAN


func precipitation_at_index(i: int) -> float:
	return _rain[i] if i >= 0 and i < _rain.size() else 0.0


func rainfall_map() -> PackedFloat32Array:
	return _rain.duplicate()


func weather_at(cell: Vector2i) -> Dictionary:
	ensure_ready()
	var i := _index(cell)
	if i < 0:
		return {}
	var temp: float = _temperature[i]
	var rain: float = _rain[i]
	return {
		"temperature": temp,
		"annual_temperature": _mean[i],
		"humidity": _humidity[i],
		"precipitation": rain,
		"weather": ("снег" if temp <= 0.0 else "дождь") if rain > 0.08 else "без осадков",
		"season": season_name(day),
		"marine_influence": _marine[i]
	}


func biome_at(cell: Vector2i, surface: RefCounted = null) -> String:
	ensure_ready()
	var i := _index(cell)
	if i < 0:
		return "за пределами карты"
	if hydro.ocean_at(i):
		return "море"
	if hydro.has_water(i):
		return "пресный водоём"
	var temp: float = _mean[i]
	var wet: float = _humidity[i]
	var substrate := ""
	if surface != null:
		substrate = str(surface.profile_at(cell).get("substrate", ""))
	if _altitude[i] > 7.0 and temp < 5.0:
		return "высокогорье"
	if substrate == "скала" and temp < 2.0:
		return "скальные высоты"
	if temp < -12.0:
		return "полярная пустыня" if wet < 0.33 else "ледяная тундра"
	if temp < -4.0:
		return "тундра"
	if temp < 7.0:
		return "тайга" if wet > 0.45 else "холодная степь"
	if temp < 18.0:
		return "умеренный лес" if wet > 0.50 else "степь"
	if wet < 0.26:
		return "пустыня"
	if wet < 0.42:
		return "полупустыня"
	if wet < 0.58:
		return "саванна"
	return "влажный тёплый лес"


func color_at(cell: Vector2i, mode: int = 0) -> Color:
	ensure_ready()
	var i := _index(cell)
	if i < 0:
		return Color.DARK_GRAY
	if mode == 0:
		return Color(0.20, 0.42, 0.82).lerp(Color(0.95, 0.42, 0.15),
			clampf((_temperature[i] + 25.0) / 65.0, 0.0, 1.0))
	var aridity: float = _humidity[i]
	var color := Color(0.79, 0.64, 0.35).lerp(
		Color(0.17, 0.52, 0.30), clampf(aridity, 0.0, 1.0))
	var cold := clampf((-_mean[i] - 2.0) / 21.0, 0.0, 1.0)
	return color.lerp(Color(0.77, 0.82, 0.85), cold)


func to_data() -> Dictionary:
	ensure_ready()
	return {
		"version": FORMAT_VERSION,
		"world_signature": JSON.stringify(world.to_data()),
		"day": day
	}


func load_data(data: Dictionary) -> bool:
	if data.get("version") != FORMAT_VERSION \
			or data.get("world_signature") != JSON.stringify(world.to_data()):
		return false
	if not (data.get("day") is int or data.get("day") is float):
		return false
	var value := float(data["day"])
	if not is_finite(value) or value < 0.0 or value > 10000000.0 \
			or value != float(int(value)):
		return false
	return set_day(int(value))
