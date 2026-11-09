extends SceneTree
## Сквозная приёмка: физический источник → перенос → кирпич → постройка.
## Используются реальные генераторы Godot, лес и проверенный WorldSave.

const Config = preload("res://scripts/world_config.gd")
const Map = preload("res://scripts/world_map.gd")
const Hydro = preload("res://scripts/hydrology.gd")
const Surface = preload("res://scripts/surface.gd")
const Climate = preload("res://scripts/climate.gd")
const Nature = preload("res://scripts/nature_registry.gd")
const Resources = preload("res://scripts/natural_resource_registry.gd")
const Generation = preload("res://scripts/natural_resource_generation.gd")
const Economy = preload("res://scripts/world_first_economy.gd")
const Weather = preload("res://scripts/weather_events.gd")
const Natural = preload("res://scripts/natural_processes.gd")
const Disasters = preload("res://scripts/natural_disasters.gd")
const Fire = preload("res://scripts/fire_registry.gd")
const Save = preload("res://scripts/world_save.gd")


func _initialize() -> void:
    # Сбой цепочки завершает процесс ненулевым кодом для GitHub Actions.
    var ok := _test()
    print("STAGE12-ECONOMY: успешно" if ok else "STAGE12-ECONOMY: ошибка")
    quit(0 if ok else 1)


func _test() -> bool:
    # Делаем настоящую карту: без поддельных деревьев и месторождений.
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
    var deposits = Resources.new(world)
    Generation.populate(world, hydro, surface, deposits)
    var economy = Economy.new(world, hydro, surface, nature, deposits, 1)
    if not economy.start():
        push_error("Не найдены достижимые залежь, лес и участок: " +
            economy.last_event)
        return false

    # В сохранение входят незавершённая работа и точные запасы.
    var state := {
        "world": world, "hydro": hydro, "surface": surface,
        "climate": climate,
        "weather": Weather.new(world, climate, surface, hydro),
        "natural": Natural.new(world, hydro, surface, climate),
        "disasters": Disasters.new(world, hydro, surface, climate),
        "nature": nature, "fire": Fire.new(world, hydro, surface, climate, nature),
        "resources": deposits, "economy": economy
    }
    var initial: Dictionary = Save.capture(state)
    if initial.is_empty() or not initial.has("economy"):
        push_error("Заказ не попал в WorldSave")
        return false
    var recovered: Dictionary = Save.restore(initial)
    if recovered.is_empty() or recovered["economy"].to_data() != economy.to_data():
        push_error("WorldSave изменил незавершённый заказ")
        return false

    # Отмечаем физическое количество сырья до первого рабочего дня.
    var original: Dictionary = deposits.source_at("глина", economy.clay_cell)
    var clay_before: int = int(original["remaining_units"])
    var wood_before: int = nature.wood_total()
    var position_before: Vector2i = economy.worker
    var phases := {}
    var finished := false
    for day in range(2, 90):
        economy.advance_day(day)
        phases[economy.phase] = true
        if economy.phase == "приостановлено":
            push_error("Заказ остановился: " + economy.last_event)
            return false
        if economy.built:
            finished = true
            break
    if not finished or not phases.has("обжиг") \
            or not phases.has("строительство"):
        push_error("Заказ не завершил перевозку, переработку и постройку")
        return false
    if position_before == economy.clay_cell or economy.site != economy.worker:
        push_error("Рабочий не вернулся на настоящую площадку")
        return false
    if int(deposits.source_at("глина", economy.clay_cell)["remaining_units"]) \
            != clay_before - Economy.CLAY_UNITS:
        push_error("Добытая глина не вычтена из месторождения")
        return false
    if nature.wood_total() != wood_before - Economy.FUEL_UNITS:
        push_error("Древесина продублирована или не потрачена")
        return false
    var end: Dictionary = economy.summary()
    if int(end["stored_clay"]) != 0 or int(end["stored_wood"]) != 0 \
            or int(end["bricks"]) != 0 \
            or int(end["clay_in_transit"]) != 0 \
            or int(end["wood_in_transit"]) != 0:
        push_error("После строительства остались фиктивные запасы")
        return false

    # Воссоздание из снимка не должно сбрасывать построенный объект.
    var saved: Dictionary = economy.to_data()
    var restored = Economy.new(world, hydro, surface, nature, deposits,
        economy.last_day)
    if not restored.load_data(saved, economy.last_day) \
            or restored.to_data() != saved:
        push_error("Хозяйственное состояние не сохранилось")
        return false
    var invalid: Dictionary = saved.duplicate(true)
    invalid["bricks"] = -50
    if restored.load_data(invalid, economy.last_day) \
            or restored.to_data() != saved:
        push_error("Повреждённый снимок изменил запасы")
        return false
    print("STAGE12-ECONOMY-REPORT: ", JSON.stringify({
        "site": [economy.site.x, economy.site.y],
        "days": economy.last_day - 1,
        "clay_spent": clay_before -
            int(deposits.source_at("глина", economy.clay_cell)["remaining_units"]),
        "wood_spent": wood_before - nature.wood_total(),
        "building": economy.built, "phases": phases.keys()
    }))
    return true
