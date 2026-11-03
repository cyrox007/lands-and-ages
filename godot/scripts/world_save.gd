extends RefCounted
## Единый атомарный снимок природного мира и безопасная загрузка.
## Сохранение вызывается только после завершения фонового игрового дня.

const Map = preload("res://scripts/world_map.gd")
const Hydro = preload("res://scripts/hydrology.gd")
const Surface = preload("res://scripts/surface.gd")
const Climate = preload("res://scripts/climate.gd")
const Weather = preload("res://scripts/weather_events.gd")
const Natural = preload("res://scripts/natural_processes.gd")
const Disasters = preload("res://scripts/natural_disasters.gd")
const Landscape = preload("res://scripts/landscape_events.gd")
const Runner = preload("res://scripts/world_day_runner.gd")

const FORMAT_VERSION := 1
const SAVE_PATH := "user://world-save.json"
const MAX_FILE_BYTES := 32 * 1024 * 1024


static func capture(state: Dictionary) -> Dictionary:
	for key in ["world", "hydro", "surface", "climate",
			"weather", "natural", "disasters"]:
		if not (state.get(key) is RefCounted):
			return {}
	var world: RefCounted = state["world"]
	var hydro: RefCounted = state["hydro"]
	var surface: RefCounted = state["surface"]
	var climate: RefCounted = state["climate"]
	var weather: RefCounted = state["weather"]
	var natural: RefCounted = state["natural"]
	var disasters: RefCounted = state["disasters"]
	if climate.day != surface.day or climate.day < 0:
		return {}
	if weather.last_day > climate.day or natural.last_day > climate.day \
			or disasters.last_day > climate.day:
		return {}
	# Снимок собирается после синхронизации геометрии, а не между
	# изменением вершины и обновлением связанных водосборов.
	if hydro._terrain_revision != world.revision \
			or surface._terrain_revision != world.revision \
			or climate._terrain_revision != world.revision:
		return {}
	return {
		"version": FORMAT_VERSION, "day": climate.day,
		"world": world.to_data(),
		"hydrology": hydro.to_snapshot(),
		"climate": climate.to_data(),
		"surface": surface.to_snapshot(),
		"weather": weather.to_data(),
		"natural": natural.to_data(),
		"disasters": disasters.to_data()
	}


static func restore(snapshot: Dictionary) -> Dictionary:
	if snapshot.get("version") != FORMAT_VERSION:
		return {}
	var saved_day: Variant = snapshot.get("day")
	if not (saved_day is int or saved_day is float) \
			or not is_finite(float(saved_day)):
		return {}
	if float(saved_day) != float(int(saved_day)) \
			or float(saved_day) < 0.0 or float(saved_day) > 10000000.0:
		return {}
	for name in ["world", "hydrology", "climate", "surface",
			"weather", "natural", "disasters"]:
		if not (snapshot.get(name) is Dictionary):
			return {}
	# Создаём новый набор моделей. Ошибка в любом слое не меняет
	# текущую игровую сцену или существующее сохранение на диске.
	var world: RefCounted = Map.from_data(snapshot["world"])
	if world == null:
		return {}
	var hydro := Hydro.new(world)
	if not hydro.load_snapshot(snapshot["hydrology"]):
		return {}
	var climate := Climate.new(world, hydro)
	climate.rebuild()
	if not climate.load_data(snapshot["climate"]):
		return {}
	var surface := Surface.new(world, hydro)
	surface.rebuild()
	if not surface.load_snapshot(snapshot["surface"]):
		return {}
	if climate.day != int(saved_day) or surface.day != int(saved_day):
		return {}
	var weather := Weather.new(world, climate, surface, hydro)
	if not weather.load_data(snapshot["weather"]):
		return {}
	var natural := Natural.new(world, hydro, surface, climate)
	if not natural.load_data(snapshot["natural"]):
		return {}
	var disasters := Disasters.new(world, hydro, surface, climate)
	if not disasters.load_data(snapshot["disasters"]):
		return {}
	return {
		"world": world, "hydro": hydro, "surface": surface,
		"climate": climate, "weather": weather,
		"natural": natural, "disasters": disasters,
		"landscape": Landscape.new(world),
		"runner": Runner.new(world, hydro, surface, climate,
			weather, natural, disasters)
	}


static func write_file(state: Dictionary, path: String = SAVE_PATH) -> bool:
	if not path.begins_with("user://"):
		return false
	var snapshot := capture(state)
	if snapshot.is_empty():
		return false
	var payload := JSON.stringify(snapshot, "", true, true)
	var envelope := JSON.stringify({
		"version": FORMAT_VERSION,
		"checksum": payload.sha256_text(),
		"payload": payload
	})
	if envelope.to_utf8_buffer().size() > MAX_FILE_BYTES:
		return false
	var temporary := path + ".tmp"
	var file := FileAccess.open(temporary, FileAccess.WRITE)
	if file == null:
		return false
	file.store_string(envelope)
	file.flush()
	file.close()
	var result := DirAccess.rename_absolute(
		ProjectSettings.globalize_path(temporary),
		ProjectSettings.globalize_path(path))
	return result == OK


static func read_file(path: String = SAVE_PATH) -> Dictionary:
	if not path.begins_with("user://"):
		return {}
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return {}
	if file.get_length() < 1 or file.get_length() > MAX_FILE_BYTES:
		file.close()
		return {}
	var raw: String = file.get_as_text()
	file.close()
	var envelope: Variant = JSON.parse_string(raw)
	if not (envelope is Dictionary) or envelope.get("version") != FORMAT_VERSION:
		return {}
	if not (envelope.get("checksum") is String) \
			or not (envelope.get("payload") is String):
		return {}
	var payload: String = envelope["payload"]
	if payload.sha256_text() != envelope["checksum"]:
		return {}
	var parsed: Variant = JSON.parse_string(payload)
	if not (parsed is Dictionary):
		return {}
	return restore(parsed)
