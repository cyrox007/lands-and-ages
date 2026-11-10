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
const LOCAL_WALK_SPEED := 0.85
const MAX_WANDER_CELLS := 6.0
const WALK_DIRECTIONS := [
    Vector2i(1, 0), Vector2i(0, 1),
    Vector2i(-1, 0), Vector2i(0, -1)
]
const MODELS := {
    "олень": {"file": "Deer.gltf", "source": "Quaternius", "height": 1.6},
    "тур": {"file": "Bull.gltf", "source": "Quaternius", "height": 1.8},
    "волк": {"file": "Wolf.gltf", "source": "Quaternius", "height": 0.9},
    "лиса": {"file": "Fox.gltf", "source": "Quaternius", "height": 0.48},
    "корова": {"file": "Cow.gltf", "source": "Quaternius", "height": 1.4},
    "собака": {"file": "Husky.gltf", "source": "Quaternius", "height": 0.7},
    "кабан": {"file": "Boar.glb", "source": "Gobkit", "height": 0.9},
    # Подлинные скелетные GLB, а не примитивные заменители.
    "заяц": {"file": "Hare.glb", "source": "Gobkit", "height": 0.48},
    "дикий гусь": {"file": "Goose.glb", "source": "Gobkit", "height": 0.72},
    "гусь": {"file": "Goose.glb", "source": "Gobkit", "height": 0.72},
    "курица": {"file": "Rooster.glb", "source": "Gobkit", "height": 0.46},
    "дикая курица": {"file": "Rooster.glb", "source": "Gobkit", "height": 0.46}
}

var world: RefCounted
var hydro: RefCounted
var surface: RefCounted
var wildlife: RefCounted
var predators: RefCounted
var domestic: RefCounted
var _models: Dictionary = {}
var _visible: Dictionary = {}
var _movement: Dictionary = {}
var _elapsed := 0.0
var _last_population_day := -1


func configure(map: RefCounted, water: RefCounted,
        ground: RefCounted, fauna: RefCounted,
        food: RefCounted, farm: RefCounted = null) -> void:
    # При загрузке другого мира выбрасываем только графические
    # узлы. Данные популяций и охотничьи запасы остаются нетронуты.
    for actor in _visible.values():
        (actor as Node3D).queue_free()
    _visible.clear()
    # Состояния прогулок относятся только к показанным 3D-актёрам:
    # при загрузке чужого мира не переносим старые маршруты.
    _movement.clear()
    world = map
    hydro = water
    surface = ground
    wildlife = fauna
    predators = food
    domestic = farm
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
    if kind in ["волк", "лиса", "дикая кошка"]:
        return predators.count_at(region, kind)
    # Домашняя особь должна действительно пройти племенные
    # поколения и находиться на существующем хозяйственном дворе.
    if kind in ["корова", "собака", "курица", "гусь"]:
        if domestic == null or domestic.site.x < 0 \
                or region != world.config.region_of(domestic.site):
            return 0
        return domestic.total(kind, true)
    return wildlife.population_at(region, kind)


func _position(region: Vector2i, kind: String,
        center: Vector2) -> Vector2i:
    # Внешний вид не меняет физический мир. Ищем настоящую
    # проходимую клетку внутри региона с уже существующим стадом.
    var bounds: Rect2i = world.config.region_rect(region)
    # Для дикого зверя выбираем устойчивую точку его ареала:
    # смещение камеры не должно телепортировать животных вслед
    # за игроком и бесконечно менять выбор видимых особей.
    var anchor := Vector2i(
        bounds.position.x + bounds.size.x / 2,
        bounds.position.y + bounds.size.y / 2)
    # Домашних животных показываем у хозяйства, а не в точке
    # камеры на другом конце региона. Родословная остаётся
    # в модели фермы, визуальный объект её не меняет.
    if kind in ["корова", "собака", "курица", "гусь"] and domestic != null:
        anchor = domestic.site
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


func _nearest_candidates(center: Vector2,
        radius: float) -> Array[Dictionary]:
    # Подготовка списка не создаёт SceneTree-узлов и не меняет
    # экологическую численность. Проверяем только регионы рядом
    # с камерой, чтобы избежать лишних обходов крупных миров.
    var candidates: Array[Dictionary] = []
    var sizes: Vector2i = world.config.region_count()
    for ry in range(sizes.y):
        for rx in range(sizes.x):
            var region := Vector2i(rx, ry)
            var bounds: Rect2i = world.config.region_rect(region)
            var nearest := Vector2(
                clampf(center.x, float(bounds.position.x), float(bounds.end.x)),
                clampf(center.y, float(bounds.position.y), float(bounds.end.y)))
            if nearest.distance_squared_to(center) > radius * radius:
                continue
            for kind in MODELS:
                if _population(region, kind) <= 0:
                    continue
                var path := ROOT + str(MODELS[kind]["file"])
                if not ResourceLoader.exists(path):
                    continue
                var cell: Vector2i = _position(region, kind, center)
                if cell.x < 0:
                    continue
                var flat := Vector2(float(cell.x) + 0.5, float(cell.y) + 0.5)
                var distance: float = flat.distance_squared_to(center)
                if distance > radius * radius:
                    continue
                candidates.append({
                    "key": "%s:%d:%d" % [kind, rx, ry],
                    "kind": kind, "cell": cell, "distance": distance
                })
    # При равном расстоянии стабильный ключ вида и ареала
    # исключает мерцание порядка и лишнее создание актёров.
    candidates.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
        var difference: float = float(a["distance"]) - float(b["distance"])
        if absf(difference) > 0.0001:
            return difference < 0.0
        return str(a["key"]) < str(b["key"]))
    return candidates


func _walk_target(key: String, movement: Dictionary) -> Vector2i:
    # Животное перемещается только между соседними реальными
    # сухопутными клетками своего ареала, не переходит через
    # реки и не уходит за пределы локального участка прогулки.
    var cell: Vector2i = movement["cell"]
    var origin: Vector2i = movement["home"]
    var region: Vector2i = world.config.region_of(origin)
    var step: int = int(movement["step"])
    var offset := floori(Terrain.hash2(cell.x + step, cell.y,
        world.config.world_seed + key.hash()) * 4.0) % 4
    for index in range(4):
        var candidate: Vector2i = cell + WALK_DIRECTIONS[(offset + index) % 4]
        if world.config.region_of(candidate) != region \
                or Vector2(candidate - origin).length() > MAX_WANDER_CELLS:
            continue
        if Paths.walkable(world, hydro, surface, candidate):
            return candidate
    return cell


func _process(delta: float) -> void:
    # Покадровое движение обрабатывает не более MAX_VISIBLE актёров.
    # Скелетная ходьба синхронна с перемещением, а вне экрана
    # остаётся только числовая популяция без фоновой анимации.
    if world == null or not is_visible_in_tree():
        return
    var frame_time := minf(maxf(delta, 0.0), 0.10)
    for key in _visible:
        if not _movement.has(key):
            continue
        var actor := _visible[key] as Node3D
        var movement: Dictionary = _movement[key]
        if bool(movement["walking"]):
            var destination: Vector3 = movement["target"]
            actor.position = actor.position.move_toward(
                destination, frame_time * LOCAL_WALK_SPEED)
            if actor.position.distance_to(destination) < 0.0001:
                # move_toward сам доводит актёра до цели. Второй
                # принудительный скачок меша нарушал лимит пути
                # за кадр и выглядел бы как микротелепортация.
                movement["cell"] = movement["next"]
                movement["walking"] = false
                movement["rest"] = 1.4
                actor.set_motion("покой")
            continue
        movement["rest"] = maxf(0.0, float(movement["rest"]) - frame_time)
        if float(movement["rest"]) > 0.0:
            continue
        var next: Vector2i = _walk_target(str(key), movement)
        movement["step"] = int(movement["step"]) + 1
        if next == movement["cell"]:
            movement["rest"] = 2.5
            continue
        var flat := Vector2(float(next.x) + 0.5, float(next.y) + 0.5)
        var target: Vector3 = world.config.to_scene(
            flat, world.height_at(flat))
        var direction: Vector3 = target - actor.position
        if direction.length_squared() < 0.0001:
            movement["rest"] = 1.4
            continue
        actor.rotation.y = atan2(-direction.x, -direction.z)
        movement["target"] = target
        movement["next"] = next
        movement["walking"] = true
        actor.set_motion("ходьба")


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
    var ranked: Array[Dictionary] = _nearest_candidates(center, radius)
    for i in range(mini(MAX_VISIBLE, ranked.size())):
        # В первую очередь показываем ближайших к камере особей,
        # а не первые регионы в порядке обхода мировой сетки.
        var entry: Dictionary = ranked[i]
        desired[entry["key"]] = entry
    for key in _visible.keys():
        if desired.has(key):
            continue
        (_visible[key] as Node3D).queue_free()
        _visible.erase(key)
        _movement.erase(key)
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
        # Начальная клетка остаётся центром небольшой локальной
        # прогулки. Ключ берётся из существующего вида и ареала;
        # новых зверей это состояние не создаёт.
        _movement[key] = {
            "cell": cell, "home": cell, "step": 0,
            "rest": 1.5, "walking": false
        }


func active_count() -> int:
    # Для мобильного бюджета отслеживаем только настоящие
    # скелетные узлы, создаваемые текущим видимым участком.
    return _visible.size()


func stats() -> Dictionary:
    # Отладка не должна объявлять отсутствующие модели готовыми.
    return {"installed": available_models(), "catalog": MODELS.size(),
        "visible": active_count(), "limit": MAX_VISIBLE}
