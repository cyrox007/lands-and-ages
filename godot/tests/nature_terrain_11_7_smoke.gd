extends SceneTree
## 11.7/RF2 — реальное повреждение леса и коллизии после деформации карты.

const Config = preload("res://scripts/world_config.gd")
const Map = preload("res://scripts/world_map.gd")
const Hydro = preload("res://scripts/hydrology.gd")
const Surface = preload("res://scripts/surface.gd")
const Climate = preload("res://scripts/climate.gd")
const Nature = preload("res://scripts/nature_registry.gd")
const Collisions = preload("res://scripts/nature_collision.gd")
const Landscape = preload("res://scripts/landscape_events.gd")
const Save = preload("res://scripts/world_save.gd")
const Weather = preload("res://scripts/weather_events.gd")
const Processes = preload("res://scripts/natural_processes.gd")
const Disasters = preload("res://scripts/natural_disasters.gd")
const Fire = preload("res://scripts/fire_registry.gd")
const Runner = preload("res://scripts/world_day_runner.gd")

const CENTER := Vector2(42.5, 30.5)
const RADIUS := 9.0
var failures: Array[String] = []


func _check(ok: bool, reason: String) -> void:
    # Несколько независимых проверок позволяют отличить ошибку
    # физического ресурса от ошибки обновления графики или JSON.
    if not ok:
        failures.append(reason)


func _item(world: RefCounted, cell: Vector2i,
        kind: String, wood: int = 0) -> Dictionary:
    # ID по-прежнему соответствует координатам — инвариант
    # действующего NatureRegistry и его старых сохранений.
    return {
        "id": cell.y * world.config.width + cell.x + 1,
        "kind": kind,
        "species": "сосна" if kind == "дерево" else (
            "камень" if kind == "валун" else "кустарник"),
        "x": cell.x, "y": cell.y, "age_days": 18 * 96,
        "health": 1000, "wood_units": wood, "fallen_wood": 0,
        "cut_progress": 0, "dead_since_day": -1,
        "fallen_since_day": -1, "fall_angle_deg": -1,
        "state": "целое", "radius": 0.35 if kind == "валун" else 0.17
    }


func _models() -> Dictionary:
    # Полная физическая карта с реальными реестрами, но фиксированными
    # четырьмя объектами в известной зоне, чтобы тест не зависел
    # от случайной плотности процедурного леса.
    var world := Map.new(Config.new(80, 72, 1199, 16, 32))
    var planned := {}
    for y in range(73):
        for x in range(81):
            planned[Vector2i(x, y)] = 8.0 + (80.0 - float(x)) * 0.05
    _check(world.apply_vertex_changes(planned), "Физический склон создан")
    world.take_dirty_chunks()
    var hydro := Hydro.new(world)
    hydro.rebuild()
    var surface := Surface.new(world, hydro)
    surface.rebuild()
    var climate := Climate.new(world, hydro)
    climate.rebuild()
    _check(climate.set_day(1), "Климат перешёл к первому дню")
    _check(surface.advance_climate_day(climate), "Почва согласована с климатом")
    _check(hydro.apply_rainfall_map(surface.runoff_map()),
        "Речной сток рассчитан")
    var nature := Nature.new(world, hydro, surface, climate)
    _check(nature.generate(), "Природный реестр сформирован")
    nature._objects.clear()
    nature._chunks.clear()
    for entry in [
        _item(world, Vector2i(42, 30), "дерево", 12),
        _item(world, Vector2i(44, 30), "кустарник"),
        _item(world, Vector2i(49, 30), "валун"),
        _item(world, Vector2i(70, 60), "дерево", 8)
    ]:
        nature._objects[int(entry["id"])] = entry
        nature._index(entry)
    return {
        "world": world, "hydro": hydro, "surface": surface,
        "climate": climate, "nature": nature,
        "weather": Weather.new(world, climate, surface, hydro),
        "natural": Processes.new(world, hydro, surface, climate),
        "disasters": Disasters.new(world, hydro, surface, climate),
        "fire": Fire.new(world, hydro, surface, climate, nature)
    }


func _parts(body: StaticBody3D, id: int) -> Array[String]:
    # Проверяем действительные CollisionShape3D, а не имя меша.
    var result: Array[String] = []
    for child in body.get_children():
        if child is CollisionShape3D and int(child.get_meta("nature_id", -1)) == id:
            result.append(str(child.get_meta("nature_part")))
    result.sort()
    return result


func _shape_y(body: StaticBody3D, id: int, part: String) -> float:
    # Позиция физической формы должна совпадать с новой высотой
    # поверхности даже после выгрузки и повторного создания чанка.
    for child in body.get_children():
        if child is CollisionShape3D \
                and int(child.get_meta("nature_id", -1)) == id \
                and str(child.get_meta("nature_part")) == part:
            return child.transform.origin.y
    return NAN


func _exercise() -> Dictionary:
    var state: Dictionary = _models()
    var world: RefCounted = state["world"]
    var nature: RefCounted = state["nature"]
    var tree := _item(world, Vector2i(42, 30), "дерево", 12)
    var shrub := _item(world, Vector2i(44, 30), "кустарник")
    var stone := _item(world, Vector2i(49, 30), "валун")
    var distant := _item(world, Vector2i(70, 60), "дерево", 8)
    var tree_id: int = int(tree["id"])
    var shrub_id: int = int(shrub["id"])
    var stone_id: int = int(stone["id"])
    var distant_id: int = int(distant["id"])
    var stone_cell := Vector2i(49, 30)
    var stone_chunk: Vector2i = world.config.chunk_of(stone_cell)
    var old_shape := Collisions.create_chunk(world, nature, stone_chunk)
    var old_stone_y := _shape_y(old_shape, stone_id, "камень")
    old_shape.free()

    var notifications := {"count": 0}
    nature.objects_changed.connect(func(_chunks: Array[Vector2i],
            _revision: int) -> void:
        notifications["count"] = int(notifications["count"]) + 1
    )
    var before_wood: int = nature.wood_total()
    var before_far: Dictionary = nature.object_at(distant_id)
    var impact: Dictionary = Landscape.new(world).apply(
        "кратер", CENTER, RADIUS, 1.8)
    _check(not impact.is_empty(), "Кратер изменил настоящие высоты")
    var reaction: Dictionary = nature.apply_landscape_impact(
        "кратер", CENTER, RADIUS, 1.0, state["climate"].day)
    _check(int(reaction["trees_felled"]) == 1,
        "Дерево возле эпицентра вывернуто из грунта")
    _check(int(reaction["shrubs_damaged"]) == 1,
        "Кустарник получил повреждение от обвала грунта")
    _check(int(reaction["boulders_rebased"]) == 1,
        "Валун остался тем же объектом на новой высоте")
    _check(int(notifications["count"]) == 1,
        "Система оповестила об изменении локальных чанков один раз")
    _check(nature.object_at(distant_id) == before_far,
        "Дальний лес не изменился")

    var fallen: Dictionary = nature.object_at(tree_id)
    _check(fallen["state"] == "пень"
        and int(fallen["wood_units"]) == 0
        and int(fallen["fallen_wood"]) == 12
        and int(fallen["fallen_since_day"]) == 1,
        "Вся древесина перенесена в одно лежащее бревно")
    _check(int(fallen["fall_angle_deg"]) >= 0
        and int(fallen["fall_angle_deg"]) < 360,
        "Направление падения сохранено в целых градусах")
    _check(nature.wood_total() == before_wood,
        "Обвал не создаёт и не уничтожает древесину")
    _check(int(nature.object_at(shrub_id)["health"]) < 1000,
        "Повреждение кустарника — физическое состояние, не цвет GPU")

    # И гидрология, и графика после кратера используют те же вершины.
    var runner := Runner.new(world, state["hydro"], state["surface"],
        state["climate"], state["weather"], state["natural"],
        state["disasters"], nature, state["fire"])
    _check(runner.synchronize_world(), "Пересчитаны зависимые слои")
    var current_shape := Collisions.create_chunk(world, nature, stone_chunk)
    var new_stone_y := _shape_y(current_shape, stone_id, "камень")
    var stone_point := Vector2(49.5, 30.5)
    var expected_y: float = world.config.to_scene(
        stone_point, world.height_at(stone_point)).y + 0.225
    _check(is_finite(new_stone_y) and is_finite(old_stone_y)
        and absf(new_stone_y - old_stone_y) > 0.001,
        "Каменная коллизия действительно сменила высоту")
    _check(absf(new_stone_y - expected_y) < 0.0001,
        "Коллизия камня точно совпадает с высотой рельефа")
    current_shape.free()
    var tree_body := Collisions.create_chunk(
        world, nature, world.config.chunk_of(Vector2i(42, 30)))
    _check(_parts(tree_body, tree_id) == ["бревно", "пень"],
        "После деформации вместо ствола существуют пень и бревно")
    tree_body.free()

    # Снимок WorldSave включает реальные объекты, геометрию, сток
    # и климат, а не только отдельно сохранённый массив высот.
    var snapshot: Dictionary = Save.capture(state)
    _check(not snapshot.is_empty(), "Полный WorldSave с кратером создан")
    if not snapshot.is_empty():
        var restored: Dictionary = Save.restore(
            JSON.parse_string(JSON.stringify(snapshot)))
        _check(not restored.is_empty(), "Мир после кратера загружен целиком")
        if not restored.is_empty():
            _check(restored["nature"].to_data() == nature.to_data(),
                "Состояние леса, древесина и валуны восстановлены")
            _check(restored["world"].to_data() == world.to_data(),
                "Физическая геометрия без потерь вернулась из JSON")
            var loaded_shape := Collisions.create_chunk(
                restored["world"], restored["nature"], stone_chunk)
            _check(absf(_shape_y(loaded_shape, stone_id, "камень")
                - new_stone_y) < 0.0001,
                "Коллизия камня восстановлена после загрузки")
            loaded_shape.free()

    # Незавершённое событие и медленная эрозия не должны давать
    # самостоятельный удар и повторную передачу древесины.
    var saved_nature: Dictionary = nature.to_data()
    nature.apply_landscape_impact("эрозия", CENTER, RADIUS, 1.0, 1)
    _check(nature.to_data() == saved_nature,
        "Эрозия не имитирует мгновенное падение дерева")
    return {"world": world.to_data(), "nature": nature.to_data()}


func _natural_event() -> void:
    # Отдельно проверяем реальный путь природного дня: геологическая
    # запись обрабатывается через NatureRegistry.advance_day, а не
    # через ручную команду редактора или графические эффекты.
    var state: Dictionary = _models()
    var world: RefCounted = state["world"]
    var nature: RefCounted = state["nature"]
    var climate: RefCounted = state["climate"]
    var source := Vector2i(42, 30)
    var impact: Dictionary = Landscape.new(world).apply(
        "просадка", CENTER, 7.0, 1.0)
    _check(not impact.is_empty(), "Тектоническая просадка изменила мир")
    _check(climate.set_day(2), "Новый игровой день установлен")
    _check(state["surface"].advance_climate_day(climate),
        "Суточная физика поверхности обновлена")
    state["hydro"].apply_rainfall_map(state["surface"].runoff_map())
    _check(nature.advance_day(2, [{
        "kind": "землетрясение", "cell": source,
        "severity": 1.0, "vertices": impact["vertices"]
    }]) >= 0, "День с тектоническим воздействием выполнен")
    _check(nature.object_at(int(_item(world, source, "дерево")["id"]))["state"]
        == "пень", "Естественное землетрясение валит дерево")
    _check(nature.advance_day(2) == 0, "Повтор дня не наносит новый урон")


func _initialize() -> void:
    # Одинаковый seed, порядок обработки и сила события воспроизводят
    # одинаковые физические снимки без опоры на камеру или FPS.
    var first: Dictionary = _exercise()
    var second: Dictionary = _exercise()
    _check(first == second, "Состояние после геологических событий детерминировано")
    _natural_event()
    if not failures.is_empty():
        for failure in failures:
            push_error("11.7/RF2: " + failure)
        quit(1)
        return
    print("11.7/RF2: объекты, коллизии, баланс и WorldSave — успешно.")
    quit(0)
