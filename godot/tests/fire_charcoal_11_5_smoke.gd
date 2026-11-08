extends SceneTree
## 11.5/F5b2d1: конечный древесный уголь после настоящего горения.

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
    # Ошибки массы, сбора и сериализации независимы. Сохраняем
    # всю диагностику, даже если один из контрольных шагов не прошёл.
    if not ok:
        failures.append(message)


func _models() -> Dictionary:
    # Физическое топливо берётся из растущих деревьев мира,
    # гидрология и климат используются настоящие, не макеты.
    var world := Map.new(Config.new(96, 80, 1729, 16, 32))
    var hydro := Hydro.new(world)
    hydro.rebuild()
    var surface := Surface.new(world, hydro)
    surface.rebuild()
    var climate := Climate.new(world, hydro)
    climate.rebuild()
    climate.set_day(1)
    _check(surface.advance_climate_day(climate), "Первый день грунта готов")
    hydro.apply_rainfall_map(surface.runoff_map())
    var nature := Nature.new(world, hydro, surface, climate)
    _check(nature.generate(), "Настоящие деревья сгенерированы")
    return {
        "world": world, "hydro": hydro, "surface": surface,
        "climate": climate, "nature": nature,
        "fire": Fire.new(world, hydro, surface, climate, nature)
    }


func _dry_day(m: Dictionary, day: int, dry: bool) -> void:
    # Согласуем календарь всех моделей до шага физики огня.
    # Управляем только влажностью локального испытательного мира;
    # тест не подменяет сгорание изменением ресурсного словаря.
    var climate: RefCounted = m["climate"]
    var surface: RefCounted = m["surface"]
    var nature: RefCounted = m["nature"]
    _check(climate.set_day(day), "Климат пересчитан для дня %d" % day)
    _check(surface.advance_climate_day(climate),
        "Грунт пересчитан для дня %d" % day)
    surface._moisture.fill(0.02 if dry else 1.0)
    surface._snow.fill(0.0)
    climate._rain.fill(0.0 if dry else 2.0)
    nature.advance_day(day)


func _test_tree_charcoal_and_save() -> void:
    # Важен расход существующей древесины, а не возникновение
    # ресурса только из события молнии или нарисованного огня.
    var m: Dictionary = _models()
    var world: RefCounted = m["world"]
    var hydro: RefCounted = m["hydro"]
    var surface: RefCounted = m["surface"]
    var climate: RefCounted = m["climate"]
    var nature: RefCounted = m["nature"]
    var fire: RefCounted = m["fire"]
    var tree: Dictionary = {}
    for record in nature.to_data()["objects"]:
        if record[1] != "дерево" or record[9] != "целое":
            continue
        var position := Vector2i(int(record[3]), int(record[4]))
        if position.x < 10 or position.y < 10 \
                or position.x >= 86 or position.y >= 70 \
                or int(record[7]) < 35:
            continue
        tree = nature.object_at(int(record[0]))
        break
    _check(not tree.is_empty(), "Найдено взрослое дерево для пожара")
    if tree.is_empty():
        return
    var id: int = int(tree["id"])
    var cell := Vector2i(int(tree["x"]), int(tree["y"]))
    _check(fire.charcoal_at(cell) == 0 and fire.charcoal_total() == 0,
        "До физического горения угля в мире нет")
    _check(not fire.take_charcoal(cell, 1)
        and not fire.take_charcoal(cell, -1),
        "Пустая клетка и отрицательный сбор запрещены")

    _dry_day(m, 2, true)
    fire.advance_day(2, [], cell)
    _check(fire.is_burning(id) and fire.charcoal_total() == 0,
        "Начало пожара не создаёт готовый уголь")
    _dry_day(m, 3, true)
    var old_wood: int = int(nature.object_at(id)["wood_units"])
    fire.advance_day(3)
    var consumed: int = old_wood - int(nature.object_at(id)["wood_units"])
    var deposited: int = fire.charcoal_at(cell)
    _check(consumed > 0 and deposited == consumed * 2,
        "Уголь получен из настоящего расхода древесины: не более 20% массы")
    _check(fire.charcoal_total() == deposited and deposited > 0,
        "Сумма угля совпадает с запасом клетки")
    _check(not fire.take_charcoal(cell, 1),
        "Нельзя собирать уголь пока дерево или подстилка горят")
    var on_day: Dictionary = fire.to_data()
    _check(fire.advance_day(3).is_empty() and fire.to_data() == on_day,
        "Повторная обработка суток не создаёт вторую порцию угля")

    # Полный снимок сохраняет ресурс независимо от сцены, дыма
    # и загрузки старого мира. Нужна проверка именно WorldSave.
    var state := {
        "world": world, "hydro": hydro, "surface": surface,
        "climate": climate, "nature": nature, "fire": fire,
        "weather": Weather.new(world, climate, surface, hydro),
        "natural": Processes.new(world, hydro, surface, climate),
        "disasters": Disasters.new(world, hydro, surface, climate)
    }
    var snapshot: Dictionary = Save.capture(state)
    _check(not snapshot.is_empty(), "Снимок с физическим углём сохранён")
    if not snapshot.is_empty():
        var loaded: Dictionary = Save.restore(
            JSON.parse_string(JSON.stringify(snapshot)))
        _check(not loaded.is_empty(), "Мир с ресурсом угля загружен")
        if not loaded.is_empty():
            _check(loaded["fire"].to_data() == fire.to_data()
                and loaded["fire"].charcoal_at(cell) == deposited,
                "После загрузки запас угля не изменился")

    # Плохая сериализация не должна разрушить существующий пожар:
    # проверяем количество, дубли и значение вне допустимого индекса.
    var before: Dictionary = fire.to_data()
    _check(int(before["version"]) == 8 and before["charcoal"].size() > 0,
        "Шестая версия сохраняет прежний физический уголь")
    var wrong: Dictionary = before.duplicate(true)
    wrong["charcoal"].append(wrong["charcoal"][0].duplicate())
    _check(not fire.load_data(wrong) and fire.to_data() == before,
        "Дубли запасов угля отвергаются без потери действующего мира")
    wrong = before.duplicate(true)
    wrong["charcoal"][0][1] = 1001
    _check(not fire.load_data(wrong) and fire.to_data() == before,
        "Переполнение единичного запаса отвергается")
    wrong = before.duplicate(true)
    wrong["charcoal"][0][0] = world.config.width * world.config.height
    _check(not fire.load_data(wrong) and fire.to_data() == before,
        "Выход за пределы физической карты отвергается")
    wrong = before.duplicate(true)
    wrong["charcoal"][0][1] = 1.5
    _check(not fire.load_data(wrong) and fire.to_data() == before,
        "Нецелая ресурсная порция недопустима")

    # Прежний v4 хранил ожог почвы, но не ресурс угля. Его чтение
    # не должно стирать сохранённую ранее почвенную травму.
    var older: Dictionary = before.duplicate(true)
    older["version"] = 4
    older.erase("charcoal")
    var old_fire := Fire.new(world, hydro, surface, climate, nature)
    _check(old_fire.load_data(older)
        and old_fire.charcoal_total() == 0
        and old_fire.soil_damage_at(cell) == fire.soil_damage_at(cell),
        "Сохранения v4 загружаются без угля и без потери ожога")

    # Мокрый грунт тушит активные очаги. После их затухания
    # результат можно забрать лишь в пределах оставшегося запаса.
    _dry_day(m, 4, false)
    fire.advance_day(4)
    var available: int = fire.charcoal_at(cell)
    _check(available >= deposited and available > 0,
        "Тушение не уничтожает уже образовавшийся твёрдый уголь")
    _check(fire.smolder_count() == 0 and fire.burning_count() == 0,
        "Горение и тление полностью потушены")
    _check(not fire.take_charcoal(cell, available + 1),
        "Нельзя забрать больше физического остатка")
    _check(fire.take_charcoal(cell, 1)
        and fire.charcoal_at(cell) == available - 1,
        "Разрешён частичный сбор после остывания")
    _check(fire.take_charcoal(cell, available - 1)
        and fire.charcoal_at(cell) == 0
        and fire.charcoal_cell_count() == 0,
        "Полный сбор удаляет пустую ресурсную запись")
    _check(not fire.take_charcoal(cell, 1),
        "Повторный сбор не порождает бесконечный уголь")


func _run() -> void:
    # При любом несоответствии CI получит ошибку, а не только
    # сообщение об успехе из предыдущего сценария F5b2c.
    _test_tree_charcoal_and_save()
    if not failures.is_empty():
        for message in failures:
            printerr("11.5/F5b2d1: ", message)
        quit(1)
        return
    print("11.5/F5b2d1: древесный уголь, сбор, JSON и баланс — успешно")
    quit(0)


func _initialize() -> void:
    # Выполняем тест после готовности SceneTree в headless Godot.
    call_deferred("_run")
