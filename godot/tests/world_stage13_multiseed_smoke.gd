extends SceneTree
## Этап 13.5: несколько независимых миров проходят настоящую стройку.
## Проверяем источник сырья, единственность здания и сохранение без подделок.

const Config = preload("res://scripts/world_config.gd")
const Map = preload("res://scripts/world_map.gd")
const Hydro = preload("res://scripts/hydrology.gd")
const Surface = preload("res://scripts/surface.gd")
const Climate = preload("res://scripts/climate.gd")
const Nature = preload("res://scripts/nature_registry.gd")
const Resources = preload("res://scripts/natural_resource_registry.gd")
const Generation = preload("res://scripts/natural_resource_generation.gd")
const Economy = preload("res://scripts/world_first_economy.gd")
const Settlement = preload("res://scripts/world_settlement.gd")
const Industry = preload("res://scripts/world_resource_industry.gd")
const Paths = preload("res://scripts/world_resource_path.gd")
const Weather = preload("res://scripts/weather_events.gd")
const Natural = preload("res://scripts/natural_processes.gd")
const Disasters = preload("res://scripts/natural_disasters.gd")
const Fire = preload("res://scripts/fire_registry.gd")
const Runner = preload("res://scripts/world_day_runner.gd")
const Save = preload("res://scripts/world_save.gd")


func _initialize() -> void:
    # Не объявляем аппаратную приёмку пройденной: здесь только
    # реальная симуляция Godot на нескольких начальных состояниях.
    var ok := true
    for seed in [1729, 2025, 4242]:
        if not _verify_seed(seed):
            ok = false
            break
    print("STAGE13-MULTISEED: успешно" if ok else
        "STAGE13-MULTISEED: ошибка")
    quit(0 if ok else 1)


func _verify_seed(seed: int) -> bool:
    # Повторяем обычную генерацию мира, гидрологию, запасы и деревья.
    # Seed различает природную географию, а не только имя поселения.
    var world = Map.new(Config.new(256, 192, seed))
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
    var settlement = Settlement.new(world, economy)
    if not economy.start() or not settlement.found(economy.site):
        push_error("Seed %d: нет стартового физического заказа" % seed)
        return false
    var source_before: Dictionary = deposits.source_at("глина",
        economy.clay_cell)
    var clay_before := int(source_before.get("remaining_units", -1))
    if clay_before < Economy.CLAY_UNITS or settlement.has_workshop():
        push_error("Seed %d: бесплатная мастерская или нет глины" % seed)
        return false

    # Действительный суточный исполнитель изменяет климат и природу,
    # перевозчик физически приносит сырьё, кирпичи сгорают в стройке.
    var weather = Weather.new(world, climate, surface, hydro)
    var natural = Natural.new(world, hydro, surface, climate)
    var disasters = Disasters.new(world, hydro, surface, climate)
    var fire = Fire.new(world, hydro, surface, climate, nature)
    var runner = Runner.new(world, hydro, surface, climate,
        weather, natural, disasters, nature, fire)
    var finished := false
    for day in range(2, 90):
        runner.run_day()
        economy.advance_day(climate.day)
        settlement.sync_workshop()
        if economy.phase == "приостановлено":
            push_error("Seed %d: остановка стройки: %s" %
                [seed, economy.last_event])
            return false
        if economy.built:
            finished = true
            break
    var clay_after: Dictionary = deposits.source_at("глина",
        economy.clay_cell)
    if not finished or not settlement.has_workshop() \
            or settlement.buildings().size() != 1 \
            or settlement.sync_workshop() \
            or int(clay_after.get("remaining_units", -1)) \
                != clay_before - Economy.CLAY_UNITS \
            or economy.bricks != 0 \
            or economy.stored_clay != 0 or economy.stored_wood != 0:
        push_error("Seed %d: не совпали расход и результат стройки" % seed)
        return false

    # Производственный участок существует лишь после стройки. Порт
    # находится у внешней стены, а дорога без покрытия невозможна.
    var industry = Industry.new(world, hydro, surface, nature,
        deposits, climate.day)
    if not industry.activate(economy.site):
        push_error("Seed %d: производственный участок недоступен" % seed)
        return false
    settlement.bind_industry(industry)
    var door: Vector2i = settlement.port_for(Settlement.WORKSHOP)
    if not world.config.contains_cell(door) \
            or settlement.occupies(door) \
            or not Paths.walkable(world, hydro, surface, door) \
            or industry.home_port != door \
            or not settlement.roads().is_empty():
        push_error("Seed %d: неверный порт или бесплатная дорога" % seed)
        return false

    # JSON-сохранение проверяем как настоящий файл по форме данных:
    # не допускаем повторной генерации уже оплаченного здания.
    var state := {
        "world": world, "hydro": hydro, "surface": surface,
        "climate": climate, "weather": weather, "natural": natural,
        "disasters": disasters, "nature": nature, "fire": fire,
        "resources": deposits, "economy": economy,
        "industry": industry, "settlement": settlement
    }
    var snapshot: Dictionary = Save.capture(state)
    if snapshot.is_empty():
        push_error("Seed %d: не удалось сохранить мир" % seed)
        return false
    var decoded: Variant = JSON.parse_string(JSON.stringify(snapshot))
    if not (decoded is Dictionary):
        push_error("Seed %d: сериализация повредила формат" % seed)
        return false
    var loaded: Dictionary = Save.restore(decoded)
    if loaded.is_empty() or loaded["settlement"].to_data() \
            != settlement.to_data() \
            or loaded["industry"].home_port != door \
            or loaded["economy"].built != true:
        push_error("Seed %d: сохранение восстановлено не полностью" % seed)
        return false

    # Поддельная дорога в сохранении не должна появиться бесплатно:
    # у склада нет произведённого дорожного покрытия.
    var forged: Dictionary = decoded.duplicate(true)
    forged["settlement"]["roads"] = [[door.x, door.y]]
    if not Save.restore(forged).is_empty():
        push_error("Seed %d: принято неоплаченное покрытие" % seed)
        return false
    print("STAGE13-SEED: ", seed, " · центр ", settlement.center,
        " · день ", climate.day, " · вход ", door)
    return true
