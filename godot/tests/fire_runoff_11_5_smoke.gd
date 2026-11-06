extends SceneTree
## 11.5/F4: дождевой сток переносит уже образованную золу вниз по суше.

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


func _check(valid: bool, message: String) -> void:
    # Каждая проверка сообщает конкретное нарушение физического
    # баланса, сохранения или календарного расчёта.
    if not valid:
        failures.append(message)


func _models() -> Dictionary:
    # Тест строит настоящий мир с землёй, гидрологией и лесом:
    # условный сток меняет только заданную климатом величину.
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
    _check(nature.generate(), "Физическая природа карты сгенерирована")
    return {
        "world": world, "hydro": hydro, "surface": surface,
        "climate": climate, "nature": nature,
        "fire": Fire.new(world, hydro, surface, climate, nature)
    }


func _lower_land(world: RefCounted, hydro: RefCounted,
        cell: Vector2i) -> Vector2i:
    # Правило выбора совпадает с физической моделью: один самый
    # низкий незатопленный сосед, без перескока через озеро.
    var origin_height: float = world.height_at(
        Vector2(cell) + Vector2(0.5, 0.5))
    var lowest := origin_height - 0.02
    var found := Vector2i(-1, -1)
    for offset in [
            Vector2i(1, 0), Vector2i(0, 1),
            Vector2i(-1, 0), Vector2i(0, -1)]:
        var target: Vector2i = cell + offset
        if not world.config.contains_cell(target):
            continue
        var i: int = hydro.cell_index(target)
        if hydro.has_water(i) or hydro.flooded_at(i):
            continue
        var height: float = world.height_at(
            Vector2(target) + Vector2(0.5, 0.5))
        if is_finite(height) and height < lowest:
            lowest = height
            found = target
    return found


func _test_runoff() -> void:
    # Ищем открытый участок с настоящим уклоном. Золу загружаем
    # в строгом формате реестра: источник берётся из сохранённого
    # физического состояния, а не из графического эффекта.
    var m: Dictionary = _models()
    var world: RefCounted = m["world"]
    var hydro: RefCounted = m["hydro"]
    var surface: RefCounted = m["surface"]
    var climate: RefCounted = m["climate"]
    var nature: RefCounted = m["nature"]
    var fire: RefCounted = m["fire"]
    var cell := Vector2i(-1, -1)
    var target := Vector2i(-1, -1)
    for y in range(8, 72):
        if cell.x >= 0:
            break
        for x in range(8, 88):
            var proposed := Vector2i(x, y)
            var index: int = hydro.cell_index(proposed)
            if hydro.has_water(index) or hydro.flooded_at(index):
                continue
            var lower := _lower_land(world, hydro, proposed)
            if lower.x < 0:
                continue
            cell = proposed
            target = lower
            break
    _check(cell.x >= 0, "Найден физический сухопутный склон")
    if cell.x < 0:
        return

    var source_index: int = hydro.cell_index(cell)
    var initial := {
        "version": 3, "day": 1, "total_ignitions": 0,
        "fires": [], "scorched": [[source_index, 850, 1]],
        "embers": []
    }
    _check(fire.load_data(initial), "Исходное зольное пятно прошло JSON")
    if fire.scorched_count() != 1:
        return

    # Без дождевого стока зола остаётся в исходной клетке,
    # а теряется лишь от естественного восстановления.
    climate.set_day(2)
    surface.advance_climate_day(climate)
    surface._runoff.fill(0.0)
    nature.advance_day(2)
    fire.advance_day(2)
    _check(fire.scorched_at(target) == 0.0
        and absf(fire.scorched_at(cell) - 0.838) < 0.00001,
        "При нулевом стоке пепел не перемещается по склону")

    # Подаём физический сток 2.0 только в одну клетку:
    # перенос ограничен 130 единицами из существующих 826.
    climate.set_day(3)
    surface.advance_climate_day(climate)
    surface._runoff.fill(0.0)
    surface._runoff[source_index] = 2.0
    nature.advance_day(3)
    var moved: Array[Dictionary] = fire.advance_day(3)
    var source_ash := roundi(fire.scorched_at(cell) * 1000.0)
    var target_ash := roundi(fire.scorched_at(target) * 1000.0)
    _check(source_ash == 696 and target_ash == 130,
        "Сток переносит ровно 130 единиц на соседнюю нижнюю клетку")
    _check(source_ash + target_ash == 826,
        "Сток не создаёт и не теряет массу сверх естественной убыли")
    _check(moved.any(func(event: Dictionary) -> bool:
        return event["kind"] == "зольный сток"),
        "О переносе остаётся физическое суточное событие")

    # Полное сохранение должно восстановить и источник, и новую
    # клетку назначения, включая количество и дату пепла.
    var state := {
        "world": world, "hydro": hydro, "surface": surface,
        "climate": climate, "nature": nature, "fire": fire,
        "weather": Weather.new(world, climate, surface, hydro),
        "natural": Processes.new(world, hydro, surface, climate),
        "disasters": Disasters.new(world, hydro, surface, climate)
    }
    var snapshot: Dictionary = Save.capture(state)
    _check(not snapshot.is_empty(), "Сохранён общий мир после стока")
    if not snapshot.is_empty():
        var loaded: Dictionary = Save.restore(
            JSON.parse_string(JSON.stringify(snapshot)))
        _check(not loaded.is_empty(),
            "Мир со смытой золой успешно восстанавливается")
        if not loaded.is_empty():
            _check(loaded["fire"].to_data() == fire.to_data(),
                "После восстановления сохраняется распределение золы")

    # Два вызова одной даты не передвигают золу дважды.
    var same_day: Dictionary = fire.to_data()
    _check(fire.advance_day(3).is_empty()
        and fire.to_data() == same_day,
        "Повторный день не дублирует зольный сток")

    # На следующем сухом дне каждая сохранённая клетка теряет
    # свой естественный минимум, но без стока осадок не переходит.
    climate.set_day(4)
    surface.advance_climate_day(climate)
    surface._runoff.fill(0.0)
    nature.advance_day(4)
    fire.advance_day(4)
    _check(roundi(fire.scorched_at(cell) * 1000.0) == 684
        and roundi(fire.scorched_at(target) * 1000.0) == 118,
        "Естественное восстановление продолжает работать после стока")


func _run() -> void:
    # Тест проверяет фактический перенос и замкнутый баланс
    # осадка, а не только видимую смену цвета у берега.
    _test_runoff()
    if not failures.is_empty():
        for message in failures:
            printerr("11.5/F4: ", message)
        quit(1)
        return
    print("11.5/F4: дождевой сток, баланс пепла и JSON — успешно")
    quit(0)


func _initialize() -> void:
    # Запускаем тест после инициализации классов Godot.
    call_deferred("_run")
