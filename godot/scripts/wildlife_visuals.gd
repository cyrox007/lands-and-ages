extends Node3D
## Видимая фауна — это лишь окно в уже существующие популяции.
## Не создаёт животных, не расходует добычу и не рисует кубов.

const Actor = preload("res://scripts/wildlife_visual_actor.gd")
const Paths = preload("res://scripts/world_resource_path.gd")
const Terrain = preload("res://scripts/terrain.gd")

const ROOT := "res://assets/fauna/"
const MAX_VISIBLE := 16
const MAX_RENDER_RANGE := 42.0
const UPDATE_INTERVAL := 0.60
const MODELS := {
    "олень": {"file": "Deer.gltf", "source": "Quaternius", "height": 1.6},
    "тур": {"file": "Stag.gltf", "source": "Quaternius", "height": 1.8},
    "волк": {"file": "Wolf.gltf", "source": "Quaternius", "height": 0.9},
    "лиса": {"file": "Fox.gltf", "source": "Quaternius", "height": 0.48},
    "корова": {"file": "Cow.gltf", "source": "Quaternius", "height": 1.4},
    "собака": {"file": "Husky.gltf", "source": "Quaternius", "height": 0.7},
    "кабан": {"file": "Boar.glb", "source": "Gobkit", "height": 0.9}
}

var world: RefCounted
var hydro: RefCounted
var surface: RefCounted
var wildlife: RefCounted
var predators: RefCounted
var _models: Dictionary = {}
var _visible: Dictionary = {}
var _elapsed := 0.0
var _last_population_day := -1


func configure(map: RefCounted, water: RefCounted,
        ground: RefCounted, fauna: RefCounted,
        food: RefCounted) -> void:
    # При загрузке другого мира выбрасываем только графические
    # узлы. Данные популяций и охотничьи запасы остаются нетронуты.
    for actor in _visible.values():
        (actor as Node3D).queue_free()
    _visible.clear()
    world = map
    hydro = water
    surface = ground
    wildlife = fauna
    predators = food
    _elapsed = UPDATE_INTERVAL
    _last_population_day = -1


func available_models() -> int:
    # Если лицензированные бинарные модели не установлены,
    # ничего не подменяем примитивами или картинками.
    var ready := 0
    for kind in MODELS:
        if ResourceLoader.exists(ROOT + str(MODELS[kind]["file"])):
            ready += 1
    return ready


func _scene(species: String) -> PackedScene:
    # Один импортированный PackedScene переиспользуется всеми
    # видимыми экземплярами данного вида и кэшируется.
    if _models.has(species):
        return _models[species]
    if not MODELS.has(species):
        return null
    var path := ROOT + str(MODELS[species]["file"])
    if not ResourceLoader.exists(path):
        return null
    var resource := ResourceLoader.load(path) as PackedScene
    if resource != null:
        _models[species] = resource
    return resource


func _population(region: Vector2i, kind: String) -> int:
    # Показать зверя можно только при наличии хотя бы одной
    # живой особи в соответствующем природном реестре.
    if kind in ["волк", "лиса"]:
        return predators.count_at(region, kind)
    return wildlife.population_at(region, kind)


func _position(region: Vector2i, kind: String,
        center: Vector2) -> Vector2i:
    # Внешний вид не меняет физический мир. Ищем настоящую
    # проходимую клетку внутри региона с уже существующим стадом.
    var bounds: Rect2i = world.config.region_rect(region)
    var anchor := Vector2i(
        clampi(roundi(center.x), bounds.position.x, bounds.end.x - 1),
        clampi(roundi(center.y), bounds.position.y, bounds.end.y - 1))
    var seed: int = world.config.world_seed + kind.hash()
    for i in range(24):
        var dx := roundi((Terrain.hash2(i, region.x, seed) - 0.5) * 24.0)
        var dy := roundi((Terrain.hash2(i, region.y, seed + 93) - 0.5) * 24.0)
        var cell := Vector2i(
            clampi(anchor.x + dx, bounds.position.x, bounds.end.x - 1),
            clampi(anchor.y + dy, bounds.position.y, bounds.end.y - 1))
        if Paths.walkable(world, hydro, surface, cell):
            return cell
    return Vector2i(-1, -1)


func refresh(center: Vector2, camera_width: float,
        delta: float = UPDATE_INTERVAL) -> void:
    # Пересоздание не допускается каждый кадр. Число узлов строго
    # ограничено, а при отсутствии ассета вид остаётся невидимым.
    if world == null or wildlife == null or predators == null:
        return
    _elapsed += delta
    if _elapsed < UPDATE_INTERVAL \
            and _last_population_day == wildlife.last_day:
        return
    _elapsed = 0.0
    _last_population_day = wildlife.last_day
    var radius := minf(MAX_RENDER_RANGE, camera_width * 0.62)
    var desired := {}
    var sizes: Vector2i = world.config.region_count()
    for ry in range(sizes.y):
        for rx in range(sizes.x):
            var region := Vector2i(rx, ry)
            for kind in MODELS:
                if desired.size() >= MAX_VISIBLE:
                    break
                if _population(region, kind) <= 0 or _scene(kind) == null:
                    continue
                var cell: Vector2i = _position(region, kind, center)
                if cell.x < 0:
                    continue
                var spot := Vector2(float(cell.x) + 0.5, float(cell.y) + 0.5)
                if spot.distance_to(center) > radius:
                    continue
                var key := "%s:%d:%d" % [kind, rx, ry]
                desired[key] = {"kind": kind, "cell": cell}
    for key in _visible.keys():
        if desired.has(key):
            continue
        (_visible[key] as Node3D).queue_free()
        _visible.erase(key)
    for key in desired:
        if _visible.has(key):
            continue
        var entry: Dictionary = desired[key]
        var kind: String = entry["kind"]
        var actor := Actor.new()
        if not actor.configure(kind, _scene(kind),
                str(MODELS[kind]["source"]), float(MODELS[kind]["height"])):
            actor.free()
            continue
        var cell: Vector2i = entry["cell"]
        var flat := Vector2(float(cell.x) + 0.5, float(cell.y) + 0.5)
        actor.position = world.config.to_scene(flat, world.height_at(flat))
        actor.rotation.y = Terrain.hash2(cell.x, cell.y,
            world.config.world_seed + kind.hash()) * TAU
        # Графические движения не инициируют охоту и не меняют
        # численность: это только спокойный жест видимого животного.
        actor.set_motion("покой")
        add_child(actor)
        _visible[key] = actor


func active_count() -> int:
    # Для мобильного бюджета отслеживаем только настоящие
    # скелетные узлы, создаваемые текущим видимым участком.
    return _visible.size()


func stats() -> Dictionary:
    # Отладка не должна объявлять отсутствующие модели готовыми.
    return {"installed": available_models(), "catalog": MODELS.size(),
        "visible": active_count(), "limit": MAX_VISIBLE}
