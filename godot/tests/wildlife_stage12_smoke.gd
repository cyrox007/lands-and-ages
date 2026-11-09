extends SceneTree
## Приёмка 12.4–12.5: настоящие вода/пища/биотопы, возрастные
## группы, воспроизводимость, миграция и совместимость WorldSave.

const Config = preload("res://scripts/world_config.gd")
const Map = preload("res://scripts/world_map.gd")
const Hydro = preload("res://scripts/hydrology.gd")
const Surface = preload("res://scripts/surface.gd")
const Climate = preload("res://scripts/climate.gd")
const Nature = preload("res://scripts/nature_registry.gd")
const Fire = preload("res://scripts/fire_registry.gd")
const Habitats = preload("res://scripts/wildlife_habitats.gd")
const Fauna = preload("res://scripts/wildlife_populations.gd")
const Weather = preload("res://scripts/weather_events.gd")
const Processes = preload("res://scripts/natural_processes.gd")
const Disasters = preload("res://scripts/natural_disasters.gd")
const Runner = preload("res://scripts/world_day_runner.gd")
const Save = preload("res://scripts/world_save.gd")

const SEEDS := [1729, 1802, 1875]
const DAYS := 18


func _initialize() -> void:
    # Код завершения CI соответствует настоящему результату испытания.
    var good := _run()
    print("STAGE12-FAUNA: успешно" if good else "STAGE12-FAUNA: ошибка")
    quit(0 if good else 1)


func _make(seed: int) -> Dictionary:
    # Все физические слои создаются в том же порядке, что и игровая
    # сцена: биотоп не получает нарисованную вместо природной воду.
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
    var fire = Fire.new(world, hydro, surface, climate, nature)
    var habitats = Habitats.new(world, hydro, surface, climate, nature, fire)
    var fauna = Fauna.new(world, habitats)
    if not fauna.generate():
        return {}
    return {"world": world, "hydro": hydro, "surface": surface,
        "climate": climate, "nature": nature, "fire": fire,
        "habitats": habitats, "fauna": fauna}


func _run() -> bool:
    var worlds: Array = []
    var populated := 0
    var biome_zones := 0
    for seed in SEEDS:
        var state: Dictionary = _make(seed)
        if state.is_empty():
            push_error("Не удалось создать фауну на seed %d" % seed)
            return false
        var habitats: RefCounted = state["habitats"]
        var fauna: RefCounted = state["fauna"]
        var configuration: RefCounted = state["world"].config
        var dimensions: Vector2i = configuration.region_count()
        var viable := 0
        for ry in dimensions.y:
            for rx in dimensions.x:
                var region := Vector2i(rx, ry)
                var zone: Dictionary = habitats.zone(region)
                for species in Habitats.SPECIES:
                    var details: Dictionary = zone[species]
                    if int(details["capacity"]) <= 0:
                        continue
                    if int(details["sites"]) < 1 \
                            or int(details["water_sites"]) < 1:
                        push_error("Животные появились без пищи или пресной воды")
                        return false
                    viable += 1
        if viable > 0:
            biome_zones += 1
        if fauna.total() > 0:
            populated += 1
        # Никакого второго заселения при открытии карты и повторной
        # генерации: метод вызывается только один раз для данного мира.
        var original: Dictionary = fauna.to_data()
        if fauna.generate() or fauna.to_data() != original:
            push_error("Повторное заселение создало животных из ничего")
            return false
        print("STAGE12-HABITAT-SEED: ", JSON.stringify({
            "seed": seed, "viable": viable, "population": fauna.by_species()
        }))
        worlds.append(state)
    if biome_zones < 2 or populated < 2:
        push_error("Пищевые и водные условия не поддержали дикую фауну")
        return false

    var state: Dictionary = worlds[0]
    var world: RefCounted = state["world"]
    var hydro: RefCounted = state["hydro"]
    var surface: RefCounted = state["surface"]
    var climate: RefCounted = state["climate"]
    var nature: RefCounted = state["nature"]
    var fire: RefCounted = state["fire"]
    var fauna: RefCounted = state["fauna"]
    var other_habitats = Habitats.new(world, hydro, surface, climate,
        nature, fire)
    var comparison = Fauna.new(world, other_habitats)
    if not comparison.generate() or comparison.to_data() != fauna.to_data():
        push_error("Seed не воспроизводит одинаковые первичные популяции")
        return false
    var weather = Weather.new(world, climate, surface, hydro)
    var natural = Processes.new(world, hydro, surface, climate)
    var disasters = Disasters.new(world, hydro, surface, climate)
    var runner = Runner.new(world, hydro, surface, climate, weather,
        natural, disasters, nature, fire)
    var total_births := 0
    var total_deaths := 0
    var total_migrated := 0
    for iteration in DAYS:
        var previous: int = fauna.total()
        runner.run_day()
        var day: int = climate.day
        if not fauna.advance_day(day) or not comparison.advance_day(day):
            push_error("Фауна не обновилась на физический день")
            return false
        if fauna.to_data() != comparison.to_data():
            push_error("Физически одинаковые дни изменили детерминизм")
            return false
        if fauna.total() != previous + fauna.last_births - fauna.last_deaths:
            push_error("Переселение породило или уничтожило животных")
            return false
        if fauna.advance_day(day):
            push_error("Повторная симуляция того же дня создала особей")
            return false
        total_births += fauna.last_births
        total_deaths += fauna.last_deaths
        total_migrated += fauna.last_migrated

    # Фауна входит в общий снимок только вместе с той же физической
    # природой: несуществующую популяцию в старом файле не генерируем.
    state["weather"] = weather
    state["natural"] = natural
    state["disasters"] = disasters
    var snapshot: Dictionary = Save.capture(state)
    if snapshot.is_empty() or not snapshot.has("fauna"):
        push_error("Поколения животных не сохранились в WorldSave")
        return false
    var restored: Dictionary = Save.restore(snapshot)
    if restored.is_empty() \
            or restored["fauna"].to_data() != fauna.to_data():
        push_error("Загрузка сменила существующее число животных")
        return false
    var legacy := snapshot.duplicate(true)
    legacy.erase("fauna")
    var previous_world: Dictionary = Save.restore(legacy)
    if previous_world.is_empty() or previous_world["fauna"].generated:
        push_error("Старое сохранение самопроизвольно заселилось")
        return false
    var invalid := snapshot.duplicate(true)
    if not invalid["fauna"]["groups"].is_empty():
        invalid["fauna"]["groups"][0]["adult"] = -10
        if not Save.restore(invalid).is_empty():
            push_error("Загрузка приняла отрицательное число животных")
            return false
    print("STAGE12-FAUNA-REPORT: ", JSON.stringify({
        "days": DAYS, "initial": comparison.total()
            - total_births + total_deaths,
        "final": fauna.total(), "births": total_births,
        "deaths": total_deaths, "migrated": total_migrated,
        "species": fauna.by_species()
    }))
    return true
