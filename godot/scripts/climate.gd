extends RefCounted
## Независимые регион, почва, климат и временное покрытие.
## События пока описательны и не изменяют игровую экономику.

const Terrain = preload("res://scripts/terrain.gd")
const REGION_SIZE := 64
const SEASON_DAYS := 24
const SEASONS := ["Весна", "Лето", "Осень", "Зима"]

static func season_index(day: int) -> int:
	return (maxi(day, 1) - 1) / SEASON_DAYS % 4


static func season_name(day: int) -> String:
	return SEASONS[season_index(day)]


static func region_id(x: int, y: int) -> Vector2i:
	return Vector2i(clampi(x / REGION_SIZE, 0, 3), clampi(y / REGION_SIZE, 0, 2))


static func weather_at(x: int, y: int, day: int, seed: int = Terrain.SEED) -> Dictionary:
	var region := region_id(x, y)
	var cx := float(region.x * REGION_SIZE + REGION_SIZE / 2)
	var cy := float(region.y * REGION_SIZE + REGION_SIZE / 2)
	var moisture := clampf(0.31 + Terrain.hash2(region.x, region.y, seed + 200) * 0.56, 0.15, 0.95)
	var season := season_index(day)
	var shift := [-1.0, 8.0, -2.0, -11.0][season]
	var baseline := 19.0 - 27.0 * cy / float(Terrain.HEIGHT)
	baseline += (Terrain.hash2(region.x, region.y, seed + 403) - 0.5) * 5.0
	var variation := (Terrain.hash2(day, region.x + region.y * 19, seed + 404) - 0.5) * 6.0
	var temperature: float = baseline + shift + variation
	var chance := Terrain.hash2(day, region.x + region.y * 31, seed + 405)
	var raining := chance < moisture * 0.65
	var precipitation := 0.0
	if raining:
		precipitation = 0.2 + Terrain.hash2(day, region.x + region.y * 37, seed + 406) * 0.8
	var wind := 2.0 + Terrain.hash2(day, region.x + region.y * 41, seed + 407) * 20.0
	var kind := "ясно"
	if raining:
		kind = "снег" if temperature < 1.0 else "дождь"
	var event := ""
	if precipitation > 0.83 and wind > 15.0:
		event = "Метель" if temperature < 1.0 else "Шторм"
	elif precipitation > 0.85 and moisture > 0.7:
		event = "Ливень"
	elif not raining and wind > 19.0:
		event = "Сильный ветер"
	elif not raining and temperature > 29.0 and moisture < 0.4:
		event = "Засуха"
	return {
		"region": region, "humidity": moisture, "temperature": temperature,
		"precipitation": precipitation, "kind": kind, "wind": wind, "event": event
	}


static func surface_at(x: int, y: int, day: int, seed: int = Terrain.SEED) -> Dictionary:
	var wx := clampi(x, 0, Terrain.WIDTH - 1)
	var wy := clampi(y, 0, Terrain.HEIGHT - 1)
	var climate := weather_at(wx, wy, day, seed)
	var elevation := Terrain.ground_height(float(wx) + 0.5, float(wy) + 0.5, seed)
	var slope := Terrain.slope_at(wx, wy, seed)
	var humidity: float = climate["humidity"]
	var moisture := clampf(0.12 + humidity * 0.63 + float(climate["precipitation"]) * 0.33 - maxf(0.0, elevation) * 0.022, 0.0, 1.0)
	var fertility := clampf(0.2 + 0.66 * Terrain.hash2(wx, wy, seed + 712) + moisture * 0.14 - maxf(0.0, slope - 0.5) * 0.12, 0.0, 1.0)
	var water := elevation < -1.35
	var substrate := "soil"
	if water:
		substrate = "water"
	elif elevation > 6.0 or slope > 1.65:
		substrate = "rock"
	elif moisture < 0.35 and Terrain.hash2(wx, wy, seed + 713) > 0.3:
		substrate = "sand"
	var region: Vector2i = climate["region"]
	var center_y := float(region.y * REGION_SIZE + REGION_SIZE / 2)
	var temperature := float(climate["temperature"]) + 27.0 * (center_y - float(wy)) / float(Terrain.HEIGHT)
	temperature -= elevation * 0.55
	var snow_depth := 0.0
	if temperature < 1.0:
		for offset in range(7):
			if day - offset < 1:
				break
			var past := weather_at(wx, wy, day - offset, seed)
			if float(past["temperature"]) < 2.0 and past["kind"] == "снег":
				snow_depth += float(past["precipitation"]) * (1.0 - float(offset) * 0.1)
	snow_depth = clampf(snow_depth * 0.5, 0.0, 1.0)
	var grass := 0.0
	if substrate == "soil":
		grass = clampf(fertility * (0.42 + moisture * 0.7) * (0.18 if temperature < -7.0 else 1.0), 0.0, 1.0)
	var cover := substrate
	if substrate == "water" and temperature < -2.0:
		cover = "ice"
	elif substrate != "water" and snow_depth > 0.19:
		cover = "snow"
	elif substrate == "soil":
		cover = "grass" if grass > 0.34 else "bare"
	var soil_kind := ""
	if substrate == "soil":
		soil_kind = "Чернозём" if fertility > 0.68 else ("Суглинок" if fertility > 0.38 else "Бедная почва")
	return {
		"height": elevation, "slope": slope, "region": region,
		"substrate": substrate, "soil": soil_kind, "fertility": fertility,
		"moisture": moisture, "grass": grass, "cover": cover,
		"snow": snow_depth, "temperature": temperature,
		"wind": climate["wind"], "precipitation": climate["precipitation"]
	}
