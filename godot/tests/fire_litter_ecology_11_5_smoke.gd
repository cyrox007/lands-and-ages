extends SceneTree
## 11.5: восстановление конечной подстилки только при живом покрове,
## подходящем климате и отсутствии физического затопления.

const Config = preload("res://scripts/world_config.gd")
const Map = preload("res://scripts/world_map.gd")
const Hydro = preload("res://scripts/hydrology.gd")
const Surface = preload("res://scripts/surface.gd")
const Climate = preload("res://scripts/climate.gd")
const Nature = preload("res://scripts/nature_registry.gd")
const Fire = preload("res://scripts/fire_registry.gd")
const Weather = preload("res://scripts/weather_events.gd")
const Processes = preload("res://scripts/natural_processes.gd")
const Disasters = preload("res://scripts/natural_disasters.gd")
const Save = preload("res://scripts/world_save.gd")

var failures: Array[String] = []


func _check(ok: bool, message: String) -> void:
    # Ошибки независимы: собираем все нарушения массы, календаря,
    # климатической реакции и сохранений в одном CI-отчёте.
    if not ok:
        failures.append(message)


func _models() -> Dictionary:
    # Используем действительную карту с лесом, природным грунтом
    # и гидрологией: тест не подставляет фиктивный источник топлива.
    var world := Map.new(Config.new(96, 80, 1729, 16, 32))
    var hydro := Hydro.new(world)
    hydro.rebuild()
    var surface := Surface.new(world, hydro)
    surface.rebuild()
    var climate := Climate.new(world, hydro)
    climate.rebuild()
    climate.set_day(1)
    surface.advance_climate_day(climate)
    hydro.apply_rainfall_map(surface.runoff_map())
    var nature := Nature.new(world, hydro, surface, climate)
    _check(nature.generate(), "Настоящий лес создан")
    surface._moisture.fill(0.02)
    surface._snow.fill(0.0)
    climate._rain.fill(0.0)
    return {
        "world": world, "hydro": hydro, "surface": surface,
        "climate": climate, "nature": nature,
        "fire": Fire.new(world, hydro, surface, climate, nature)
    }


func _reserve_at(fire: RefCounted, index: int) -> int:
    # Читаем публичное сериализуемое состояние, а не подменяем
    # реестр подстилки внутренним словарём тестовой заглушки.
    for entry in fire.to_data()["litter_remaining"]:
        if int(entry[0]) == index:
            return int(entry[1])
    return -1


func _find_cell(m: Dictionary) -> Vector2i:
    # Пробное воспламенение проверяет наличие настоящей подстилки
    # у живого дерева; после каждой пробы состояние возвращаем.
    var fire: RefCounted = m["fire"]
    var nature: RefCounted = m["nature"]
    var initial: Dictionary = fire.to_data()
    for entry in nature.to_data()["objects"]:
        if entry[1] != "дерево" or entry[9] != "целое":
            continue
        var cell := Vector2i(int(entry[3]), int(entry[4]))
        if not fire._ignite_litter(cell, {}):
            continue
        var available: int = _reserve_at(fire,
            m["hydro"].cell_index(cell))
        _check(fire.load_data(initial), "Проба воспламенения отменена")
        if available >= 100:
            return cell
    return Vector2i(-1, -1)


func _day(m: Dictionary, day: int, moisture: float,
        temperature: float, snow: float, flooded: bool,
        index: int) -> void:
    # Климат и природа переходят на новые физические сутки перед
    # пожарным реестром, как в обычном WorldDayRunner.
    var climate: RefCounted = m["climate"]
    var surface: RefCounted = m["surface"]
    var hydro: RefCounted = m["hydro"]
    _check(climate.set_day(day), "Климат перешёл на сутки %d" % day)
    _check(surface.advance_climate_day(climate),
        "Почва перешла на сутки %d" % day)
    # Управляем только условиями тестовой клетки; дни и реестры
    # по-прежнему настоящие, восстановление происходит в advance_day.
    surface._moisture.fill(moisture)
    surface._air_temperature.fill(temperature)
    surface._snow.fill(snow)
    climate._rain.fill(0.0)
    if flooded:
        hydro._flood[index] = 1
    m["nature"].advance_day(day)
    m["fire"].advance_day(day)
    if flooded:
        # Контролируемый разлив спал; в будущем тесте нет воды.
        hydro._flood[index] = 0


func _test_gain_formula() -> void:
    # У нулевой биомассы или на мёртвой почве нет даже одной
    # гарантированной порции. На полноценной — не более четырёх.
    var cell := Vector2i(19, 27)
    var total := 0
    for day in range(1, 366):
        _check(Fire.litter_daily_gain(0.0, 1.0, cell, day, 1729) == 0
            and Fire.litter_daily_gain(1.0, 0.0, cell, day, 1729) == 0,
            "Нулевой рост или покров не создаёт биомассу")
        _check(Fire.litter_daily_gain(1.0, 1.0, cell, day, 1729) == 4,
            "Благоприятный предел составляет четыре единицы")
        var gain: int = Fire.litter_daily_gain(0.02, 0.80,
            cell, day, 1729)
        _check(gain >= 0 and gain <= 1
            and gain == Fire.litter_daily_gain(0.02, 0.80,
                cell, day, 1729),
            "Дробный рост ограничен и воспроизводим по seed и суткам")
        total += gain
    # 365 × 4 × 0.02 × 0.8 ≈ 23 единицы. Проверяем порядок
    # величины, не делая тест зависимым от точного хеш-распределения.
    _check(total >= 7 and total <= 50,
        "Редкая растительность наращивает конечный, а не ежедневный полный запас")


func _test_physical_calendar() -> void:
    var m: Dictionary = _models()
    var cell: Vector2i = _find_cell(m)
    _check(cell.x >= 0, "Найден настоящий лесной участок")
    if cell.x < 0:
        return
    var fire: RefCounted = m["fire"]
    var index: int = m["hydro"].cell_index(cell)
    # Выгоревший запас равен нулю, но сам физический лес не удалён.
    # Так исключаем новую массу через первое воспламенение.
    var burned: Dictionary = fire.to_data()
    burned["litter_remaining"] = [[index, 0]]
    _check(fire.load_data(burned), "Нулевой остаток принят строгим JSON v8")

    # Засуха с нулевым потенциалом, зима и паводок не пополняют
    # топливо даже при отсутствии активных углей.
    _day(m, 2, 0.02, 20.0, 0.0, false, index)
    _check(_reserve_at(fire, index) == 0, "Засуха не создаёт подстилку")
    _day(m, 3, 0.45, -18.0, 1.0, false, index)
    _check(_reserve_at(fire, index) == 0, "Зима не создаёт подстилку")
    _day(m, 4, 0.45, 20.0, 0.0, true, index)
    _check(_reserve_at(fire, index) == 0, "Паводок не создаёт подстилку")

    var previous := 0
    for day in range(5, 31):
        _day(m, day, 0.45, 20.0, 0.0, false, index)
        var now: int = _reserve_at(fire, index)
        _check(now >= previous and now <= previous + 4,
            "Суточный прирост не превышает природный предел")
        previous = now
    _check(previous > 0 and previous < 104,
        "Живой лес восстанавливается постепенно после благоприятных суток")
    var after: Dictionary = fire.to_data()
    _check(fire.advance_day(30).is_empty() and fire.to_data() == after,
        "Дублирование суток не увеличивает запас")
    _check(fire.charcoal_total() == 0 and fire.ash_mass_total() == 0,
        "Восстановление биомассы не создаёт уголь и золу")

    # Проверяем точную сериализацию целого мира, а не только
    # самостоятельного пожарного словаря.
    var state := {
        "world": m["world"], "hydro": m["hydro"],
        "surface": m["surface"], "climate": m["climate"],
        "nature": m["nature"], "fire": fire,
        "weather": Weather.new(m["world"], m["climate"],
            m["surface"], m["hydro"]),
        "natural": Processes.new(m["world"], m["hydro"],
            m["surface"], m["climate"]),
        "disasters": Disasters.new(m["world"], m["hydro"],
            m["surface"], m["climate"])
    }
    var snapshot: Dictionary = Save.capture(state)
    _check(not snapshot.is_empty(), "Естественный запас сохранён в WorldSave")
    if snapshot.is_empty():
        return
    var restored: Dictionary = Save.restore(
        JSON.parse_string(JSON.stringify(snapshot)))
    _check(not restored.is_empty(), "Мир с восстановленной подстилкой загружен")
    if restored.is_empty():
        return
    _check(restored["fire"].to_data() == after,
        "После загрузки запас, календарь и ресурсы совпадают")
    for day in range(31, 37):
        # Два мира получают одинаковые физические условия.
        # Совпадение итогов доказывает детерминизм после загрузки.
        _day(m, day, 0.45, 20.0, 0.0, false, index)
        _day(restored, day, 0.45, 20.0, 0.0, false, index)
        _check(m["fire"].to_data() == restored["fire"].to_data(),
            "Суточное восстановление совпадает после WorldSave")


func _run() -> void:
    # Итог принимаем только при соблюдении всех проверок живой
    # подстилки, источника роста, годового хеша и сохранений.
    _test_gain_formula()
    _test_physical_calendar()
    if not failures.is_empty():
        for message in failures:
            printerr("11.5/ECO: ", message)
        quit(1)
        return
    print("11.5/ECO: климат, покров, паводок, 36 суток и WorldSave — успешно")
    quit(0)


func _initialize() -> void:
    # SceneTree даёт доступ к физическим RefCounted-моделям Godot.
    call_deferred("_run")
