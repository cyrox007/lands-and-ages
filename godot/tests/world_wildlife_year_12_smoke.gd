extends SceneTree
## Испытание 12.10: полный природный год (96 игровых суток),
## повторяемость сохранений, пищевой баланс и память Godot.
## Реальные FPS Android здесь НЕ измеряются: нужен аппаратный стенд.

const Config = preload("res://scripts/world_config.gd")
const World = preload("res://scripts/world_map.gd")
const Hydro = preload("res://scripts/hydrology.gd")
const Ground = preload("res://scripts/surface.gd")
const Climate = preload("res://scripts/climate.gd")
const Nature = preload("res://scripts/nature_registry.gd")
const Weather = preload("res://scripts/weather_events.gd")
const Natural = preload("res://scripts/natural_processes.gd")
const Disasters = preload("res://scripts/natural_disasters.gd")
const Fire = preload("res://scripts/fire_registry.gd")
const Runner = preload("res://scripts/world_day_runner.gd")
const Wildlife = preload("res://scripts/wildlife_populations.gd")
const FoodWeb = preload("res://scripts/wildlife_food_web.gd")
const Save = preload("res://scripts/world_save.gd")

const MAX_WORLD_MS := 360000
const MAX_SERIALIZED_BYTES := 64 * 1024 * 1024
const MAX_STATIC_MIB := 1024.0


func _initialize() -> void:
    # Испытание принимает seed и число лет из аргументов CI;
    # отсутствие параметров запускает один полный год по умолчанию.
    var seed := 1729
    var years := 1
    for arg in OS.get_cmdline_user_args():
        if arg.begins_with("--seed="):
            seed = int(arg.trim_prefix("--seed="))
        elif arg.begins_with("--years="):
            years = int(arg.trim_prefix("--years="))
    if years < 1 or years > 3:
        push_error("Допустимо от одного до трёх полных природных лет")
        quit(1)
        return
    var report: Dictionary = _check(seed, years)
    if report.is_empty():
        print("STAGE12-YEAR: ошибка")
        quit(1)
        return
    print("STAGE12-YEAR-REPORT: ", JSON.stringify(report))
    print("STAGE12-YEAR: успешно")
    quit(0)


func _create(seed: int) -> Dictionary:
    # Полностью воспроизводим сборку реального мира Godot:
    # без тестовых ресурсов, вручную созданных стад и муляжей.
    var world = World.new(Config.new(256, 192, seed))
    var hydro = Hydro.new(world)
    hydro.rebuild()
    var surface = Ground.new(world, hydro)
    surface.rebuild()
    var climate = Climate.new(world, hydro)
    climate.rebuild()
    climate.set_day(1)
    surface.advance_climate_day(climate)
    hydro.apply_rainfall_map(surface.runoff_map())
    var nature = Nature.new(world, hydro, surface, climate)
    if not nature.generate():
        return {}
    var wildlife = Wildlife.new(world, hydro, surface, climate, nature)
    if not wildlife.generate():
        return {}
    var food_web = FoodWeb.new(world, climate, wildlife)
    if not food_web.generate():
        return {}
    var weather = Weather.new(world, climate, surface, hydro)
    var natural = Natural.new(world, hydro, surface, climate)
    var disasters = Disasters.new(world, hydro, surface, climate)
    var fire = Fire.new(world, hydro, surface, climate, nature)
    var runner = Runner.new(world, hydro, surface, climate,
        weather, natural, disasters, nature, fire)
    return {"world": world, "hydro": hydro, "surface": surface,
        "climate": climate, "nature": nature, "wildlife": wildlife,
        "food_web": food_web, "weather": weather, "natural": natural,
        "disasters": disasters, "fire": fire, "runner": runner}


func _step(state: Dictionary) -> Dictionary:
    # Весь климатический цикл и растительность обновляются прежде,
    # чем дикие животные получают корм и прежде, чем хищник ест.
    var fauna: RefCounted = state["wildlife"]
    var predators: RefCounted = state["food_web"]
    var before_herbivores: int = fauna.total()
    var before_predators: int = predators.total()
    var start: int = Time.get_ticks_usec()
    state["runner"].run_day()
    var day: int = state["climate"].day
    if not fauna.advance_day(day):
        push_error("Дикие популяции не синхронизированы с климатом")
        return {}
    var born: int = fauna.last_events["born"]
    var died: int = fauna.last_events["died"]
    var hazards: Array = state["runner"].last_result["hazards"]
    if not predators.advance_day(day, hazards):
        push_error("Пищевая цепочка не синхронизирована с травоядными")
        return {}
    var event: Dictionary = predators.last_events
    if fauna.total() != before_herbivores + born - died \
            - int(event["eaten"]) - int(event["prey_lost"]):
        push_error("Закон сохранения особей нарушен в охоте")
        return {}
    if predators.total() != before_predators + int(event["born"]) \
            - int(event["died"]):
        push_error("Миграция и размножение создают лишних хищников")
        return {}
    var regions: Vector2i = state["world"].config.region_count()
    for y in range(regions.y):
        for x in range(regions.x):
            var region := Vector2i(x, y)
            for species in Wildlife.SPECIES:
                var n: int = fauna.population_at(region, species)
                if n < 0 or n > Wildlife.MAX_PER_REGION:
                    push_error("В регионе превышен предел травоядных")
                    return {}
            for species in FoodWeb.SPECIES:
                var n: int = predators.count_at(region, species)
                if n < 0 or n > FoodWeb.MAX_PER_REGION:
                    push_error("Хищник вышел за лимит региона")
                    return {}
    return {"ms": float(Time.get_ticks_usec() - start) / 1000.0,
        "born": born + int(event["born"]),
        "died": died + int(event["died"]) + int(event["prey_lost"]),
        "eaten": int(event["eaten"]),
        "herbivores": fauna.total(), "predators": predators.total()}


func _percentile(samples: Array[float], fraction: float) -> float:
    # Измеряем p95 непосредственно по суточной физике; среднее
    # скрывало бы редкие кадровые пики перерасчёта природных регионов.
    if samples.is_empty():
        return 0.0
    var sorted := samples.duplicate()
    sorted.sort()
    var index := clampi(ceili(float(sorted.size()) * fraction) - 1,
        0, sorted.size() - 1)
    return sorted[index]


func _check(seed: int, years: int) -> Dictionary:
    var state: Dictionary = _create(seed)
    if state.is_empty():
        return {}
    var total_days := years * Climate.YEAR_DAYS
    var origin: int = state["wildlife"].total() \
        + state["food_web"].total()
    var times: Array[float] = []
    var events := {"born": 0, "died": 0, "eaten": 0}
    var replay_verified := false
    var max_memory := 0.0
    var seasons := {}
    var started: int = Time.get_ticks_msec()
    for step in range(total_days):
        # Шаги не перескакиваются: зима и лето полностью влияют
        # на траву, снег, воду, стада и доступность добычи.
        var current: Dictionary = _step(state)
        if current.is_empty():
            return {}
        times.append(float(current["ms"]))
        for key in events:
            events[key] += int(current[key])
        var year_day: int = posmod(state["climate"].day - 1,
            Climate.YEAR_DAYS)
        var season := Climate.season_name(year_day)
        seasons[season] = int(seasons.get(season, 0)) + 1
        max_memory = maxf(max_memory,
            float(Performance.get_monitor(Performance.MEMORY_STATIC))
            / 1048576.0)
        if max_memory > MAX_STATIC_MIB:
            push_error("Статическая память превысила защитный лимит")
            return {}
        if Time.get_ticks_msec() - started > MAX_WORLD_MS:
            push_error("Годовая симуляция превысила аварийный лимит времени")
            return {}
        # После первого полного цикла сохраняем реальные слои.
        # Независимая загрузка обязана дать такой же следующий день.
        if not replay_verified and step == total_days - 1:
            var snapshot: Dictionary = Save.capture(state)
            if snapshot.is_empty():
                push_error("Годовой WorldSave не собрался")
                return {}
            var bytes := JSON.stringify(snapshot).to_utf8_buffer().size()
            if bytes > MAX_SERIALIZED_BYTES:
                push_error("Сохранение стало чрезмерно большим")
                return {}
            var clone: Dictionary = Save.restore(snapshot)
            if clone.is_empty():
                push_error("Не восстановлен первый полный природный год")
                return {}
            if clone["wildlife"].to_data() != state["wildlife"].to_data() \
                    or clone["food_web"].to_data() != state["food_web"].to_data():
                push_error("Исчезли особи при загрузке года")
                return {}
            var original_next: Dictionary = _step(state)
            var clone_next: Dictionary = _step(clone)
            if original_next.is_empty() or clone_next.is_empty() \
                    or clone["wildlife"].to_data() != state["wildlife"].to_data() \
                    or clone["food_web"].to_data() != state["food_web"].to_data():
                push_error("Продолжение года не детерминировано")
                return {}
            # Следующий день уже прожит в оригинале; учитываем его
            # события без лишнего повторного шага.
            times.append(float(original_next["ms"]))
            for key in events:
                events[key] += int(original_next[key])
            replay_verified = true
    if not replay_verified or seasons.size() != Climate.SEASONS.size():
        return {}
    var remaining: int = state["wildlife"].total() \
        + state["food_web"].total()
    if origin + int(events["born"]) - int(events["died"]) \
            - int(events["eaten"]) != remaining:
        push_error("Многосезонный материальный баланс животных неверен")
        return {}
    return {"seed": seed, "years": years, "season_days": total_days,
        "replay_next_day": state["climate"].day,
        "seasons": seasons, "initial": origin, "remaining": remaining,
        "born": events["born"], "died": events["died"],
        "prey_eaten": events["eaten"], "p50_day_ms": _percentile(times, 0.5),
        "p95_day_ms": _percentile(times, 0.95),
        "peak_static_mib": snappedf(max_memory, 0.01),
        "replay_year": replay_verified,
        "platform": OS.get_name(), "renderer": "headless"}
