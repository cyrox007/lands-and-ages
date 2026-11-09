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
var _ocean_revision := -1
var full_rebuilds := 0
var partial_rebuilds := 0
var last_rebuild_rows := 0
var last_updated_rows: Array[int] = []
var _width := 0
var _height := 0
var _mean := PackedFloat32Array()
var _humidity := PackedFloat32Array()
var _altitude := PackedFloat32Array()
var _marine := PackedFloat32Array()
var _temperature := PackedFloat32Array()
var _rain := PackedFloat32Array()
var _wind := PackedFloat32Array()
var _storm := PackedFloat32Array()


func _init(map: RefCounted, water: RefCounted) -> void:
	world = map
	hydro = water


static func season_name(index: int) -> String:
	return SEASONS[posmod(int(float(index) / SEASON_DAYS), SEASONS.size())]


static func snowfall_fraction(air_temperature: float) -> float:
	# В околонулевом диапазоне возможны смешанные осадки.
	# При +2 °C и выше новых снеговых осадков нет.
	return 1.0 - smoothstep(-1.5, 2.0, air_temperature)


static func _seasonal_rain_factor(day_of_year: int, latitude: float) -> float:
	# В холодных широтах весна и осень влажнее лета и зимы.
	# К югу постепенно переходим к летнему дождливому сезону.
	var phase := TAU * float(day_of_year % YEAR_DAYS) / float(YEAR_DAYS)
	var temperate := 0.80 + 0.30 * cos(phase * 2.0)
	var southern := 0.84 + 0.43 * sin(phase)
	return lerpf(temperate, southern, smoothstep(0.25, 0.85, latitude))


static func _smooth_noise(x: float, y: float, world_seed: int) -> float:
	var x0 := floori(x)
	var y0 := floori(y)
	var u := smoothstep(0.0, 1.0, x - float(x0))
	var v := smoothstep(0.0, 1.0, y - float(y0))
	var a := lerpf(Terrain.hash2(x0, y0, world_seed),
		Terrain.hash2(x0 + 1, y0, world_seed), u)
	var b := lerpf(Terrain.hash2(x0, y0 + 1, world_seed),
		Terrain.hash2(x0 + 1, y0 + 1, world_seed), u)
	return lerpf(a, b, v) * 2.0 - 1.0


func _index(cell: Vector2i) -> int:
	if not world.config.contains_cell(cell):
		return -1
	return cell.y * world.config.width + cell.x


func ensure_ready() -> void:
	if _terrain_revision != world.revision or _width != world.config.width \
			or _height != world.config.height:
		rebuild()


func rebuild_if_stale(affected_chunks: Array[Vector2i] = []) -> bool:
	if _terrain_revision == world.revision:
		return false
	rebuild(affected_chunks)
	return true


func rebuild(affected_chunks: Array[Vector2i] = []) -> void:
	hydro.ensure_ready()
	# Морская связность не менялась: морское влияние сохранено.
	# Ветровая тень идёт с запада, поэтому обновляем целые строки,
	# а не только высоты непосредственно в изменённых чанках.
	var partial: bool = _terrain_revision >= 0 \
		and _width == world.config.width \
		and _height == world.config.height \
		and _ocean_revision == hydro.ocean_revision \
		and not affected_chunks.is_empty()
	if partial:
		var rows := {}
		for chunk in affected_chunks:
			var bounds: Rect2i = world.config.chunk_rect(chunk)
			for y in range(bounds.position.y, bounds.end.y):
				rows[y] = true
		if not rows.is_empty():
			last_updated_rows.clear()
			for y in rows.keys():
				_rebuild_row(y)
				last_updated_rows.append(y)
			_terrain_revision = world.revision
			partial_rebuilds += 1
			last_rebuild_rows = rows.size()
			_calculate_day(rows)
			return
	full_rebuilds += 1
	last_updated_rows.clear()
	_width = world.config.width
	_height = world.config.height
	var count := _width * _height
	_mean.resize(count)
	_humidity.resize(count)
	_altitude.resize(count)
	_marine.resize(count)
	_temperature.resize(count)
	_rain.resize(count)
	_wind.resize(count)
	_storm.resize(count)

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
		var y: int = int(float(current) / _width)
		for direction in DIRECTIONS:
			var nx: int = x + direction.x
			var ny: int = y + direction.y
			if nx < 0 or ny < 0 or nx >= _width or ny >= _height:
				continue
			var next: int = ny * _width + nx
			if distance[next] > distance[current] + 1:
				distance[next] = distance[current] + 1
				queue.append(next)

	for i in range(count):
		_marine[i] = exp(-float(distance[i]) / 42.0)
	for y in range(_height):
		_rebuild_row(y)
	_ocean_revision = hydro.ocean_revision
	last_rebuild_rows = _height
	_terrain_revision = world.revision
	_calculate_day()


# Дневная погода и геология используют единую формулу при полной
# и частичной перестройке, чтобы не возникали расхождения по seed.
func _rebuild_row(y: int) -> void:
	# Преобладающий западный ветер: наветренные склоны получают влагу,
	# а за протяжёнными хребтами возникает плавная дождевая тень.
	var peak := -100.0
	var previous := 0.0
	for x in range(_width):
		var i := y * _width + x
		var height: float = world.height_at(Vector2(x + 0.5, y + 0.5))
		_altitude[i] = height
		var latitude := (float(y) + 0.5) / float(_height)
		var marine: float = _marine[i]
		var relief_shadow := clampf((peak - height - 1.0) * 0.065, 0.0, 0.38)
		var windward := clampf((height - previous) * 0.018, 0.0, 0.12)
		var broad := _smooth_noise(x / 90.0, y / 90.0, world.config.world_seed + 314)
		_mean[i] = lerpf(-9.0, 27.0, latitude) \
			- maxf(0.0, height) * 0.78 + broad * 1.8
		# В тёплых удалённых от моря районах испаряемость выше,
		# поэтому образуются протяжённые засушливые внутренние области.
		var continental_dryness := 0.24 + 0.95 * smoothstep(
			0.35, 0.90, latitude)
		_humidity[i] = clampf(0.45 + marine * 0.40 \
			- (1.0 - marine) * continental_dryness * latitude \
			- relief_shadow + windward + broad * 0.055, 0.05, 0.97)
		peak = maxf(height, peak - WIND_STEP)
		previous = height



static func _noise_lattice(min_x: int, max_x: int, min_y: int,
		max_y: int, seed: int) -> PackedFloat64Array:
	# Сетка фронта намного реже клеток мира: в прямоугольнике
	# 256×192 требуется несколько десятков хешей, а не тысячи.
	# Точность float64 сохраняет исходные значения Terrain.hash2,
	# чтобы климат и WorldSave были побитово воспроизводимыми.
	var stride := max_x - min_x + 1
	var values := PackedFloat64Array()
	values.resize(stride * (max_y - min_y + 1))
	var index := 0
	for y in range(min_y, max_y + 1):
		for x in range(min_x, max_x + 1):
			values[index] = Terrain.hash2(x, y, seed)
			index += 1
	return values


static func _lattice_noise(x: float, y: float, values: PackedFloat64Array,
		min_x: int, min_y: int, stride: int) -> float:
	# Используем ту же гладкую интерполяцию, что _smooth_noise.
	# Меняется лишь источник четырёх угловых значений: хеш уже
	# был вычислен один раз для всех соседних клеток дня.
	var x0 := floori(x)
	var y0 := floori(y)
	var u := smoothstep(0.0, 1.0, x - float(x0))
	var v := smoothstep(0.0, 1.0, y - float(y0))
	var index := (y0 - min_y) * stride + x0 - min_x
	var a := lerpf(values[index], values[index + 1], u)
	var c := lerpf(values[index + stride], values[index + stride + 1], u)
	return lerpf(a, c, v) * 2.0 - 1.0


func _calculate_day(rows: Dictionary = {}) -> void:
	# Волны медленно перемещаются в пространстве, а не выпадают из
	# независимого генератора для каждой клетки.
	# День одинаков для всех клеток. Прежде сезонные sin() и
	# широтный множитель осадков пересчитывались десятки тысяч
	# раз на большой карте, хотя на данной широте они неизменны.
	# Убираем только повторы, сохраняя порядок формул каждой клетки.
	var season := sin(TAU * float(day % YEAR_DAYS) / float(YEAR_DAYS))
	var wind_season := 2.5 * absf(sin(TAU * float(day % YEAR_DAYS) / YEAR_DAYS))
	# Крупные и местные фронты сдвигаются ежедневно. Их опорные
	# узлы вычисляем один раз за день, но ни одну клетку не
	# заменяем ближайшим узлом: интерполяция остаётся точной.
	var front_x := float(day) * 1.8
	var front_y := -float(day) * 0.65
	var front_min_x := floori(front_x / 55.0)
	var front_min_y := floori(front_y / 49.0)
	var front_max_x := floori((float(_width - 1) + front_x) / 55.0) + 1
	var front_max_y := floori((float(_height - 1) + front_y) / 49.0) + 1
	var front_stride := front_max_x - front_min_x + 1
	var fronts := _noise_lattice(front_min_x, front_max_x,
		front_min_y, front_max_y, world.config.world_seed + 990)
	var local_x := float(day) * 0.7
	var local_y := float(day) * 0.4
	var local_min_x := floori(local_x / 38.0)
	var local_min_y := floori(local_y / 38.0)
	var local_max_x := floori((float(_width - 1) + local_x) / 38.0) + 1
	var local_max_y := floori((float(_height - 1) + local_y) / 38.0) + 1
	var local_stride := local_max_x - local_min_x + 1
	var locals := _noise_lattice(local_min_x, local_max_x,
		local_min_y, local_max_y, world.config.world_seed + 991)
	for y in range(_height):
		if not rows.is_empty() and not rows.has(y):
			continue
		var latitude := (float(y) + 0.5) / float(_height)
		# Фактор дождей общий для всех клеток одной широты.
		# Отдельные фронты по-прежнему вычисляются для каждой.
		var rain_factor := _seasonal_rain_factor(day, latitude)
		for x in range(_width):
			var i := y * _width + x
			var amplitude := lerpf(13.0, 6.0, latitude) * \
				(1.0 - _marine[i] * 0.28)
			var front := _lattice_noise((float(x) + float(day) * 1.8) / 55.0,
				(float(y) - float(day) * 0.65) / 49.0,
				fronts, front_min_x, front_min_y, front_stride)
			var local := _lattice_noise((float(x) + float(day) * 0.7) / 38.0,
				(float(y) + float(day) * 0.4) / 38.0,
				locals, local_min_x, local_min_y, local_stride)
			_temperature[i] = _mean[i] + season * amplitude + front * 3.1
			var threshold := 0.11 - _humidity[i] * 0.20
			# Тёплый влажный воздух поднимается вдоль погодного фронта:
			# возникает грозовая нестабильность, а не случайная молния.
			var convection := clampf((_temperature[i] - 7.0) / 17.0, 0.0, 1.0) \
				* clampf((_humidity[i] - 0.24) / 0.52, 0.0, 1.0)
			var frontal_lift := clampf(0.55 + front * 0.60
				+ local * 0.38, 0.0, 1.0)
			_storm[i] = clampf(convection * frontal_lift, 0.0, 1.0)
			# Ливень — усиление обычных осадков грозовым фронтом.
			_rain[i] = clampf(maxf(0.0, local * 0.9 + front * 0.4 - threshold)
				* _humidity[i] * 2.5 * rain_factor
				+ _storm[i] * 1.35, 0.0, 3.0)
			# Ветер связан с движущимися фронтами и широтами.
			# Скорость условная: шкалу м/с откалибруем позже.
			_wind[i] = clampf(5.0 + absf(front) * 10.0
				+ _storm[i] * 5.0 + maxf(0.0, -local) * 3.0
				+ wind_season
				+ _marine[i] * 1.5, 0.0, 24.0)
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


func wind_at_index(i: int) -> float:
	return _wind[i] if i >= 0 and i < _wind.size() else 0.0


func storm_at_index(i: int) -> float:
	return _storm[i] if i >= 0 and i < _storm.size() else 0.0


func wind_direction_at_index(i: int) -> Vector2:
	# Направление — текущий суточный поток В СТОРОНУ движения воздуха,
	# а не направление, откуда дует ветер. Оси совпадают с X/Y карты.
	# Макроклиматическая западная роза ветров остаётся базовой;
	# проходящие фронты плавно отклоняют поток даже до встречного.
	if i < 0 or i >= _wind.size() or _width <= 0:
		return Vector2.ZERO
	var x := float(i % _width)
	var y := float(floori(float(i) / float(_width)))
	var moving := _smooth_noise((x + float(day) * 1.1) / 72.0,
		(y - float(day) * 0.5) / 64.0, world.config.world_seed + 14141)
	var seasonal := sin(TAU * float(day % YEAR_DAYS) / float(YEAR_DAYS))
	var angle := moving * 1.70 + seasonal * 0.42
	return Vector2(cos(angle), sin(angle))


func wind_gust_at_index(i: int) -> float:
	# Порыв вычисляется из того же климатического дня, что и скорость:
	# у рендера нет собственного генератора ветра и собственного RNG.
	# Мелкая неоднородность фронта даёт порывы и вне сильной грозы.
	if i < 0 or i >= _wind.size() or _width <= 0:
		return 0.0
	var x := float(i % _width)
	var y := float(floori(float(i) / float(_width)))
	var turbulence := absf(_smooth_noise((x - float(day) * 1.7) / 28.0,
		(y + float(day) * 0.9) / 28.0, world.config.world_seed + 14142))
	var extra := (0.8 + 3.2 * _storm[i]) * (0.45 + turbulence)
	return clampf(_wind[i] + extra, _wind[i], 36.0)



func rainfall_map() -> PackedFloat32Array:
	return _rain.duplicate()


func weather_at(cell: Vector2i) -> Dictionary:
	ensure_ready()
	var i := _index(cell)
	if i < 0:
		return {}
	var temp: float = _temperature[i]
	var rain: float = _rain[i]
	var snow_share := snowfall_fraction(temp)
	var direction := wind_direction_at_index(i)
	return {
		"temperature": temp,
		"annual_temperature": _mean[i],
		"humidity": _humidity[i],
		"precipitation": rain, "wind_speed": _wind[i],
		"wind_gust": wind_gust_at_index(i),
		"wind_direction_x": direction.x, "wind_direction_y": direction.y,
		"storm_intensity": _storm[i], "downpour": rain >= 1.6,
		"rainfall": rain * (1.0 - snow_share),
		"snowfall": rain * snow_share,
		"weather": "гроза" if _storm[i] > 0.32 and rain > 0.14 else (
			"ливень" if rain >= 1.6 and temp > 2.0 else (
				("снег" if snow_share >= 0.75 else
				("мокрый снег" if snow_share > 0.15 else "дождь"))
				if rain > 0.08 else "без осадков")),
		"season": season_name(day),
		"seasonal_precipitation_factor": _seasonal_rain_factor(day,
			(float(cell.y) + 0.5) / float(_height)),
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
