extends SceneTree
## 12.5: популяции живут в полном физическом календаре Godot,
## размножаются по биотопам и не теряются при сохранении сезона.

const Config = preload("res://scripts/world_config.gd")
const Map = preload("res://scripts/world_map.gd")
const Hydro = preload("res://scripts/hydrology.gd")
const Surface = preload("res://scripts/surface.gd")
const Climate = preload("res://scripts/climate.gd")
const Nature = preload("res://scripts/nature_registry.gd")
const Weather = preload("res://scripts/weather_events.gd")
const Natural = preload("res://scripts/natural_processes.gd")
const Disasters = preload("res://scripts/natural_disasters.gd")
const Fire = preload("res://scripts/fire_registry.gd")
const Runner = preload("res://scripts/world_day_runner.gd")
const Save = preload("res://scripts/world_save.gd")
const Populations = preload("res://scripts/wildlife_populations.gd")

const DAYS := 32


func _initialize() -> void:
    # CI проверяет ненулевой результат и полный журнал счётчиков.
    var ok := _check()
    print("STAGE12-POPULATIONS: успешно" if ok else "STAGE12-POPULATIONS: ошибка")
    quit(0 if ok else 1)


func _state() -> Dictionary:
    # Используем тот же порядок и те же источники, что настоящая игра.
    var world = Map.new(Config.new(256, 192, 1729))
    var hydro = Hydro.new(world)
    hydro.rebuild()
    var surface = Surface.new(world, hydro)
    surface.rebuild()
    var climate = Climate.new(world, hydro)
    climate.rebuild()
    climate.set_day(1)
    surface.advance_climate_day(climate)
    hydro.apply_rainfall_map(surface.runoff_map())
    var nature = Nature.new(world, hydro, surface, climate)
    nature.generate()
    var wildlife = Populations.new(world, hydro, surface, climate, nature)
    if not wildlife.generate():
        return {}
    var weather = Weather.new(world, climate, surface, hydro)
    var natural = Natural.new(world, hydro, surface, climate)
    var disasters = Disasters.new(world, hydro, surface, climate)
    var fire = Fire.new(world, hydro, surface, climate, nature)
    var runner = Runner.new(world, hydro, surface, climate,
        weather, natural, disasters, nature, fire)
    return {"world": world, "hydro": hydro, "surface": surface,
        "climate": climate, "nature": nature, "wildlife": wildlife,
        "weather": weather, "natural": natural,
        "disasters": disasters, "fire": fire, "runner": runner}


func _step(state: Dictionary) -> bool:
    # Сначала живёт природа, только затем обновляются животные:
    # корм, снег и паводки берутся из текущего физического дня.
    state["runner"].run_day()
    var day: int = state["climate"].day
    var fauna: RefCounted = state["wildlife"]
    var before: int = fauna.total()
    if not fauna.advance_day(day):
        push_error("Популяции приняли несинхронный день")
        return false
    var events: Dictionary = fauna.last_events
    if fauna.total() != before + int(events["born"]) - int(events["died"]):
        push_error("Размножение или миграция создали животных из воздуха")
        return false
    for region_y in range(state["world"].config.region_count().y):
        for region_x in range(state["world"].config.region_count().x):
            var region := Vector2i(region_x, region_y)
            for kind in Populations.SPECIES:
                var count: int = fauna.population_at(region, kind)
                if count < 0 or count > Populations.MAX_PER_REGION:
                    push_error("Численность вне физического лимита")
                    return false
                # Каждый физический день сохраняет закон сложения возрастов.
                var ages: Array = fauna.age_at(region, kind)
                if ages.size() != 3 or int(ages[0]) + int(ages[1]) \
                        + int(ages[2]) != count:
                    push_error("Возрастные группы не равны численности")
                    return false
    return true


func _check() -> bool:
    var state: Dictionary = _state()
    if state.is_empty():
        return false
    var wildlife: RefCounted = state["wildlife"]
    if wildlife.total() <= 0 or wildlife.generate():
        push_error("Нет травоядных или повторная генерация увеличила популяцию")
        return false
    if wildlife.total("волк") != 0 or wildlife.total("лиса") != 0 \
            or wildlife.population_at(Vector2i(-1, 0), "олень") != 0:
        push_error("Хищники появились до появления добычи")
        return false
    var snapshot: Dictionary = wildlife.to_data()
    var second = Populations.new(state["world"], state["hydro"],
        state["surface"], state["climate"], state["nature"])
    if not second.generate() or second.to_data() != snapshot:
        push_error("Генерация зависит от порядка вызовов")
        return false
    var born := 0
    var died := 0
    var moved := 0
    var previous_total: int = wildlife.total()
    for day in range(2, DAYS + 1):
        # Двадцатый день проверен отдельно после загрузки снимка.
        if day == 20:
            continue
        if not _step(state):
            return false
        var events: Dictionary = wildlife.last_events
        born += int(events["born"])
        died += int(events["died"])
        moved += int(events["migrated"])
        if day == 19:
            # Посреди сезона снимок должен запомнить именно текущую
            # вместимость, а не пересоздавать стада после загрузки.
            var world_snapshot: Dictionary = Save.capture(state)
            if world_snapshot.is_empty() or not world_snapshot.has("wildlife"):
                push_error("WorldSave не сохранил реальные популяции")
                return false
            var restored: Dictionary = Save.restore(world_snapshot)
            if restored.is_empty() \
                    or restored["wildlife"].to_data() != wildlife.to_data():
                push_error("Загрузка изменила животных посреди сезона")
                return false
            var invalid: Dictionary = world_snapshot.duplicate(true)
            invalid["wildlife"]["entries"][0]["count"] = 50000
            if not Save.restore(invalid).is_empty():
                push_error("WorldSave принял поддельную популяцию")
                return false
            # Проверяем повторение следующих суток на независимо
            # восстановленном мире, а не только равенство JSON.
            if not _step(restored) or not _step(state):
                return false
            if restored["wildlife"].to_data() != wildlife.to_data():
                push_error("После загрузки сезонная динамика разошлась")
                return false
            born += int(wildlife.last_events["born"])
            died += int(wildlife.last_events["died"])
            moved += int(wildlife.last_events["migrated"])
            continue
    # Контрольный годовой фрагмент должен действительно испытывать
    # все три процесса, а не проходить пустым циклом счётчиков.
    if born <= 0 or died <= 0 or moved <= 0:
        push_error("Размножение, смертность или миграция не выполнялись")
        return false
    if wildlife.total() != previous_total + born - died:
        push_error("Суммарная численность не соответствует рождаемости")
        return false
    var wrong: Dictionary = wildlife.to_data().duplicate(true)
    var saved: Dictionary = wildlife.to_data()
    if wrong["entries"].is_empty():
        return false
    wrong["entries"][0]["species"] = "домашняя корова"
    if wildlife.load_data(wrong) or wildlife.to_data() != saved:
        push_error("Поддельное животное попало в природный реестр")
        return false
    # Повреждённые когорты нельзя принимать даже при корректном count.
    var broken: Dictionary = saved.duplicate(true)
    broken["entries"][0]["ages"] = [0, 0, 0]
    if int(broken["entries"][0]["count"]) > 0 \
            and (wildlife.load_data(broken) or wildlife.to_data() != saved):
        push_error("Принято сохранение с несогласованными возрастами")
        return false
    # Снимки до введения возрастов восстанавливаем без изменений общей
    # численности, без генерации дополнительной добычи или миграций.
    var legacy: Dictionary = saved.duplicate(true)
    legacy["version"] = 1
    for item in legacy["entries"]:
        item.erase("ages")
    var old_world = Populations.new(state["world"], state["hydro"],
        state["surface"], state["climate"], state["nature"])
    if not old_world.load_data(legacy) or old_world.total() != wildlife.total():
        push_error("Потеряна совместимость сохранения без возрастных групп")
        return false
    print("STAGE12-POPULATIONS-REPORT: ", JSON.stringify({
        "day": wildlife.last_day, "counts": wildlife.summary()["population"],
        "born": born, "died": died, "migrated": moved,
        "regions": state["world"].config.region_count()
    }))
    return true
