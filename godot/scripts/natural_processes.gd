extends RefCounted
## Медленные природные процессы. Ни погода, ни GPU не владеют высотами.
## За один шаг изменяется лишь небольшой физически обоснованный участок.

signal process_applied(kind: String, cell: Vector2i, day: int)

const Landscape = preload("res://scripts/landscape_events.gd")
const FORMAT_VERSION := 1
const STEP_DAYS := 4
const SAMPLE_COUNT := 192
const SAMPLE_STRIDE := 577

var world: RefCounted
var hydro: RefCounted
var surface: RefCounted
var climate: RefCounted
# Необязательный реестр пожаров: старые миры без пожаров сохраняют
# прежнюю геологию и порядок событий.
var fire: RefCounted
var last_day := 0
var revision := 0
var last_event: Dictionary = {}


func _init(map: RefCounted, water: RefCounted,
		ground: RefCounted, weather: RefCounted) -> void:
	world = map
	hydro = water
	surface = ground
	climate = weather


func estimate_at(cell: Vector2i) -> Dictionary:
	if not world.config.contains_cell(cell):
		return {}
	hydro.ensure_ready()
	surface.ensure_ready()
	climate.ensure_ready()
	var i: int = hydro.cell_index(cell)
	if hydro.ocean_at(i) or hydro.lake_at(i):
		return {}
	var from_height: float = world.vertex_at(cell)
	var next: Vector2i = hydro.cell_from_index(hydro.downstream_of(i))
	var drop := 0.0
	if world.config.contains_cell(next) and not hydro.ocean_at(hydro.cell_index(next)):
		drop = maxf(0.0, from_height - world.vertex_at(next))
	var moisture: float = surface.moisture_at_index(i)
	var snow: float = surface.snow_at_index(i)
	var depth: float = surface.soil_depth_at_index(i)
	var runoff: float = surface.runoff_at_index(i)
	var flow: float = hydro.discharge_at_index(i)
	var resistant := 0.0 if surface.rock_at_index(i) else 1.0
	# Пепел может уйти с дождевым стоком раньше восстановления
	# повреждённой почвы. Оба физических следа пожара повышают
	# уязвимость грунта независимо от камеры и текущих эффектов.
	var fire_exposure := 0.0
	if fire != null:
		var ash_exposure: float = clampf(fire.scorched_at(cell), 0.0, 1.0)
		var soil_exposure: float = clampf(fire.soil_damage_at(cell), 0.0, 1.0)
		# Берём более сильный след вместо суммы: двойной учёт одного
		# пожара не должен увеличивать предел риска свыше 1.75.
		fire_exposure = maxf(ash_exposure, soil_exposure)
	var exposure_multiplier := 1.0 + fire_exposure * 0.75
	# Сопоставимая шкала рисков: речной поток может переносить грунт
	# даже при небольшом уклоне, а не всегда проигрывать ветру.
	var water_risk := clampf(2.5 * resistant \
		* clampf(drop / 0.45, 0.0, 1.0) \
		* clampf((flow - 1.0) / 12.0, 0.0, 1.0) \
		* clampf(0.20 + moisture * 0.5 + runoff * 0.65, 0.0, 1.0) \
		* surface.erosion_risk_at_index(i) * exposure_multiplier, 0.0, 1.0)
	var wind_speed: float = climate.wind_at_index(i)
	var exposed: bool = surface.exposed_at_index(i)
	var east := cell + Vector2i(1, 0)
	var wind_risk := 0.0
	if exposed and snow < 0.08 and moisture < 0.32 \
			and world.config.contains_cell(east) \
			and not hydro.has_water(hydro.cell_index(east)):
		wind_risk = clampf(clampf((wind_speed - 7.0) / 10.0, 0.0, 1.0) \
			* clampf((0.32 - moisture) / 0.32, 0.0, 1.0) \
			* clampf(depth, 0.0, 1.0) * exposure_multiplier, 0.0, 1.0)
	var slide_risk := clampf(clampf((drop - 0.8) / 3.0, 0.0, 1.0) \
		* clampf((moisture - 0.62) / 0.38, 0.0, 1.0) \
		* clampf(depth / 1.2, 0.0, 1.0) * exposure_multiplier, 0.0, 1.0)
	# Берег разрушается только там, где суша соприкасается с морем.
	var coast_target := Vector2i(-1, -1)
	for offset in [Vector2i(-1, 0), Vector2i(1, 0),
			Vector2i(0, -1), Vector2i(0, 1)]:
		var neighbor: Vector2i = cell + offset
		if world.config.contains_cell(neighbor) \
				and hydro.ocean_at(hydro.cell_index(neighbor)):
			coast_target = neighbor
			break
	# Наносы в устье оседают на мелководье и со временем
	# могут поднять дно до уровня новой суши.
	var delta_risk := 0.0
	var delta_target := Vector2i(-1, -1)
	if hydro.river_mouth_at(i) and depth > 0.05:
		delta_target = next
		delta_risk = resistant \
			* clampf(flow / 280.0, 0.0, 1.0) \
			* clampf(depth / 1.0, 0.0, 1.0) \
			* clampf(1.0 + runoff * 0.2, 0.0, 1.0)
	var coast_risk := 0.0
	if coast_target.x >= 0 and resistant > 0.0:
		coast_risk = clampf((wind_speed - 6.0) / 12.0, 0.0, 1.0) \
			* clampf(depth / 1.4, 0.0, 1.0) \
			* (1.0 - snow * 0.7) * resistant
	return {
		"water": water_risk, "wind": wind_risk,
		"slide": slide_risk, "coast": coast_risk, "delta": delta_risk,
		"downstream": next, "wind_target": east,
		"coast_target": coast_target, "delta_target": delta_target,
		"drop": drop, "fire_exposure": fire_exposure
	}


func advance_day(day: int) -> Dictionary:
	# Календарь не двигается здесь: он уже передан климатом и почвой.
	if day <= last_day or day != climate.day or day != surface.day:
		return {}
	last_day = day
	if day % STEP_DAYS != 0:
		return {}
	var count: int = world.config.width * world.config.height
	var offset := posmod(day * 997 + world.config.world_seed * 31, count)
	var best_score := 0.0
	var best: Dictionary = {}
	for step in range(mini(SAMPLE_COUNT, count)):
		var i := posmod(offset + step * SAMPLE_STRIDE, count)
		var sample_cell := Vector2i(i % world.config.width, i / world.config.width)
		var risk: Dictionary = estimate_at(sample_cell)
		if risk.is_empty():
			continue
		for kind in ["water", "wind", "slide", "coast", "delta"]:
			var score: float = risk[kind]
			if kind == "delta" and day % 8 != 0:
				continue
			if kind == "coast" and day % 12 != 0:
				continue
			if kind == "slide" and day % 24 != 0:
				continue
			if score > best_score:
				best_score = score
				best = {"kind": kind, "cell": sample_cell, "risk": risk}
	if best_score < 0.045:
		return {}
	var kind: String = best["kind"]
	var cell: Vector2i = best["cell"]
	var result := {}
	if kind == "slide":
		result = Landscape.new(world).apply("оползень",
			Vector2(cell) + Vector2(0.5, 0.5), 5.0,
			clampf(best_score * 0.18, 0.03, 0.18))
	else:
		result = _move_sediment(best)
	if result.is_empty():
		return {}
	# Только реальная геологическая деформация передаёт силу в
	# NatureRegistry: для обычного речного переноса грунта урона
	# лесу нет. Показатель — исходный физический риск участка.
	if kind == "slide" and int(result.get("vertices", 0)) > 0:
		result["severity"] = clampf(best_score, 0.0, 1.0)
	result["process"] = kind
	result["cell"] = cell
	result["day"] = day
	revision += 1
	last_event = result.duplicate()
	process_applied.emit(kind, cell, day)
	return result


func _move_sediment(plan: Dictionary) -> Dictionary:
	var kind: String = plan["kind"]
	var source: Vector2i = plan["cell"]
	var risk: Dictionary = plan["risk"]
	var target: Vector2i = risk["downstream"] if kind == "water" else (
		risk["coast_target"] if kind == "coast" else (
			risk["delta_target"] if kind == "delta" else risk["wind_target"]))
	if not world.config.contains_vertex(target) or source == target:
		return {}
	var a: float = world.vertex_at(source)
	var b: float = world.vertex_at(target)
	var amount := clampf(float(risk[kind]) * 0.012, 0.001, 0.012)
	if kind == "water":
		amount = minf(amount, maxf(0.0, a - b) * 0.20)
	if amount < 0.0005:
		return {}
	# Surface проверяет наличие грунта, меняет геометрию одним пакетом
	# и сохраняет происхождение нанесённого/снятого материала.
	if not surface.transfer_sediment(source, target, amount):
		return {}
	var description := "водная эрозия"
	if kind == "wind":
		description = "ветровой перенос"
	elif kind == "coast":
		description = "береговая эрозия"
	elif kind == "delta":
		description = "формирование речной дельты"
	return {
		"kind": description, "vertices": 2,
		"volume": amount, "revision": world.revision
	}


func to_data() -> Dictionary:
	return {
		"version": FORMAT_VERSION,
		"world_signature": JSON.stringify(world.to_data()),
		"last_day": last_day
	}


func load_data(data: Dictionary) -> bool:
	if data.get("version") != FORMAT_VERSION \
			or data.get("world_signature") != JSON.stringify(world.to_data()):
		return false
	if not (data.get("last_day") is int or data.get("last_day") is float):
		return false
	var value := float(data["last_day"])
	if not is_finite(value) or value < 0.0 or value > 10000000.0 \
			or value != float(int(value)):
		return false
	if int(value) > climate.day or int(value) > surface.day:
		return false
	last_day = int(value)
	return true
