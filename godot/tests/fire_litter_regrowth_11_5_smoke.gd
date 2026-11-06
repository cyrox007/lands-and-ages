extends SceneTree
## 11.5/F5b2c: ожог почвы ограничивает повторное появление горючей подстилки.

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
    # Собираем ошибки независимо: сохранение и повторное зажигание
    # должны быть проверены даже при ошибке коэффициента восстановления.
    if not ok:
        failures.append(message)


func _models() -> Dictionary:
    # Создаём ту же физическую карту, что и пожарные smoke F1–F5b2b.
    # Растения и реальный полог берутся из NatureRegistry, а не из
    # искусственного списка доступных для горения клеток.
    var world := Map.new(Config.new(96, 80, 1729, 16, 32))
    var hydro := Hydro.new(world)
    hydro.rebuild()
    var surface := Surface.new(world, hydro)
    surface.rebuild()
    var climate := Climate.new(world, hydro)
    climate.rebuild()
    climate.set_day(1)
    _check(surface.advance_climate_day(climate),
        "Календарь грунта синхронизирован с климатом")
    hydro.apply_rainfall_map(surface.runoff_map())
    var nature := Nature.new(world, hydro, surface, climate)
    _check(nature.generate(), "Физическая растительность сгенерирована")
    surface._moisture.fill(0.02)
    surface._snow.fill(0.0)
    climate._rain.fill(0.0)
    return {
        "world": world, "hydro": hydro, "surface": surface,
        "climate": climate, "nature": nature,
        "fire": Fire.new(world, hydro, surface, climate, nature)
    }


func _fuel_in_cell(fire: RefCounted, cell: Vector2i) -> int:
    # Фактический запас берём из сохраняемого FireRegistry, чтобы
    # проверить не только допуск к огню, но и количество топлива.
    for entry in fire.to_data()["embers"]:
        var index: int = int(entry[0])
        if index == fire.hydro.cell_index(cell):
            return int(entry[1])
    return 0


func _test_litter_regrowth() -> void:
    # При сильном повреждении доступной подстилки нет, после
    # восстановления возвращается исходная физическая биомасса.
    _check(is_equal_approx(Fire.litter_recovery_factor(0.0), 1.0),
        "Здоровый грунт полностью сохраняет прежний запас подстилки")
    _check(Fire.litter_recovery_factor(0.95) == 0.0
        and Fire.litter_recovery_factor(0.70) == 0.0,
        "Глубокий ожог подавляет повторное воспламенение")
    _check(Fire.litter_recovery_factor(0.12) > 0.0
        and Fire.litter_recovery_factor(0.12) < 1.0,
        "Заживающий грунт возвращает топливо постепенно")

    var m: Dictionary = _models()
    var world: RefCounted = m["world"]
    var hydro: RefCounted = m["hydro"]
    var surface: RefCounted = m["surface"]
    var climate: RefCounted = m["climate"]
    var nature: RefCounted = m["nature"]
    var fire: RefCounted = m["fire"]
    var clean: Dictionary = fire.to_data()
    var cell := Vector2i(-1, -1)
    var original_fuel := 0

    # Ищем среди реально существующих деревьев участок с достаточной
    # здоровой подстилкой. Пробное зажигание сбрасываем строгим JSON.
    for record in nature.to_data()["objects"]:
        if record[1] != "дерево" or record[9] != "целое":
            continue
        var probe := Vector2i(int(record[3]), int(record[4]))
        if probe.x < 8 or probe.y < 8 \
                or probe.x >= 88 or probe.y >= 72:
            continue
        var index: int = hydro.cell_index(probe)
        if hydro.has_water(index) or hydro.flooded_at(index):
            continue
        var changed := {}
        if not fire._ignite_litter(probe, changed):
            continue
        var fuel: int = _fuel_in_cell(fire, probe)
        _check(fire.load_data(clean), "Пробное тление сброшено без дублей")
        if fuel >= 145:
            cell = probe
            original_fuel = fuel
            break
    _check(cell.x >= 0, "Найдено реальное место с запасом подстилки")
    if cell.x < 0:
        return

    var index: int = hydro.cell_index(cell)
    var damaged: Dictionary = clean.duplicate(true)
    damaged["soil_damage"] = [[index, 950, 1]]
    _check(fire.load_data(damaged), "Ожог без золы принят форматом v4")
    var changed := {}
    _check(not fire._ignite_litter(cell, changed)
        and fire.smolder_count() == 0
        and fire.scorched_at(cell) == 0.0,
        "Сильный ожог препятствует новой подстилке даже без золы")

    # Последствие должно пережить сохранение целого мира: после
    # загрузки повторная попытка не должна создать новый уголь.
    var state := {
        "world": world, "hydro": hydro, "surface": surface,
        "climate": climate, "nature": nature, "fire": fire,
        "weather": Weather.new(world, climate, surface, hydro),
        "natural": Processes.new(world, hydro, surface, climate),
        "disasters": Disasters.new(world, hydro, surface, climate)
    }
    var snapshot: Dictionary = Save.capture(state)
    _check(not snapshot.is_empty(), "Повреждённый участок сохранён")
    if not snapshot.is_empty():
        var loaded: Dictionary = Save.restore(
            JSON.parse_string(JSON.stringify(snapshot)))
        _check(not loaded.is_empty(), "Мир с ожогом восстановлен")
        if not loaded.is_empty():
            var loaded_fire: RefCounted = loaded["fire"]
            _check(not loaded_fire._ignite_litter(cell, {})
                and loaded_fire.smolder_count() == 0,
                "После загрузки сильный ожог по-прежнему запрещает тление")

    # На частично зажившей почве биомасса меньше исходной, а при
    # полном восстановлении запас снова становится прежним.
    damaged["soil_damage"] = [[index, 120, 1]]
    _check(fire.load_data(damaged), "Частичный ожог принят форматом v4")
    _check(fire._ignite_litter(cell, {}),
        "Частично восстановившаяся подстилка снова доступна")
    var recovered_fuel: int = _fuel_in_cell(fire, cell)
    _check(recovered_fuel > 0 and recovered_fuel < original_fuel,
        "Запас после ожога меньше исходного физического топлива")

    _check(fire.load_data(clean), "Полное восстановление очищает угли")
    _check(fire._ignite_litter(cell, {})
        and _fuel_in_cell(fire, cell) == original_fuel,
        "Здоровый грунт возвращает прежний запас подстилки")

    # Старые сохранения v3 вообще не содержали почвенного ожога.
    # Новая проверка не должна препятствовать их прежней загрузке.
    var legacy: Dictionary = clean.duplicate(true)
    legacy["version"] = 3
    legacy.erase("soil_damage")
    _check(fire.load_data(legacy) and fire.soil_scar_count() == 0,
        "Старый пожарный JSON не получает вымышленный ожог")
    _check(fire._ignite_litter(cell, {})
        and _fuel_in_cell(fire, cell) == original_fuel,
        "В старом мире без ожога прежняя подстилка воспламеняется")


func _run() -> void:
    # Единый сценарий проверяет восстановление физической горючести,
    # отсутствие мгновенного повторного огня и обратную совместимость.
    _test_litter_regrowth()
    if not failures.is_empty():
        for message in failures:
            printerr("11.5/F5b2c: ", message)
        quit(1)
        return
    print("11.5/F5b2c: подстилка, ожог, JSON и восстановление — успешно")
    quit(0)


func _initialize() -> void:
    # Запуск после инициализации SceneTree позволяет загрузить Godot
    # классы и выполнить сценарий без окна и без графического движка.
    call_deferred("_run")
