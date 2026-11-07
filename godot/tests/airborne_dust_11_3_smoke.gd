extends SceneTree
## 11.3/V2.10: часть реального грунта временно переносится в воздухе.
## Сверяем баланс Surface + воздушный реестр, вектор Climate,
## выпадение в дождь, старые сохранения и полную загрузку WorldSave.

const Config = preload("res://scripts/world_config.gd")
const Map = preload("res://scripts/world_map.gd")
const Hydro = preload("res://scripts/hydrology.gd")
const Surface = preload("res://scripts/surface.gd")
const Climate = preload("res://scripts/climate.gd")
const Disasters = preload("res://scripts/natural_disasters.gd")
const Weather = preload("res://scripts/weather_events.gd")
const Processes = preload("res://scripts/natural_processes.gd")
const Runner = preload("res://scripts/world_day_runner.gd")
const Save = preload("res://scripts/world_save.gd")

var failures: Array[String] = []


func _check(ok: bool, description: String) -> void:
	# Проверяем отдельные контракты; при регрессии тест сообщает
	# не только факт ошибки, но и нарушенный физический инвариант.
	if not ok:
		failures.append(description)


func _setup() -> Dictionary:
	# Строим реальную географию из фиксированного seed. Все
	# последующие изменения массы производят только Surface и
	# NaturalDisasters, не тестовая ручная правка вершин.
	var world := Map.new(Config.new(96, 80, 1729, 16, 32))
	var hydro := Hydro.new(world)
	hydro.rebuild()
	var surface := Surface.new(world, hydro)
	surface.rebuild()
	var climate := Climate.new(world, hydro)
	climate.rebuild()
	climate.set_day(2)
	surface.advance_climate_day(climate)
	surface._moisture.fill(0.025)
	surface._snow.fill(0.0)
	surface._frost.fill(0.0)
	climate._wind.fill(34.0)
	climate._rain.fill(0.0)
	climate._storm.fill(0.0)
	var disasters := Disasters.new(world, hydro, surface, climate)
	disasters.last_day = 2
	return {"world": world, "hydro": hydro,
		"surface": surface, "climate": climate, "disasters": disasters}


func _dry_source(state: Dictionary) -> Vector2i:
	# Для двухшаговой аэродинамики ищем сухой коридор
	# непосредственно в физическом мире, не жёстко заданную
	# координату, которая может оказаться под водой.
	var world: RefCounted = state["world"]
	var hydro: RefCounted = state["hydro"]
	var climate: RefCounted = state["climate"]
	var disasters: RefCounted = state["disasters"]
	for y in range(8, 72):
		for x in range(8, 88):
			var cell := Vector2i(x, y)
			if not disasters.dust_source_ready(cell):
				continue
			var direction: Vector2 = climate.wind_direction_at_index(
				hydro.cell_index(cell))
			var offset := Vector2i(roundi(direction.x * 3.0),
				roundi(direction.y * 3.0))
			var middle: Vector2i = cell + offset
			var final: Vector2i = middle + offset
			if not world.config.contains_cell(final):
				continue
			if disasters.dust_source_ready(middle) and not hydro.has_water(
					hydro.cell_index(final)):
				return cell
	return Vector2i(-1, -1)


func _test_airborne() -> void:
	# Часть перемещённого грунта временно отсутствует в Surface,
	# но существует в реестре взвеси. Никакого второго запаса
	# физической массы из визуального эмиттера не возникает.
	var state := _setup()
	var world: RefCounted = state["world"]
	var hydro: RefCounted = state["hydro"]
	var surface: RefCounted = state["surface"]
	var climate: RefCounted = state["climate"]
	var disasters: RefCounted = state["disasters"]
	var source := _dry_source(state)
	_check(source.x >= 0, "Найден сухой ветровой коридор")
	if source.x < 0:
		return
	var initial_balance: float = surface.sediment_balance()
	var impact: Dictionary = disasters.apply_dust_storm(source, 1.0)
	var airborne: float = disasters.airborne_volume()
	_check(float(impact.get("sediment_volume", 0.0)) > airborne
		and airborne > 0.0005 and airborne < 0.01,
		"Доля реального грунта поднята в ограниченный воздушный реестр")
	_check(is_equal_approx(airborne,
		float(impact.get("airborne_volume", -1.0))),
		"Физическое событие точно сообщает массу взвеси графике")
	_check(absf(surface.sediment_balance() + airborne -
		initial_balance) < 0.00002,
		"Грунт и взвесь вместе сохраняют полный объём")

	# Реестр переживает самостоятельное сохранение и отвергает
	# повреждённые значения без частичной записи в живой объект.
	var saved: Dictionary = JSON.parse_string(JSON.stringify(disasters.to_data()))
	var copy := Disasters.new(world, hydro, surface, climate)
	var loaded_v2: bool = copy.load_data(saved)
	var equal_v2: bool = loaded_v2 and copy.to_data() == disasters.to_data()
	if not equal_v2:
		# Здесь различаем отказ строгого JSON и погрешность при
		# обратном кодировании микродолей воздушной массы.
		printerr("11.3/V2.10 диагностика v2: load=", loaded_v2,
			" last_day=", disasters.last_day, " climate=", climate.day,
			" surface=", surface.day, " air=", saved.get("airborne_dust"),
			" roundtrip=", copy.to_data().get("airborne_dust"))
	_check(equal_v2, "Масса и возраст облаков переживают формат бедствий v2")
	var before_bad: String = JSON.stringify(copy.to_data())
	var broken := saved.duplicate(true)
	broken["airborne_dust"] = [[-1, 0, 2000, 2]]
	_check(not copy.load_data(broken) and
		JSON.stringify(copy.to_data()) == before_bad,
		"Невозможные координаты пыли отвергаются атомарно")
	broken = saved.duplicate(true)
	broken["airborne_dust"] = [[source.x, source.y, 100000, 2]]
	_check(not copy.load_data(broken),
		"Невозможный запас аэрозоля не принимается из JSON")

	# Миграция настоящего прежнего формата: в нём воздушной
	# фракции ещё не было, поэтому старое сохранение не должно
	# порождать её искусственно после загрузки.
	var old := saved.duplicate(true)
	old["version"] = 1
	old.erase("airborne_dust")
	for event in old["last_events"]:
		if event.size() == 10:
			event.pop_back()
	var legacy := Disasters.new(world, hydro, surface, climate)
	var loaded_v1: bool = legacy.load_data(old)
	if not loaded_v1:
		printerr("11.3/V2.10 диагностика v1: version=", old.get("version"),
			" last_day=", old.get("last_day"),
			" air=", old.get("airborne_dust", "отсутствует"))
	_check(loaded_v1 and legacy.airborne_volume() == 0.0,
		"Сохранения стихийных бедствий v1 загружаются без выдуманной пыли")

	# Полный WorldSave обязан восстановить высоты, Surface и
	# отсутствующую в нём массу из одного согласованного снимка.
	var weather := Weather.new(world, climate, surface, hydro)
	var processes := Processes.new(world, hydro, surface, climate)
	var runner := Runner.new(world, hydro, surface, climate,
		weather, processes, disasters)
	_check(runner.synchronize_world(), "Геометрия и почва согласованы до сохранения")
	var captured: Dictionary = Save.capture({
		"world": world, "hydro": hydro, "surface": surface,
		"climate": climate, "weather": weather,
		"natural": processes, "disasters": disasters
	})
	if captured.is_empty():
		printerr("11.3/V2.10 диагностика WorldSave: day=", climate.day,
			"/", surface.day, " rev=", world.revision,
			" hydro=", hydro._terrain_revision,
			" surface=", surface._terrain_revision,
			" climate=", climate._terrain_revision,
			" weather_day=", weather.last_day,
			" natural_day=", processes.last_day,
			" disasters_day=", disasters.last_day)
	_check(not captured.is_empty(),
		"Полный WorldSave фиксирует одновременные грунт и взвесь")
	if captured.is_empty():
		return
	var restored: Dictionary = Save.restore(
		JSON.parse_string(JSON.stringify(captured)))
	_check(not restored.is_empty(),
		"Полная загрузка WorldSave восстанавливает воздушную пыль")
	if restored.is_empty():
		return
	var fresh: RefCounted = restored["disasters"]
	var fresh_surface: RefCounted = restored["surface"]
	_check(absf(fresh.airborne_volume() - airborne) < 0.000002,
		"Объём пыли не удваивается после перезапуска")
	_check(absf(fresh_surface.sediment_balance() +
		fresh.airborne_volume() - initial_balance) < 0.00002,
		"Полный баланс переносится между игровыми запусками")

	# Реальный дождь быстро осаждает остаток воздушной массы.
	# Не вызываем визуальную анимацию для изменения почвы.
	var fresh_climate: RefCounted = restored["climate"]
	fresh_climate.set_day(3)
	fresh_climate._wind.fill(0.0)
	fresh_climate._rain.fill(1.4)
	fresh_climate._storm.fill(0.0)
	fresh_surface.advance_climate_day(fresh_climate)
	fresh.advance_day(3)
	_check(fresh.airborne_volume() < 0.0000005,
		"Дождь полностью осаждает реальную взвесь")
	_check(absf(fresh_surface.sediment_balance() - initial_balance) < 0.00002,
		"После осаждения прежняя масса возвращается в грунт")
	var after := JSON.stringify(fresh_surface.to_data())
	_check(fresh.advance_day(3).is_empty()
		and JSON.stringify(fresh_surface.to_data()) == after,
		"Повтор суток не создаёт дополнительного осадка")


func _run() -> void:
	# Единая проверка охватывает физику, миграцию, сохранение и
	# осаждение, но не подменяет аппаратную приёмку эффектов.
	_test_airborne()
	if failures.is_empty():
		print("Этап 11.3/V2.10: воздушный баланс, осаждение, JSON v1/v2 — успешно")
		quit(0)
		return
	for error in failures:
		printerr("11.3/V2.10: ", error)
	quit(1)


func _initialize() -> void:
	# SceneTree создаётся перед тестом совместимых моделей.
	call_deferred("_run")
