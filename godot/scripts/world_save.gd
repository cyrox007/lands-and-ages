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
const Nature = preload("res://scripts/nature_registry.gd")
const Fire = preload("res://scripts/fire_registry.gd")
const Resources = preload("res://scripts/natural_resource_registry.gd")
const Economy = preload("res://scripts/world_first_economy.gd")
const Industry = preload("res://scripts/world_resource_industry.gd")
const Settlement = preload("res://scripts/world_settlement.gd")
const Wildlife = preload("res://scripts/wildlife_populations.gd")
const FoodWeb = preload("res://scripts/wildlife_food_web.gd")
const Harvest = preload("res://scripts/wildlife_harvest.gd")
const Domestic = preload("res://scripts/wildlife_domestication.gd")

const FORMAT_VERSION := 1
const SAVE_PATH := "user://world-save.json"
const MAX_FILE_BYTES := 32 * 1024 * 1024
const MAX_SAVED_CELLS := 512 * 512


static func _within_world_limit(data: Dictionary) -> bool:
	var config: Variant = data.get("config")
	if not (config is Dictionary):
		return false
	var width: Variant = config.get("width")
	var height: Variant = config.get("height")
	if not (width is int or width is float) \
			or not (height is int or height is float):
		return false
	var w := float(width)
	var h := float(height)
	return is_finite(w) and is_finite(h) and w >= 1.0 and h >= 1.0 \
		and w * h <= float(MAX_SAVED_CELLS)


static func capture(state: Dictionary) -> Dictionary:
	for key in ["world", "hydro", "surface", "climate",
			"weather", "natural", "disasters"]:
		if not (state.get(key) is RefCounted):
			return {}
	var world: RefCounted = state["world"]
	# Гигантские конфигурации из раннего формата мира не должны
	# создавать файлы, которые полигон пока не способен загрузить.
	if world.config.width * world.config.height > MAX_SAVED_CELLS:
		return {}
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
	var snapshot := {
		"version": FORMAT_VERSION, "day": climate.day,
		"world": world.to_data(),
		"hydrology": hydro.to_snapshot(),
		"climate": climate.to_data(),
		"surface": surface.to_snapshot(),
		"weather": weather.to_snapshot(),
		"natural": natural.to_data(),
		"disasters": disasters.to_data()
	}
	# Старые сценарии без леса не меняют формат своего снимка.
	var nature: RefCounted = state.get("nature")
	if nature != null and nature.generated:
		if nature.last_day != climate.day:
			return {}
		snapshot["nature"] = nature.to_data()
	# Новый раздел необязателен, чтобы старые сохранения формата v1
	# не переписывались без причины и продолжали загружаться.
	var fire: RefCounted = state.get("fire")
	if fire != null:
		if fire.last_day != climate.day:
			return {}
		snapshot["fire"] = fire.to_data()
	# Залежи необязательны для старых сохранений без этапа 12.
	var resources: RefCounted = state.get("resources")
	if resources != null:
		var sources: Dictionary = resources.to_data()
		if not (sources.get("sources") is Array):
			return {}
		if not sources["sources"].is_empty():
			snapshot["resources"] = sources
	# Пустой цикл не меняет старый формат; активный заказ сохраняется
	# только вместе с днём, исходниками и физическим состоянием мира.
	var economy: RefCounted = state.get("economy")
	if economy != null and economy.phase != "ожидание":
		if economy.last_day != climate.day:
			return {}
		snapshot["economy"] = economy.to_data()
	# Новый производственный склад необязателен для старых миров.
	# Его время строго синхронно с климатом и физической экономикой.
	var industry: RefCounted = state.get("industry")
	if industry != null and industry.site.x >= 0:
		if industry.last_day != climate.day:
			return {}
		snapshot["industry"] = industry.to_data()
	# Поселение хранится только вместе с настоящим строительным заказом.
	# Отсутствующий раздел не меняет прежний формат WorldSave.
	var settlement: RefCounted = state.get("settlement")
	if settlement != null and settlement.established():
		if economy == null or economy.phase == "ожидание":
			return {}
		snapshot["settlement"] = settlement.to_data()
	# Дикие популяции добавляются в снимок только после реальной
	# генерации и обработки того же климатического дня.
	var wildlife: RefCounted = state.get("wildlife")
	if wildlife != null and wildlife.generated:
		if wildlife.last_day != climate.day:
			return {}
		snapshot["wildlife"] = wildlife.to_data()
	# Хищники хранят только собственные стаи; их жертвы уже
	# списаны из того же реестра травоядных WildlifePopulations.
	var food_web: RefCounted = state.get("food_web")
	if food_web != null and food_web.generated:
		if food_web.last_day != climate.day or wildlife == null \
				or not wildlife.generated:
			return {}
		snapshot["food_web"] = food_web.to_data()
	# Туши и материалы хранятся отдельно от исходных живых стад.
	# Если хозяйство ведёт охоту, нужно сохранить весь путь до склада.
	var harvest: RefCounted = state.get("harvest")
	if harvest != null and harvest.site.x >= 0:
		if wildlife == null or not wildlife.generated \
				or harvest.last_day != climate.day:
			return {}
		snapshot["harvest"] = harvest.to_data()
	# Отловленные предки и их потомки никогда не генерируются
	# заново из построек при восстановлении сохранения.
	var domestic: RefCounted = state.get("domestic")
	if domestic != null and domestic.site.x >= 0:
		if wildlife == null or not wildlife.generated \
				or food_web == null or not food_web.generated \
				or harvest == null or domestic.last_day != climate.day:
			return {}
		snapshot["domestic"] = domestic.to_data()
	return snapshot


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
	# Размер проверяем до создания массивов гидрологии: чужой файл
	# не должен выделять гигабайты памяти при одной загрузке.
	if not _within_world_limit(snapshot["world"]):
		return {}
	# Создаём новые модели только после проверки формата и размера.
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
	if not weather.load_snapshot(snapshot["weather"]):
		return {}
	var natural := Natural.new(world, hydro, surface, climate)
	if not natural.load_data(snapshot["natural"]):
		return {}
	var disasters := Disasters.new(world, hydro, surface, climate)
	if not disasters.load_data(snapshot["disasters"]):
		return {}
	var nature := Nature.new(world, hydro, surface, climate)
	if snapshot.has("nature"):
		if not (snapshot["nature"] is Dictionary) \
				or not nature.load_data(snapshot["nature"]):
			return {}
	# Старый мир не содержит очагов. Для нового мира строго
	# валидируем все активные горящие записи до подмены моделей.
	var fire := Fire.new(world, hydro, surface, climate, nature)
	if snapshot.has("fire") and (not (snapshot["fire"] is Dictionary) \
			or not fire.load_data(snapshot["fire"])):
		return {}
	# Отсутствующий слой означает старый формат мира, а не ошибку.
	# Повреждённые новые записи отклоняются до замены игровых моделей.
	var resources := Resources.new(world)
	if snapshot.has("resources"):
		if not (snapshot["resources"] is Dictionary) \
				or not resources.load_data(snapshot["resources"]):
			return {}
	# Хозяйство восстанавливается после природы и залежей, чтобы
	# работать с теми же деревьями, а не копиями запасов.
	var economy := Economy.new(world, hydro, surface, nature,
		resources, int(saved_day))
	if snapshot.has("economy") and (not (snapshot["economy"] is Dictionary)
			or not economy.load_data(snapshot["economy"], int(saved_day))):
		return {}
	# Новый склад может отсутствовать в ранних сохранениях, но при
	# наличии должен пройти полную проверку до подмены моделей.
	var industry := Industry.new(world, hydro, surface, nature,
		resources, int(saved_day))
	if snapshot.has("industry") and (not (snapshot["industry"] is Dictionary)
			or not industry.load_data(snapshot["industry"], int(saved_day))):
		return {}
	# Поддельное здание отклоняем до возвращения новой модели миру.
	var settlement := Settlement.new(world, economy, industry)
	if snapshot.has("settlement") and (not (snapshot["settlement"] is Dictionary)
			or not settlement.load_data(snapshot["settlement"])):
		return {}
	# Старое сохранение остаётся доступно без автоматического
	# появления животных. Существующий реестр читается атомарно.
	var wildlife := Wildlife.new(world, hydro, surface, climate, nature)
	if snapshot.has("wildlife") and (not (snapshot["wildlife"] is Dictionary)
			or not wildlife.load_data(snapshot["wildlife"])):
		return {}
	# Старые миры сохраняют совместимость; стаи не появляются при
	# загрузке, если новый раздел отсутствует в старом файле.
	var food_web := FoodWeb.new(world, climate, wildlife)
	if snapshot.has("food_web") and (not (snapshot["food_web"] is Dictionary)
			or not food_web.load_data(snapshot["food_web"])):
		return {}
	# Реестр продукции не может существовать без живой фауны,
	# от которой могла произойти учтённая добыча.
	var harvest := Harvest.new(world, hydro, surface, climate, wildlife)
	if snapshot.has("harvest"):
		if not snapshot.has("wildlife") \
				or not (snapshot["harvest"] is Dictionary) \
				or not harvest.load_data(snapshot["harvest"]):
			return {}
	# Источник предков должен быть восстановлен раньше домашних линий.
	var domestic := Domestic.new(world, hydro, surface, climate,
		wildlife, food_web, harvest)
	if snapshot.has("domestic"):
		if not snapshot.has("wildlife") or not snapshot.has("food_web") \
				or not snapshot.has("harvest") \
				or not (snapshot["domestic"] is Dictionary) \
				or not domestic.load_data(snapshot["domestic"]):
			return {}
	return {
		"world": world, "hydro": hydro, "surface": surface,
		"climate": climate, "weather": weather,
		"natural": natural, "disasters": disasters,
		"nature": nature, "fire": fire, "resources": resources,
		"economy": economy, "industry": industry, "settlement": settlement,
		"wildlife": wildlife,
		"food_web": food_web, "harvest": harvest, "domestic": domestic,
		"landscape": Landscape.new(world),
		"runner": Runner.new(world, hydro, surface, climate,
			weather, natural, disasters, nature, fire)
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


static func _parse_json(text: String) -> Variant:
	# JSON.parse_string пишет ошибку движка при битом файле.
	# Проверяем код парсера и тихо отклоняем повреждённый текст.
	var parser := JSON.new()
	if parser.parse(text) != OK:
		return null
	return parser.data


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
	var envelope: Variant = _parse_json(raw)
	if not (envelope is Dictionary) or envelope.get("version") != FORMAT_VERSION:
		return {}
	if not (envelope.get("checksum") is String) \
			or not (envelope.get("payload") is String):
		return {}
	var payload: String = envelope["payload"]
	if payload.sha256_text() != envelope["checksum"]:
		return {}
	var parsed: Variant = _parse_json(payload)
	if not (parsed is Dictionary):
		return {}
	return restore(parsed)
