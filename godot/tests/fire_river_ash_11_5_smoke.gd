extends SceneTree
## 11.5/F5b2e1: зола из поверхностного стока попадает в речную взвесь.

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
    # Проверяем каждый инвариант отдельно: масса, русло, JSON
    # и однократность суточного переноса не заменяют друг друга.
    if not ok:
        failures.append(message)


func _models() -> Dictionary:
    # Создаём настоящий водосбор с лесом и климатом, без вручную
    # нарисованного потока и отключения гидрологических правил.
    var world := Map.new(Config.new(96, 80, 1729, 16, 32))
    var hydro := Hydro.new(world)
    hydro.rebuild()
    var surface := Surface.new(world, hydro)
    surface.rebuild()
    var climate := Climate.new(world, hydro)
    climate.rebuild()
    climate.set_day(1)
    _check(surface.advance_climate_day(climate), "Грунт первого дня готов")
    hydro.apply_rainfall_map(surface.runoff_map())
    var nature := Nature.new(world, hydro, surface, climate)
    _check(nature.generate(), "Природная растительность создана")
    return {
        "world": world, "hydro": hydro, "surface": surface,
        "climate": climate, "nature": nature,
        "fire": Fire.new(world, hydro, surface, climate, nature)
    }


func _bank(world: RefCounted, hydro: RefCounted) -> Dictionary:
    # Ищем берег, у которого нет нижнего сухого соседа, зато есть
    # расположенное ниже реальное речное дно. Тогда F4 не забирает
    # всю золу в сухопутное русло до входа в воду.
    for y in range(8, world.config.height - 8):
        for x in range(8, world.config.width - 8):
            var cell := Vector2i(x, y)
            var index: int = hydro.cell_index(cell)
            if hydro.has_water(index) or hydro.flooded_at(index):
                continue
            var height: float = world.height_at(
                Vector2(cell) + Vector2(0.5, 0.5))
            if not is_finite(height):
                continue
            var lowest: float = height - 0.02
            var bank := Vector2i(-1, -1)
            var has_lower_land := false
            for offset in [
                    Vector2i(1, 0), Vector2i(0, 1),
                    Vector2i(-1, 0), Vector2i(0, -1)]:
                var next: Vector2i = cell + offset
                if not world.config.contains_cell(next):
                    continue
                var ni: int = hydro.cell_index(next)
                var next_height: float = world.height_at(
                    Vector2(next) + Vector2(0.5, 0.5))
                if not is_finite(next_height) or next_height >= lowest:
                    continue
                if not hydro.has_water(ni) and not hydro.flooded_at(ni):
                    has_lower_land = true
                    break
                if hydro.river_at(ni) and hydro.has_water(ni):
                    lowest = next_height
                    bank = next
            if not has_lower_land and bank.x >= 0:
                return {"source": cell, "river": bank}
    return {}


func _advance_day(m: Dictionary, day: int, source: Vector2i,
        runoff: float) -> Array[Dictionary]:
    # Сначала пересчитываются календарные модели, затем одна
    # контролируемая порция осадков поступает на выбранный берег.
    var climate: RefCounted = m["climate"]
    var surface: RefCounted = m["surface"]
    var nature: RefCounted = m["nature"]
    var fire: RefCounted = m["fire"]
    _check(climate.set_day(day), "Погода готова на день %d" % day)
    _check(surface.advance_climate_day(climate),
        "Грунт готов на день %d" % day)
    surface._runoff.fill(0.0)
    surface._runoff[m["hydro"].cell_index(source)] = runoff
    nature.advance_day(day)
    return fire.advance_day(day)


func _test_suspension() -> void:
    # Вся масса начинается с 850 единиц золы на настоящем берегу;
    # вода не получает бесплатного пепла из эффекта или генератора.
    var m: Dictionary = _models()
    var world: RefCounted = m["world"]
    var hydro: RefCounted = m["hydro"]
    var surface: RefCounted = m["surface"]
    var climate: RefCounted = m["climate"]
    var nature: RefCounted = m["nature"]
    var fire: RefCounted = m["fire"]
    var bank: Dictionary = _bank(world, hydro)
    _check(not bank.is_empty(), "На реальной карте найден берег реки")
    if bank.is_empty():
        return
    var source: Vector2i = bank["source"]
    var river: Vector2i = bank["river"]
    var index: int = hydro.cell_index(source)
    var saved: Dictionary = fire.to_data()
    saved["scorched"] = [[index, 850, 1]]
    _check(fire.load_data(saved), "Исходная зола принята JSON v6")
    if fire.scorched_count() != 1:
        return

    _advance_day(m, 2, source, 0.0)
    _check(fire.suspended_ash_total() == 0
        and fire.ash_mass_total() == 838,
        "Без стока вода чиста, зола теряет только суточную убыль")

    var events: Array[Dictionary] = _advance_day(m, 3, source, 2.0)
    _check(fire.suspended_ash_at(river) == 130
        and roundi(fire.scorched_at(source) * 1000.0) == 696,
        "Речной берег передал ровно 130 из существующих единиц золы")
    _check(fire.ash_mass_total() == 826
        and fire.suspended_ash_cell_count() == 1,
        "Баланс массы сохранён, не создана фиктивная взвесь")
    _check(events.any(func(event: Dictionary) -> bool:
        return event["kind"] == "зола в речную взвесь"),
        "Физический вход золы в реку зафиксирован событием")
    var current: Dictionary = fire.to_data()
    _check(fire.advance_day(3).is_empty()
        and current == fire.to_data(),
        "Зола не перемещается повторно в те же сутки")

    # При отсутствии нового дождевого стока вчерашняя взвесь может
    # передвинуться лишь на один участок вниз по течению за сутки.
    var river_index: int = hydro.cell_index(river)
    var downstream: int = hydro.downstream_of(river_index)
    var can_flow: bool = downstream >= 0 and downstream != river_index \
        and hydro.has_water(downstream)
    var flow: int = mini(130, clampi(
        roundi(hydro.discharge_at_index(river_index) * 7.0), 0, 160))
    _advance_day(m, 4, source, 0.0)
    _check(fire.ash_mass_total() == 814
        and fire.suspended_ash_total() == 130,
        "Течение сохраняет 130 единиц водной взвеси без потерь")
    if can_flow:
        _check(fire.suspended_ash_at(river) == 130 - flow
            and fire.suspended_ash_at(hydro.cell_from_index(downstream)) == flow,
            "Взвесь переместилась не более чем на одну клетку течения")
    else:
        _check(fire.suspended_ash_at(river) == 130,
            "При отсутствии продолжения русла зола не исчезает")

    # Полный WorldSave сохраняет обе части массы, а не только
    # пожарный JSON. Дневной календарь не пересчитывается при входе.
    var state := {
        "world": world, "hydro": hydro, "surface": surface,
        "climate": climate, "nature": nature, "fire": fire,
        "weather": Weather.new(world, climate, surface, hydro),
        "natural": Processes.new(world, hydro, surface, climate),
        "disasters": Disasters.new(world, hydro, surface, climate)
    }
    var snapshot: Dictionary = Save.capture(state)
    _check(not snapshot.is_empty(), "Мир с речной взвесью сохранён")
    if not snapshot.is_empty():
        var loaded: Dictionary = Save.restore(
            JSON.parse_string(JSON.stringify(snapshot)))
        _check(not loaded.is_empty(), "Мир с речной взвесью восстановлен")
        if not loaded.is_empty():
            _check(loaded["fire"].to_data() == fire.to_data()
                and loaded["fire"].ash_mass_total() == fire.ash_mass_total(),
                "После загрузки сохранены речные и сухопутные запасы")

    # Нельзя присвоить одну порцию двум участкам, переполнить
    # речную ячейку или подменить целые порции дробными.
    var valid: Dictionary = fire.to_data()
    _check(int(valid["version"]) == 6
        and not valid["suspended_ash"].is_empty(),
        "Новый речной слой существует только в формате v6")
    var invalid: Dictionary = valid.duplicate(true)
    invalid["suspended_ash"].append(invalid["suspended_ash"][0].duplicate())
    _check(not fire.load_data(invalid) and fire.to_data() == valid,
        "Дубли водной золы отклоняются атомарно")
    invalid = valid.duplicate(true)
    invalid["suspended_ash"][0][1] = 1001
    _check(not fire.load_data(invalid) and fire.to_data() == valid,
        "Переполненная взвесь отклоняется")
    invalid = valid.duplicate(true)
    invalid["suspended_ash"][0][1] = 1.5
    _check(not fire.load_data(invalid) and fire.to_data() == valid,
        "Дробный запас золы отклоняется")
    invalid = valid.duplicate(true)
    invalid["suspended_ash"][0][0] = world.config.width * world.config.height
    _check(not fire.load_data(invalid) and fire.to_data() == valid,
        "Индекс за границей мира отклоняется")

    # Версия v5 ещё не имела речной взвеси. Ожог, уголь, сухая
    # зола и тление из старого мира при этом не теряются.
    var older: Dictionary = valid.duplicate(true)
    older["version"] = 5
    older.erase("suspended_ash")
    var legacy := Fire.new(world, hydro, surface, climate, nature)
    _check(legacy.load_data(older)
        and legacy.suspended_ash_total() == 0
        and legacy.to_data()["scorched"] == valid["scorched"]
        and legacy.to_data()["charcoal"] == valid["charcoal"],
        "Старый v5 загружается без вымышленной речной золы")


func _run() -> void:
    # Интеграционная регрессия объединяет реальную географию,
    # баланс вещества, суточную адвекцию, JSON и обратную совместимость.
    _test_suspension()
    if not failures.is_empty():
        for message in failures:
            printerr("11.5/F5b2e1: ", message)
        quit(1)
        return
    print("11.5/F5b2e1: речная зольная взвесь, баланс и JSON — успешно")
    quit(0)


func _initialize() -> void:
    # Готовность SceneTree нужна для инициализации физики Godot.
    call_deferred("_run")
