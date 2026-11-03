extends RefCounted
## Грозовые разряды — события физического мира, не объекты рендера.
## Возможное возгорание передаётся будущей растительности, а не создаёт дерево.

signal lightning_struck(event: Dictionary)
signal ignition_candidate(event: Dictionary)

const Terrain = preload("res://scripts/terrain.gd")
const FORMAT_VERSION := 1
const REGION_STEP := 32
const MIN_STORM := 0.27
const MAX_STRIKES := 8

var world: RefCounted
var climate: RefCounted
var surface: RefCounted
var hydro: RefCounted
var last_day := 0
var total_strikes := 0
var last_events: Array[Dictionary] = []


func _init(map: RefCounted, weather: RefCounted,
		ground: RefCounted, water: RefCounted) -> void:
	world = map
	climate = weather
	surface = ground
	hydro = water


func advance_day(day: int) -> Array[Dictionary]:
	if day <= last_day or day != climate.day or day != surface.day:
		return []
	last_day = day
	last_events.clear()
	var width: int = world.config.width
	var height: int = world.config.height
	var regions_x := ceili(float(width) / float(REGION_STEP))
	var regions_y := ceili(float(height) / float(REGION_STEP))
	for ry in range(regions_y):
		for rx in range(regions_x):
			if last_events.size() >= MAX_STRIKES:
				break
			var chosen := Vector2i(-1, -1)
			var strength := 0.0
			var x0 := rx * REGION_STEP
			var y0 := ry * REGION_STEP
			var span_x := mini(REGION_STEP, width - x0)
			var span_y := mini(REGION_STEP, height - y0)
			# Выборка 4×4 охватывает регион без обхода всех клеток.
			for sy in range(4):
				for sx in range(4):
					var cell := Vector2i(x0 + mini(span_x - 1,
						(sx * 2 + 1) * span_x / 8),
						y0 + mini(span_y - 1, (sy * 2 + 1) * span_y / 8))
					var i: int = hydro.cell_index(cell)
					var storm: float = climate.storm_at_index(i)
					if storm > strength:
						strength = storm
						chosen = cell
			if strength < MIN_STORM:
				continue
			var chance := Terrain.hash2(rx, ry,
				world.config.seed + day * 41 + 39071)
			if chance > clampf(strength * 0.72, 0.0, 0.72):
				continue
			var profile: Dictionary = surface.profile_at(chosen)
			var weather: Dictionary = climate.weather_at(chosen)
			var i: int = hydro.cell_index(chosen)
			var dryness := clampf((0.54 - float(profile["moisture"])) / 0.54,
				0.0, 1.0)
			var ignition := strength * dryness \
				* (1.0 - float(profile["snow"])) \
				* clampf(1.0 - float(weather["rainfall"]) * 0.58, 0.0, 1.0)
			if hydro.has_water(i):
				ignition = 0.0
			var event: Dictionary = {
				"day": day, "cell": chosen, "cause": "молния",
				"strength": strength,
				"ignition_potential": clampf(ignition, 0.0, 1.0)
			}
			last_events.append(event)
			total_strikes += 1
			lightning_struck.emit(event.duplicate())
			# Это только запрос будущему горючему объекту; леса пока нет.
			if ignition > 0.02:
				ignition_candidate.emit(event.duplicate())
	return last_events.duplicate(true)


func to_data() -> Dictionary:
	var entries := []
	for event in last_events:
		var cell: Vector2i = event["cell"]
		entries.append([
			cell.x, cell.y, float(event["strength"]),
			float(event["ignition_potential"])
		])
	return {
		"version": FORMAT_VERSION,
		"world_signature": JSON.stringify(world.to_data()),
		"last_day": last_day, "total_strikes": total_strikes,
		"last_events": entries
	}


func load_data(data: Dictionary) -> bool:
	if data.get("version") != FORMAT_VERSION \
			or data.get("world_signature") != JSON.stringify(world.to_data()):
		return false
	for key in ["last_day", "total_strikes"]:
		if not (data.get(key) is int or data.get(key) is float):
			return false
		if not is_finite(float(data[key])) \
				or float(data[key]) != float(int(data[key])) \
				or int(data[key]) < 0:
			return false
	if int(data["last_day"]) > climate.day or int(data["last_day"]) > surface.day:
		return false
	if not (data.get("last_events") is Array):
		return false
	var entries: Array = data["last_events"]
	if entries.size() > MAX_STRIKES or entries.size() > int(data["total_strikes"]):
		return false
	var restored: Array[Dictionary] = []
	for item in entries:
		if not (item is Array) or item.size() != 4:
			return false
		for value in item:
			if not (value is int or value is float) or not is_finite(float(value)):
				return false
		if float(item[0]) != float(int(item[0])) \
				or float(item[1]) != float(int(item[1])):
			return false
		var cell := Vector2i(int(item[0]), int(item[1]))
		if not world.config.contains_cell(cell):
			return false
		if float(item[2]) < 0.0 or float(item[2]) > 1.0 \
				or float(item[3]) < 0.0 or float(item[3]) > 1.0:
			return false
		restored.append({
			"day": int(data["last_day"]), "cell": cell, "cause": "молния",
			"strength": float(item[2]),
			"ignition_potential": float(item[3])
		})
	last_day = int(data["last_day"])
	total_strikes = int(data["total_strikes"])
	last_events = restored
	return true
