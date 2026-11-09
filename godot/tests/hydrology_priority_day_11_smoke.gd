extends SceneTree
## 11/HYDRO-DAY: полный физический день с исходной и новой
## очередью Priority-Flood, без подмены других моделей.
## Сравниваем удалённые реки, события и весь WorldSave.

const Config = preload("res://scripts/world_config.gd")
const Map = preload("res://scripts/world_map.gd")
const Hydro = preload("res://scripts/hydrology.gd")
const OldHydro = preload("res://tests/hydrology_priority_legacy.gd")
const Surface = preload("res://scripts/surface.gd")
const Climate = preload("res://scripts/climate.gd")
# Один и тот же действующий климат для двух независимых миров.
const Nature = preload("res://scripts/nature_registry.gd")
const Fire = preload("res://scripts/fire_registry.gd")
const Weather = preload("res://scripts/weather_events.gd")
const Processes = preload("res://scripts/natural_processes.gd")
const Disasters = preload("res://scripts/natural_disasters.gd")
const Runner = preload("res://scripts/world_day_runner.gd")
const Save = preload("res://scripts/world_save.gd")

const SIZE := Vector2i(256, 192)
const SEED := 1729
const RUN_DAYS := 4
const SNAPSHOT_KEYS := [
	"version", "day", "world", "hydrology", "climate", "surface",
	"weather", "natural", "disasters", "nature", "fire"
]
var failures: Array[String] = []


func _check(condition: bool, reason: String) -> void:
	# Несовпадение физики и недостаточное ускорение — разные
	# причины отказа. Не прекращаем сравнение после первой.
	if not condition:
		failures.append(reason)


func _make_state(old_formula: bool) -> Dictionary:
	# Все модели создаются обычным игровым порядком. Разница
	# исключительно в реализации приоритетной очереди гидрологии,
	# которая обеспечивает глобальный маршрут каждой реки.
	var world := Map.new(Config.new(SIZE.x, SIZE.y, SEED, 16, 32))
	var hydro: RefCounted = OldHydro.new(world) if old_formula else Hydro.new(world)
	hydro.rebuild()
	var surface := Surface.new(world, hydro)
	surface.rebuild()
	var climate := Climate.new(world, hydro)
	climate.rebuild()
	_check(climate.set_day(1), "Климат исходного дня установлен")
	_check(surface.advance_climate_day(climate), "Почва исходного дня обновлена")
	_check(hydro.apply_rainfall_map(surface.runoff_map()),
		"Водосбор получил исходные осадки")
	var nature := Nature.new(world, hydro, surface, climate)
	_check(nature.generate(), "Настоящая растительность сгенерирована")
	var weather := Weather.new(world, climate, surface, hydro)
	var natural := Processes.new(world, hydro, surface, climate)
	var disasters := Disasters.new(world, hydro, surface, climate)
	var fire := Fire.new(world, hydro, surface, climate, nature)
	var runner := Runner.new(world, hydro, surface, climate,
		weather, natural, disasters, nature, fire)
	return {"world": world, "hydro": hydro, "surface": surface,
		"climate": climate, "nature": nature, "fire": fire,
		"weather": weather, "natural": natural,
		"disasters": disasters, "runner": runner}


func _record_day(state: Dictionary, totals: Dictionary,
		profile: Dictionary) -> void:
	# Время каждого этапа снимаем из реального WorldDayRunner,
	# а не складываем оценочные коэффициенты из разных карт.
	var runner: RefCounted = state["runner"]
	var duration: int = runner.last_duration_us
	var stages: Dictionary = runner.last_profile_us
	var measured := 0
	for stage in stages:
		var elapsed: int = stages[stage]
		measured += elapsed
		profile[stage] = int(profile.get(stage, 0)) + elapsed
	_check(duration > 0 and measured <= duration + 1000,
		"Профиль суток не содержит двойного учёта времени")
	totals["us"] = int(totals.get("us", 0)) + duration
	totals["slowest_us"] = maxi(int(totals.get("slowest_us", 0)), duration)


func _packed_bytes(value: Variant) -> PackedByteArray:
	# NaN сухого участка и точные значения float32 необходимо
	# сравнить побитово, иначе разные водные поверхности могут
	# незаметно пройти обычное численное сравнение.
	return value if value is PackedByteArray else value.to_byte_array()


func _verify_physics(old: Dictionary, current: Dictionary,
		day: int) -> void:
	# Контролируем все клетки гидрологии, не только устье возле
	# геологического события; удалённые изменения тоже важны.
	var hydro_a: RefCounted = old["hydro"]
	var hydro_b: RefCounted = current["hydro"]
	for field in ["_ground", "_spill", "_downstream", "_outlet",
			"_order", "_rank", "_catchment", "_discharge", "_local_rain",
			"_ocean", "_lake", "_river", "_flood", "_water_level", "_wetness"]:
		_check(_packed_bytes(hydro_a.get(field)) ==
			_packed_bytes(hydro_b.get(field)),
			"Гидрологическое поле %s на дне %d" % [field, day])
	_check(hydro_a._summary == hydro_b._summary,
		"Реки и озёра совпадают на дне %d" % day)
	var a: RefCounted = old["climate"]
	var b: RefCounted = current["climate"]
	_check(a._temperature == b._temperature
		and a._rain == b._rain and a._wind == b._wind
		and a._storm == b._storm,
		"Погода всех клеток совпадает на дне %d" % day)
	_check(old["runner"].last_result == current["runner"].last_result,
		"Реальные события совпадают на дне %d" % day)
	_check(old["runner"].last_statistics == current["runner"].last_statistics,
		"Полные и частичные перестройки совпадают на дне %d" % day)


func _verify_snapshot(old: Dictionary, current: Dictionary) -> void:
	# Подлинный WorldSave сравниваем только после последнего
	# физического дня, чтобы сериализация не попадала в
	# измеряемое время и не влияла на сравнение CPU.
	var before: Dictionary = Save.capture(old)
	var after: Dictionary = Save.capture(current)
	_check(not before.is_empty() and not after.is_empty(),
		"Оба независимых физических мира допускают WorldSave")
	for key in SNAPSHOT_KEYS:
		_check(before.has(key) and after.has(key)
			and before.get(key) == after.get(key),
			"Физический слой WorldSave без изменений: " + str(key))
	print("HYDRO-DAY: WorldSave совпадает по ", SNAPSHOT_KEYS.size(),
		" физическим секциям")


func _run() -> void:
	# Порядок «старый → новый» на нечётном шаге и обратный
	# на чётном исключает систематическое преимущество второй
	# реализации из-за прогрева CPU и кеша инструкций.
	var old: Dictionary = _make_state(true)
	var current: Dictionary = _make_state(false)
	var old_total := {}
	var new_total := {}
	var old_stages := {}
	var new_stages := {}
	for step in range(RUN_DAYS):
		if step % 2 == 0:
			old["runner"].run_day()
			_record_day(old, old_total, old_stages)
			current["runner"].run_day()
			_record_day(current, new_total, new_stages)
		else:
			current["runner"].run_day()
			_record_day(current, new_total, new_stages)
			old["runner"].run_day()
			_record_day(old, old_total, old_stages)
		_verify_physics(old, current, int(current["climate"].day))
		# Для поиска остаточного фриза печатаем отдельные сутки.
		# Агрегированные четыре дня скрывают краткий геологический
		# перерасчёт, который пользователь ощущает как остановку.
		print("HYDRO-DAY/STEP: день=", current["climate"].day,
			", старый=", old["runner"].last_duration_us,
			" мкс, новый=", current["runner"].last_duration_us,
			" мкс, стадии=", current["runner"].last_profile_us,
			", события=", current["runner"].last_result["hazards"].size(),
			", статистика=", current["runner"].last_statistics,
			", эрозия_поэтапно=", current["natural"].last_profile_us,
			", бедствия_поэтапно=", current["disasters"].last_profile_us)

	_verify_snapshot(old, current)
	var old_us: int = old_total.get("us", 0)
	var new_us: int = new_total.get("us", 0)
	var ratio := float(new_us) / float(maxi(1, old_us))
	print("HYDRO-DAY: seed=", SEED, ", карта=", SIZE,
		", дней=", RUN_DAYS, ", старый мир=", old_us,
		" мкс, новый=", new_us, " мкс, отношение=", ratio)
	print("HYDRO-DAY: старые стадии=", old_stages)
	print("HYDRO-DAY: новые стадии=", new_stages)
	print("HYDRO-DAY: пик старый=", old_total.get("slowest_us", 0),
		" мкс, новый=", new_total.get("slowest_us", 0), " мкс")
	# Само ускорение требуется проверить целиком, а не
	# объявлять полным из-за успеха отдельно взятого климата.
	_check(ratio < 0.97,
		"Реальный WorldDayRunner не ускорился хотя бы на 3%")
	if not failures.is_empty():
		for failure in failures.slice(0, 25):
			push_error("HYDRO-DAY: " + failure)
		print("HYDRO-DAY: нарушений=", failures.size())
		quit(1)
		return
	print("HYDRO-DAY: весь физический день, WorldSave и точность — успешно")
	quit(0)


func _initialize() -> void:
	call_deferred("_run")
