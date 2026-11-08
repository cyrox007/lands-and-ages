extends RefCounted
## Стихийные события из состояния мира, а не случайных координат.
## Снег, наносы и геометрия меняются только через свои физические модели.

signal disaster_occurred(event: Dictionary)

const Terrain = preload("res://scripts/terrain.gd")
const Landscape = preload("res://scripts/landscape_events.gd")
const Climate = preload("res://scripts/climate.gd")
const FORMAT_VERSION := 2
const AIRBORNE_UNITS := 1000000.0
const MAX_AIRBORNE_PLUMES := 16
const AIRBORNE_LIFT_FRACTION := 0.22
const MAX_EVENTS_PER_DAY := 4
const SAMPLE_AXIS := 4
const DIRECTIONS := [
	Vector2i(-1, 0), Vector2i(1, 0),
	Vector2i(0, -1), Vector2i(0, 1)
]
const KINDS := ["шторм", "шквал", "ураган", "смерч", "пыльная буря", "паводок", "засуха", "лавина",
	"сель", "оползень", "обвал", "землетрясение"]

var world: RefCounted
var hydro: RefCounted
var surface: RefCounted
var climate: RefCounted
var last_day := 0
var total_events := 0
var last_events: Array[Dictionary] = []
var airborne_dust: Array[Dictionary] = []
var _storms := PackedInt32Array()
var _floods := PackedInt32Array()
var _droughts := PackedInt32Array()
var _strain := PackedFloat32Array()
var _fault_cache := {}
var _region_samples := {}


func _init(map: RefCounted, water: RefCounted,
		ground: RefCounted, weather: RefCounted) -> void:
	world = map
	hydro = water
	surface = ground
	climate = weather
	var region_count: Vector2i = world.config.region_count()
	var count := region_count.x * region_count.y
	_storms.resize(count)
	_floods.resize(count)
	_droughts.resize(count)
	_strain.resize(count)
	for i in range(count):
		# Накопление тектонического напряжения не зависит от осадков.
		_strain[i] = Terrain.hash2(i % region_count.x,
			floori(float(i) / float(region_count.x)),
			world.config.world_seed + 7513) * 0.65
	# Координаты выборки неизменны для данного размера карты.
	for ry in range(region_count.y):
		for rx in range(region_count.x):
			var region := Vector2i(rx, ry)
			var rect: Rect2i = world.config.region_rect(region)
			var cells: Array[Vector2i] = []
			for sy in range(SAMPLE_AXIS):
				for sx in range(SAMPLE_AXIS):
					cells.append(Vector2i(
						rect.position.x + mini(rect.size.x - 1,
							floori(float((sx * 2 + 1) * rect.size.x) /
								float(2 * SAMPLE_AXIS))),
						rect.position.y + mini(rect.size.y - 1,
							floori(float((sy * 2 + 1) * rect.size.y) /
								float(2 * SAMPLE_AXIS)))))
			_region_samples[region] = cells


func _downhill(cell: Vector2i) -> Vector2i:
	var lowest: Vector2i = Vector2i(-1, -1)
	var elevation: float = world.vertex_at(cell)
	for direction in DIRECTIONS:
		var near: Vector2i = cell + direction
		if not world.config.contains_cell(near):
			continue
		var height: float = world.vertex_at(near)
		if height < elevation:
			elevation = height
			lowest = near
	return lowest


func fault_risk_at(cell: Vector2i) -> float:
	if not world.config.contains_cell(cell):
		return 0.0
	if _fault_cache.has(cell):
		return float(_fault_cache[cell])
	# Непрерывные коридоры геологических разломов задаются seed.
	# Это упрощённая модель геологического напряжения, не тектоника плит.
	var field: float = Terrain._noise(
		(float(cell.x) + 37.0) / 140.0,
		(float(cell.y) + 19.0) / 140.0,
		world.config.world_seed + 4401)
	var risk := 1.0 - smoothstep(0.035, 0.28, absf(field))
	_fault_cache[cell] = risk
	return risk


func conditions_at(cell: Vector2i, include_slopes: bool = true) -> Dictionary:
	if not world.config.contains_cell(cell):
		return {}
	hydro.ensure_ready()
	surface.ensure_ready()
	climate.ensure_ready()
	var i: int = hydro.cell_index(cell)
	var moisture: float = surface.moisture_at_index(i)
	var snow: float = surface.snow_at_index(i)
	var air: float = climate.temperature_at_index(i)
	var liquid: float = climate.precipitation_at_index(i) \
		* (1.0 - Climate.snowfall_fraction(air))
	# Для опасного ветрового события важны порывы, а не только
	# средняя скорость: оба значения — физический климат суток.
	var wind: float = climate.wind_gust_at_index(i)
	var storm: float = climate.storm_at_index(i)
	var depth: float = surface.soil_depth_at_index(i)
	var rock: bool = surface.rock_at_index(i)
	var covered: bool = hydro.has_water(i)
	var target := Vector2i(-1, -1)
	var steep := 0.0
	var loose := 0.0
	if include_slopes:
		target = _downhill(cell)
		var drop := 0.0
		if target.x >= 0:
			drop = maxf(0.0, world.vertex_at(cell) - world.vertex_at(target))
		steep = clampf((drop - 0.65) / 2.25, 0.0, 1.0)
		loose = 0.0 if rock else clampf(depth / 1.2, 0.0, 1.0)

	var storm_risk := clampf((wind - 10.0) / 12.0, 0.0, 1.0) \
		* clampf(storm * 1.85, 0.0, 1.0)
	# Короткий шквал — отдельный порывистый фронт. Для него не нужна
	# трёхсуточная выдержка обычного шторма, но нужен высокий порыв.
	var squall_risk := clampf((wind - 16.0) / 13.0, 0.0, 1.0) * \
		clampf(0.55 + storm * 0.65, 0.0, 1.0)
	# Ураган требует одновременно сильного порывистого потока
	# и развитого грозового фронта. Продолжительность сверяем
	# по уже сохраняемой серии штормовых суток, без новой версии JSON.
	var hurricane_risk := clampf((wind - 19.0) / 10.0, 0.0, 1.0) * \
		clampf((storm - 0.52) / 0.45, 0.0, 1.0)
	# Смерч — редкий короткий вихрь на суше под мощным
	# конвективным фронтом. Порог не измерен в реальных м/с:
	# здесь используется условная физическая шкала Climate.
	var tornado_risk := clampf((wind - 20.0) / 10.0, 0.0, 1.0) * \
		clampf((storm - 0.65) / 0.30, 0.0, 1.0)
	if covered:
		tornado_risk = 0.0
	# Пыль поднимается над сухим открытым рыхлым грунтом.
	# Вода, снег и дождь гасят риск, даже при сильном порыве.
	var dust_risk := clampf((wind - 15.0) / 14.0, 0.0, 1.0) \
		* clampf((0.27 - moisture) / 0.22, 0.0, 1.0) \
		* clampf((0.09 - snow) / 0.09, 0.0, 1.0) \
		* clampf((0.13 - liquid) / 0.13, 0.0, 1.0) \
		* clampf(depth / 0.65, 0.0, 1.0)
	if covered or not surface.exposed_at_index(i) \
			or surface.frost_at_index(i) >= 0.55:
		dust_risk = 0.0
	var flood_risk := clampf(hydro.flood_depth_at(i) / 0.45, 0.0, 1.0)
	var drought_risk := clampf((0.32 - moisture) / 0.32, 0.0, 1.0) \
		* clampf((air - 15.0) / 17.0, 0.0, 1.0) \
		* clampf((0.18 - liquid) / 0.18, 0.0, 1.0) \
		* (1.0 - snow)
	var avalanche_risk := steep * clampf((snow - 0.25) / 0.65, 0.0, 1.0) \
		* (0.55 + 0.45 * clampf((air + 8.0) / 14.0, 0.0, 1.0))
	var mudflow_risk := steep * loose \
		* clampf(surface.runoff_at_index(i) / 1.45, 0.0, 1.0) \
		* clampf((moisture - 0.55) / 0.45, 0.0, 1.0)
	var slide_risk := steep * loose \
		* clampf((moisture - 0.53) / 0.47, 0.0, 1.0)
	# Обвалы возникают на крутой открытой скале. Переходы температуры
	# около нуля увеличивают риск трещинообразования, а рыхлая
	# влажная почва здесь не служит обязательным условием.
	var thermal_stress := 1.0 - smoothstep(1.5, 12.0, absf(air))
	var rockfall_risk := steep * (1.0 if rock else 0.0) \
		* (0.64 + 0.36 * thermal_stress)
	if covered:
		drought_risk = 0.0
		avalanche_risk = 0.0
		mudflow_risk = 0.0
		slide_risk = 0.0
		rockfall_risk = 0.0
	return {
		"шторм": storm_risk, "шквал": squall_risk,
		"ураган": hurricane_risk, "смерч": tornado_risk,
		"пыльная буря": dust_risk, "паводок": flood_risk,
		"засуха": drought_risk, "лавина": avalanche_risk,
		"сель": mudflow_risk, "оползень": slide_risk,
		"обвал": rockfall_risk,
		"землетрясение": fault_risk_at(cell),
		"downhill": target
	}


func _candidates(region: Vector2i, check_slopes: bool) -> Dictionary:
	var chosen := {}
	for kind in KINDS:
		chosen[kind] = {"score": 0.0, "cell": Vector2i(-1, -1)}
	for cell in _region_samples[region]:
		var risks: Dictionary = conditions_at(cell, check_slopes)
		for kind in KINDS:
			var score: float = risks[kind]
			if score > float(chosen[kind]["score"]):
				chosen[kind] = {"score": score, "cell": cell}
	return chosen

func _streak(previous: int, value: float, threshold: float) -> int:
	return mini(previous + 1, 10000) if value >= threshold else 0


func _record(kind: String, cell: Vector2i, severity: float,
		duration: int, impact: Dictionary = {}) -> void:
	if last_events.size() >= MAX_EVENTS_PER_DAY:
		return
	var event: Dictionary = {
		"kind": kind, "day": last_day, "cell": cell,
		"severity": clampf(severity, 0.0, 1.0),
		"duration_days": duration,
		"vertices": int(impact.get("vertices", 0)),
		"snow_volume": float(impact.get("snow_volume", 0.0)),
		"sediment_volume": float(impact.get("sediment_volume", 0.0)),
		"airborne_volume": float(impact.get("airborne_volume", 0.0))
	}
	last_events.append(event)
	total_events += 1
	disaster_occurred.emit(event.duplicate())


func dust_source_ready(cell: Vector2i) -> bool:
	# Единое правило для естественного зарождения и кнопки испытания:
	# скала, вода, снег и влажная поверхность не могут дать пыль.
	if not world.config.contains_cell(cell):
		return false
	var index: int = hydro.cell_index(cell)
	if hydro.has_water(index) or not surface.exposed_at_index(index):
		return false
	if surface.moisture_at_index(index) >= 0.27 \
			or surface.snow_at_index(index) >= 0.09 \
			or surface.frost_at_index(index) >= 0.55:
		return false
	return surface.soil_depth_at_index(index) >= 0.06


func apply_dust_storm(cell: Vector2i, severity: float) -> Dictionary:
	# Применяем настоящий перенос осадочного материала, не создавая
	# новую массу и не изменяя объекты GPU. Каждая пара исходной и
	# конечной клеток проходит через общий Surface.transfer_sediment.
	if not dust_source_ready(cell):
		return {}
	var direction: Vector2 = climate.wind_direction_at_index(
		hydro.cell_index(cell))
	if direction.length_squared() < 0.000001:
		return {}
	var forward := Vector2i(roundi(direction.x * 3.0),
		roundi(direction.y * 3.0))
	var side := Vector2i(-roundi(direction.y), roundi(direction.x))
	if forward == Vector2i.ZERO:
		return {}
	# Два коротких последовательных переноса дают читаемый след
	# на карте. У каждой полосы масса идёт из клетки в клетку,
	# а не телепортируется из эпицентра сразу в дальнюю точку.
	# Максимум шесть переносов по 0.007 = 0.042: прежний JSON v1
	# и ограничение sediment_volume <= 0.05 остаются совместимы.
	var amount := clampf(severity * 0.007, 0.002, 0.007)
	var moved := 0
	var lifted := 0.0
	for lane in [0, -1, 1]:
		var source: Vector2i = cell + side * lane
		var lane_moved := 0
		for step in range(2):
			# Нельзя брать новый грунт из воды, скалы, снега или
			# мокрой клетки. Если цепочка оборвалась, дальше не идём.
			if not dust_source_ready(source):
				break
			var target: Vector2i = source + forward
			if not world.config.contains_cell(target):
				break
			if hydro.has_water(hydro.cell_index(target)):
				break
			if not surface.transfer_sediment(source, target, amount):
				break
			moved += 1
			lane_moved += 1
			# Второй перенос использует тот же физический осадок
			# на новой клетке и не создаёт дополнительной массы.
			source = target
		# Только из уже действительно доставленного Surface-наноса
		# поднимаем в воздух малую долю. Вычитание из грунта
		# атомарно, а ограниченный реестр хранит физическую массу.
		if lane_moved > 0 and airborne_dust.size() < MAX_AIRBORNE_PLUMES:
			var suspension := amount * AIRBORNE_LIFT_FRACTION
			if surface.lift_airborne_sediment(source, suspension):
				airborne_dust.append({
					"cell": source, "mass": suspension, "born": climate.day
				})
				lifted += suspension
	if moved == 0:
		return {}
	return {
		"vertices": moved * 2,
		"sediment_volume": float(moved) * amount,
		"airborne_volume": lifted
	}


func airborne_volume() -> float:
	# Сумма вычисляется по ограниченному числу фронтов, а не
	# по всей карте: важно для длительных прогонов и HUD.
	var amount := 0.0
	for entry in airborne_dust:
		amount += float(entry["mass"])
	return amount


func _settle_airborne_day(day: int) -> void:
	# Воздушная масса может переместиться за сутки строго по
	# физическому направлению Climate. Дождь и слабый ветер
	# ускоряют выпадение, а после трёх суток оседает весь остаток.
	# Не используем RNG, камеру и отдельные GPU-погодные события.
	var remaining: Array[Dictionary] = []
	for entry in airborne_dust:
		if int(entry["born"]) >= day:
			remaining.append(entry)
			continue
		var position: Vector2i = entry["cell"]
		var index: int = hydro.cell_index(position)
		var direction: Vector2 = climate.wind_direction_at_index(index)
		var next := position + Vector2i(
			roundi(direction.x * 2.0), roundi(direction.y * 2.0))
		if not world.config.contains_cell(next):
			next = position
		elif hydro.has_water(hydro.cell_index(next)):
			next = position
		var rain: float = climate.precipitation_at_index(index)
		var gust: float = climate.wind_gust_at_index(index)
		var age := day - int(entry["born"])
		var portion := clampf(
			0.26 + rain * 0.42 + (1.0 - clampf(gust / 36.0, 0.0, 1.0)) * 0.20,
			0.25, 1.0)
		if age >= 3 or rain >= 0.8:
			portion = 1.0
		var volume: float = float(entry["mass"])
		var deposited := volume * portion
		if volume - deposited < 0.000001:
			deposited = volume
		# Не теряем массу над затопленной или слишком высокой
		# клеткой: если перенос не удался, пробуем прежний участок.
		var settled: bool = surface.settle_airborne_sediment(next, deposited)
		if not settled and next != position:
			settled = surface.settle_airborne_sediment(position, deposited)
			next = position
		if settled:
			volume -= deposited
		if volume > 0.0000005:
			remaining.append({
				"cell": next, "mass": volume, "born": entry["born"]
			})
	airborne_dust = remaining


func _slope_event(kind: String, cell: Vector2i, risk: float) -> Dictionary:
	if not world.config.contains_cell(cell):
		return {}
	var conditions: Dictionary = conditions_at(cell)
	if conditions.is_empty() or float(conditions.get(kind, 0.0)) < risk:
		return {}
	var target: Vector2i = conditions["downhill"]
	if not world.config.contains_cell(target):
		return {}
	if kind == "лавина":
		var before: float = surface.profile_at(cell)["snow"]
		if not surface.transfer_snow(cell, target, minf(0.25, before * 0.32)):
			return {}
		var moved: float = before - float(surface.profile_at(cell)["snow"])
		return {"snow_volume": moved}
	if kind == "сель":
		var amount := clampf(risk * 0.035, 0.005, 0.035)
		if not surface.transfer_sediment(cell, target, amount):
			return {}
		return {"vertices": 2, "sediment_volume": amount}
	if kind == "обвал":
		# Обрушение меняет настоящие вершины; гидрология и визуальные
		# чанки получают новую ревизию через единый WorldMap.
		return Landscape.new(world).apply("обвал",
			Vector2(cell) + Vector2(0.5, 0.5), 5.0,
			clampf(risk * 0.36, 0.12, 0.36))
	if kind == "оползень":
		return Landscape.new(world).apply("оползень",
			Vector2(cell) + Vector2(0.5, 0.5), 6.0,
			clampf(risk * 0.42, 0.12, 0.42))
	return {}


func _earthquake(cell: Vector2i, risk: float) -> Dictionary:
	if risk < 0.7 or not world.config.contains_cell(cell):
		return {}
	# Тектоническое смещение меняет геометрию; сам толчок мог бы
	# повредить будущие здания через disaster_occurred.
	var uplift: bool = Terrain.hash2(cell.x, cell.y,
		world.config.world_seed + last_day * 19 + 2207) > 0.5
	var kind := "поднятие" if uplift else "просадка"
	return Landscape.new(world).apply(kind,
		Vector2(cell) + Vector2(0.5, 0.5), 7.0,
		clampf(risk * 0.15, 0.08, 0.15))


func advance_day(day: int) -> Array[Dictionary]:
	if day <= last_day or day != climate.day or day != surface.day:
		return []
	last_day = day
	last_events.clear()
	# Сначала переносим и осаждаем взвесь предыдущих суток.
	# Новая пыль текущего бедствия оседать в тот же день не может.
	_settle_airborne_day(day)
	var dimensions: Vector2i = world.config.region_count()
	# Склоны проверяем только в дни возможного схода масс.
	# День 13 обязателен для обвалов: без него выборка обнуляла
	# крутизну и физический риск у уже запланированного события.
	# Шторм, паводок, засуха и напряжение обновляются ежедневно.
	var check_slopes := day % 5 == 0 or day % 7 == 0 \
		or day % 13 == 0 or day % 19 == 0
	var terrain_changed := false
	var dust_occurred := false
	for ry in range(dimensions.y):
		for rx in range(dimensions.x):
			var index := ry * dimensions.x + rx
			var found := _candidates(Vector2i(rx, ry), check_slopes)
			var storm: Dictionary = found["шторм"]
			var squall: Dictionary = found["шквал"]
			var hurricane: Dictionary = found["ураган"]
			var tornado: Dictionary = found["смерч"]
			var dust: Dictionary = found["пыльная буря"]
			var flood: Dictionary = found["паводок"]
			var drought: Dictionary = found["засуха"]
			_storms[index] = _streak(_storms[index], storm["score"], 0.34)
			_floods[index] = _streak(_floods[index], flood["score"], 0.25)
			_droughts[index] = _streak(_droughts[index], drought["score"], 0.30)
			var tectonic: Dictionary = found["землетрясение"]
			if float(tectonic["score"]) > 0.65:
				_strain[index] = minf(1.05, _strain[index]
					+ float(tectonic["score"]) * 0.015)
			else:
				_strain[index] = maxf(0.0, _strain[index] - 0.001)

			if _storms[index] == 3:
				_record("шторм", storm["cell"], storm["score"], _storms[index])
			# На пятые подряд штормовые сутки проверяем переход
			# фронта в ураган. Ровно одно событие на серию:
			# возобновление после JSON использует прежний _storms.
			if _storms[index] == 5 and float(hurricane["score"]) >= 0.65:
				_record("ураган", hurricane["cell"],
					float(hurricane["score"]), _storms[index])
			# На суше отдельный вихрь может возникнуть в первые
			# сутки фронта. Шанс редкий, seed-детерминированный;
			# один event описывает весь след за один физический день.
			if float(tornado["score"]) >= 0.72 and Terrain.hash2(rx, ry,
					world.config.world_seed + day * 83 + 6137) < 0.18:
				_record("смерч", tornado["cell"], float(tornado["score"]), 1)
			# Один короткий шквал допускается при резком физическом порыве.
			# Отбор по seed/дню не расходует состояние генератора случайных
			# чисел, поэтому сохранение и повторный прогон согласованы.
			if _storms[index] != 3 and float(squall["score"]) >= 0.72 \
					and Terrain.hash2(rx, ry,
						world.config.world_seed + day * 79 + 4417) < 0.42:
				_record("шквал", squall["cell"], squall["score"], 1)
			# Одна пыльная буря за день: землёй распоряжается только
			# Surface; событие записываем, только если грунт перенесён.
			if not dust_occurred and last_events.size() < MAX_EVENTS_PER_DAY \
					and float(dust["score"]) >= 0.65 \
					and Terrain.hash2(rx, ry,
						world.config.world_seed + day * 89 + 7321) < 0.45:
				var dust_impact: Dictionary = apply_dust_storm(
					dust["cell"], float(dust["score"]))
				if not dust_impact.is_empty():
					_record("пыльная буря", dust["cell"],
						float(dust["score"]), 1, dust_impact)
					dust_occurred = true
					terrain_changed = true
			if _floods[index] == 2:
				_record("чрезвычайный паводок", flood["cell"],
					flood["score"], _floods[index])
			if _droughts[index] == 8:
				_record("засуха", drought["cell"],
					drought["score"], _droughts[index])
			if terrain_changed or last_events.size() >= MAX_EVENTS_PER_DAY:
				continue

			var hazard := ""
			var risk := 0.0
			var at := Vector2i(-1, -1)
			if _strain[index] >= 1.0 and day % 8 == 0:
				hazard = "землетрясение"
			elif day % 5 == 0:
				hazard = "лавина"
			elif day % 7 == 0:
				hazard = "сель"
			elif day % 13 == 0:
				hazard = "обвал"
			elif day % 19 == 0:
				hazard = "оползень"
			if hazard.is_empty():
				continue
			var candidate: Dictionary = found[hazard]
			risk = candidate["score"]
			at = candidate["cell"]
			if at.x < 0 or risk < (0.70 if hazard == "землетрясение" else 0.52):
				continue
			var impact: Dictionary = _earthquake(at, risk) \
				if hazard == "землетрясение" else _slope_event(hazard, at, risk)
			if impact.is_empty():
				continue
			if hazard == "землетрясение":
				_strain[index] = 0.0
			_record(hazard, at, risk, 1, impact)
			terrain_changed = int(impact.get("vertices", 0)) > 0
	return last_events.duplicate(true)


func _numbers(values: PackedInt32Array) -> Array:
	var result := []
	for value in values:
		result.append(value)
	return result


func _floats(values: PackedFloat32Array) -> Array:
	var result := []
	for value in values:
		result.append(value)
	return result


func to_data() -> Dictionary:
	var events := []
	for event in last_events:
		var cell: Vector2i = event["cell"]
		# История — сохраняемый отчёт, не вход в физические формулы.
		# Канонизируем доли до миллиардной единицы: JSON может
		# вернуть иную последнюю цифру double при загрузке.
		# Иначе два равных мира дают ложное расхождение 11.10.
		events.append([
			event["kind"], event["day"], cell.x, cell.y,
			snappedf(float(event["severity"]), 0.000000001),
			event["duration_days"], event["vertices"],
			snappedf(float(event["snow_volume"]), 0.000000001),
			snappedf(float(event["sediment_volume"]), 0.000000001),
			snappedf(float(event.get("airborne_volume", 0.0)), 0.000000001)
		])
	# Воздушная масса записывается отдельно от старой истории
	# девятипольных событий и в целых микродолях: точная
	# повторная загрузка не дублирует пыль поверх грунта.
	var plumes := []
	for entry in airborne_dust:
		var point: Vector2i = entry["cell"]
		plumes.append([point.x, point.y,
			roundi(float(entry["mass"]) * AIRBORNE_UNITS),
			int(entry["born"])])
	return {
		"version": FORMAT_VERSION,
		"world_signature": JSON.stringify(world.to_data()),
		"airborne_dust": plumes,
		"last_day": last_day, "total_events": total_events,
		"storms": _numbers(_storms), "floods": _numbers(_floods),
		"droughts": _numbers(_droughts), "strain": _floats(_strain),
		"last_events": events
	}


func _valid_integer(value: Variant, maximum: int) -> bool:
	if not (value is int or value is float) or not is_finite(float(value)):
		return false
	return float(value) == float(int(value)) \
		and int(value) >= 0 and int(value) <= maximum


func _read_streak(data: Dictionary, key: String, count: int) -> PackedInt32Array:
	var result := PackedInt32Array()
	var raw: Variant = data.get(key)
	if not (raw is Array) or raw.size() != count:
		return result
	for value in raw:
		if not _valid_integer(value, 10000):
			return PackedInt32Array()
		result.append(int(value))
	return result


func load_data(data: Dictionary) -> bool:
	# Версия 1 сохраняет прежнюю историю без воздушной массы.
	# Версия 2 добавляет реестр в пути и по-прежнему проверяет
	# подпись настоящей карты до изменения полей живой модели.
	var version: Variant = data.get("version")
	if version != 1 and version != FORMAT_VERSION:
		return false
	if data.get("world_signature") != JSON.stringify(world.to_data()):
		return false
	if not _valid_integer(data.get("last_day"), 10000000) \
			or not _valid_integer(data.get("total_events"), 100000000):
		return false
	if int(data["last_day"]) > climate.day or int(data["last_day"]) > surface.day:
		return false
	var count := _storms.size()
	var storms := _read_streak(data, "storms", count)
	var floods := _read_streak(data, "floods", count)
	var droughts := _read_streak(data, "droughts", count)
	if storms.size() != count or floods.size() != count or droughts.size() != count:
		return false
	var raw_strain: Variant = data.get("strain")
	if not (raw_strain is Array) or raw_strain.size() != count:
		return false
	var strain := PackedFloat32Array()
	for value in raw_strain:
		if not (value is int or value is float) or not is_finite(float(value)):
			return false
		if float(value) < 0.0 or float(value) > 1.05:
			return false
		strain.append(float(value))
	var entries: Variant = data.get("last_events")
	if not (entries is Array) or entries.size() > MAX_EVENTS_PER_DAY:
		return false
	if entries.size() > int(data["total_events"]):
		return false
	var restored: Array[Dictionary] = []
	for item in entries:
		if not (item is Array) or item.size() != (9 if version == 1 else 10):
			return false
		if not (item[0] is String) or item[0] not in KINDS + ["чрезвычайный паводок"]:
			return false
		for field in [1, 2, 3, 5, 6]:
			if not _valid_integer(item[field], 10000000):
				return false
		var cell := Vector2i(int(item[2]), int(item[3]))
		if not world.config.contains_cell(cell) or int(item[1]) > int(data["last_day"]):
			return false
		for field in [4, 7, 8]:
			if not (item[field] is int or item[field] is float) \
					or not is_finite(float(item[field])) \
					or float(item[field]) < 0.0:
				return false
		if float(item[4]) > 1.0 or float(item[7]) > 0.5 or float(item[8]) > 0.05:
			return false
		var suspended := 0.0
		if version == FORMAT_VERSION:
			if not (item[9] is int or item[9] is float) \
					or not is_finite(float(item[9])):
				return false
			suspended = float(item[9])
			if suspended < 0.0 or suspended > 0.05:
				return false
		restored.append({
			"kind": item[0], "day": int(item[1]), "cell": cell,
			"severity": float(item[4]), "duration_days": int(item[5]),
			"vertices": int(item[6]),
			"snow_volume": float(item[7]),
			"sediment_volume": float(item[8]),
			"airborne_volume": suspended
		})
	# Проверяем новые массы, индексы и возраст до записи
	# каких-либо полей. Сломанный JSON не оставляет полузагруженную
	# атмосферу или неверные серии штормов.
	var plumes: Variant = data.get("airborne_dust", []) \
		if version == FORMAT_VERSION else []
	if not (plumes is Array) or plumes.size() > MAX_AIRBORNE_PLUMES:
		return false
	var restored_air: Array[Dictionary] = []
	for plume in plumes:
		if not (plume is Array) or plume.size() != 4:
			return false
		for index in range(4):
			if not _valid_integer(plume[index], 10000000):
				return false
		var place := Vector2i(int(plume[0]), int(plume[1]))
		var mass: float = float(plume[2]) / AIRBORNE_UNITS
		if not world.config.contains_cell(place) or mass < 0.0000005 \
				or mass > 0.05 or int(plume[3]) > int(data["last_day"]):
			return false
		restored_air.append({
			"cell": place, "mass": mass, "born": int(plume[3])
		})
	_storms = storms
	_floods = floods
	_droughts = droughts
	_strain = strain
	last_day = int(data["last_day"])
	total_events = int(data["total_events"])
	last_events = restored
	airborne_dust = restored_air
	return true
