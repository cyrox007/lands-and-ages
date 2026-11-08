extends SceneTree
## 11.5: остаток лесной подстилки переживает дождь, JSON и повторный пожар.

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
    # Записываем каждую отдельную ошибку: для физической модели
    # важно увидеть, где нарушились топливо, календарь или JSON.
    if not ok:
        failures.append(message)


func _models() -> Dictionary:
    # Подстилку испытываем на настоящей географии и растительности.
    # Никаких придуманных клеток с безусловной горючестью нет.
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
    _check(nature.generate(), "Физическая растительность создана")
    surface._moisture.fill(0.02)
    surface._snow.fill(0.0)
    climate._rain.fill(0.0)
    return {
        "world": world, "hydro": hydro, "surface": surface,
        "climate": climate, "nature": nature,
        "fire": Fire.new(world, hydro, surface, climate, nature)
    }


func _litter_in_cell(data: Dictionary, cell_index: int) -> int:
    # Читаем сериализованный конечный запас, а не внутренний объект.
    # Нулевой остаток — тоже запись: он запрещает создание топлива.
    for entry in data["litter_remaining"]:
        if int(entry[0]) == cell_index:
            return int(entry[1])
    return -1


func _ember_in_cell(data: Dictionary, cell_index: int) -> int:
    # Тёплые угли существуют отдельно от негорящего запаса.
    for entry in data["embers"]:
        if int(entry[0]) == cell_index:
            return int(entry[1])
    return -1


func _advance(m: Dictionary, day: int, moisture: float) -> void:
    # Проходим настоящий календарь мира, затем переопределяем
    # влажность контрольного участка для детерминированного дождя.
    var climate: RefCounted = m["climate"]
    var surface: RefCounted = m["surface"]
    climate.set_day(day)
    _check(surface.advance_climate_day(climate),
        "Поверхность обновлена в сутки %d" % day)
    surface._moisture.fill(moisture)
    surface._snow.fill(0.0)
    climate._rain.fill(0.0)
    m["nature"].advance_day(day)


func _test_reserve() -> void:
    var m: Dictionary = _models()
    var fire: RefCounted = m["fire"]
    var nature: RefCounted = m["nature"]
    var hydro: RefCounted = m["hydro"]
    var dry: Dictionary = fire.to_data()
    var cell := Vector2i(-1, -1)
    var original_fuel := 0

    # Ищем настоящий лесной участок с большим начальным запасом.
    # Каждое пробное зажигание откатываем строгим снимком мира.
    for record in nature.to_data()["objects"]:
        if record[1] != "дерево" or record[9] != "целое":
            continue
        var probe := Vector2i(int(record[3]), int(record[4]))
        if not fire._ignite_litter(probe, {}):
            continue
        var fuel: int = _litter_in_cell(fire.to_data(),
            hydro.cell_index(probe))
        _check(fire.load_data(dry), "Пробное зажигание полностью сброшено")
        if fuel >= 160:
            cell = probe
            original_fuel = fuel
            break
    _check(cell.x >= 0, "Найден реальный участок с подстилкой")
    if cell.x < 0:
        return

    var index: int = hydro.cell_index(cell)
    _check(fire._ignite_litter(cell, {}), "Подстилка загорелась")
    _check(int(fire.to_data()["version"]) == 8
        and _ember_in_cell(fire.to_data(), index) == original_fuel,
        "V8 хранит активные угли и их общий запас одинаково")

    _advance(m, 2, 0.02)
    fire.advance_day(2)
    var after_burn: Dictionary = fire.to_data()
    var leftover: int = _litter_in_cell(after_burn, index)
    _check(leftover >= 0 and leftover < original_fuel
        and _ember_in_cell(after_burn, index) == leftover,
        "Тление списало конечное топливо ровно один раз")

    # Дождь тушит жар, но не восстанавливает потраченный запас.
    _advance(m, 3, 1.0)
    fire.advance_day(3)
    var after_rain: Dictionary = fire.to_data()
    _check(_ember_in_cell(after_rain, index) == -1
        and _litter_in_cell(after_rain, index) == leftover,
        "Мокрая клетка больше не тлеет, остаток сохранён")

    # Смываем видимую золу как после сильного стока, но оставляем
    # реальный ожог почвы: отсутствие золы не равно новой биомассе.
    after_rain["scorched"] = []
    _check(fire.load_data(after_rain), "Смыв золы не меняет запас")
    m["surface"]._moisture.fill(0.02)
    _check(fire._ignite_litter(cell, {}), "Оставшаяся подстилка доступна")
    var reignited: Dictionary = fire.to_data()
    var reignited_fuel: int = _ember_in_cell(reignited, index)
    _check(reignited_fuel > 0 and reignited_fuel <= leftover,
        "Повторное воспламенение не создаёт сгоревшее топливо")

    # Устаревший формат v7 не знал о потушенных запасах.
    # Миграция переносит только действующие угли без подмены массы.
    var old: Dictionary = reignited.duplicate(true)
    old["version"] = 7
    old.erase("litter_remaining")
    var legacy := Fire.new(m["world"], hydro, m["surface"],
        m["climate"], nature)
    _check(legacy.load_data(old)
        and _ember_in_cell(legacy.to_data(), index) == reignited_fuel
        and _litter_in_cell(legacy.to_data(), index) == reignited_fuel,
        "Старый v7 загружен без придуманного запаса")

    # Неправильное количество и двойной индекс отвергаются атомарно.
    var duplicate: Dictionary = reignited.duplicate(true)
    duplicate["litter_remaining"].append(
        duplicate["litter_remaining"][0].duplicate())
    _check(not fire.load_data(duplicate)
        and fire.to_data() == reignited,
        "Двойной запас отклонён без повреждения мира")
    var mismatch: Dictionary = reignited.duplicate(true)
    for entry in mismatch["litter_remaining"]:
        if int(entry[0]) == index:
            entry[1] = reignited_fuel + 1
            break
    _check(not fire.load_data(mismatch)
        and fire.to_data() == reignited,
        "Несовпадающие угли и топливо отклонены")

    # Проверяем не только отдельный пожарный JSON, но и общий
    # WorldSave с грунтом, лесом, погодой и активными углями.
    var state := {
        "world": m["world"], "hydro": hydro, "surface": m["surface"],
        "climate": m["climate"], "nature": nature, "fire": fire,
        "weather": Weather.new(m["world"], m["climate"], m["surface"], hydro),
        "natural": Processes.new(m["world"], hydro, m["surface"], m["climate"]),
        "disasters": Disasters.new(m["world"], hydro, m["surface"], m["climate"])
    }
    var snapshot: Dictionary = Save.capture(state)
    _check(not snapshot.is_empty(), "Мир с конечным топливом сохранён")
    if not snapshot.is_empty():
        var restored: Dictionary = Save.restore(
            JSON.parse_string(JSON.stringify(snapshot)))
        _check(not restored.is_empty(), "Общий WorldSave восстановлен")
        if not restored.is_empty():
            _check(restored["fire"].to_data() == reignited,
                "Топливо и угли идентичны после полной загрузки")

    # Даже при полностью восстановленной почве нулевой запас
    # не может превратиться в полную подстилку за одно возгорание.
    var exhausted: Dictionary = reignited.duplicate(true)
    exhausted["embers"] = []
    exhausted["scorched"] = []
    exhausted["soil_damage"] = []
    exhausted["litter_remaining"] = [[index, 0]]
    _check(fire.load_data(exhausted), "Нулевой запас допустим в JSON")
    _check(not fire._ignite_litter(cell, {}),
        "Истощённая подстилка сразу не создаётся заново")

    # При следующем физическом дне регенерация ограничена четырьмя
    # единицами и больше не запускается повторным вызовом того же дня.
    _advance(m, 4, 0.45)
    m["surface"]._air_temperature.fill(20.0)
    fire.advance_day(4)
    var regenerated: Dictionary = fire.to_data()
    var new_fuel: int = _litter_in_cell(regenerated, index)
    # С дробным ростом один отдельный день вправе дать ноль:
    # малая плодородность не создаёт гарантированную массу.
    _check(new_fuel >= 0 and new_fuel <= 4,
        "Прирост отдельного дня ограничен и может быть нулевым")
    _check(fire.advance_day(4).is_empty()
        and fire.to_data() == regenerated,
        "Повтор суток не пополняет запас дважды")


func _run() -> void:
    # Единый итог выводим только после проверки всех физических,
    # календарных и сериализационных инвариантов.
    _test_reserve()
    if not failures.is_empty():
        for message in failures:
            printerr("11.5/LITTER-RESERVE: ", message)
        quit(1)
        return
    print("11.5/LITTER-RESERVE: остаток, дождь, регенерация и v1–v8 — успешно")
    quit(0)


func _initialize() -> void:
    # Godot-модели и Node3D доступны после инициализации SceneTree.
    call_deferred("_run")
