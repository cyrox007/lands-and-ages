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
const FLEE_SPEED := 2.40
const CHASE_SPEED := 1.80
const HUNT_SCARE_RADIUS := 10.0
const HAZARD_RADIUS := 12.0
const DANGERS := [
    "шторм", "шквал", "ураган", "смерч",
    "паводок", "пожар", "лавина", "сель", "оползень",
    "землетрясение", "обвал"
]
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
var _last_hunt_day := -1


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
    _last_hunt_day = -1


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


func _flee_target(movement: Dictionary, danger: Vector2i) -> Vector2i:
    # Физическая опасность задаёт направление, но зверь может
    # убежать только по реальной проходимой суше своего ареала.
    var cell: Vector2i = movement["cell"]
    var home: Vector2i = movement["home"]
    var region: Vector2i = world.config.region_of(home)
    var best := cell
    var distance := Vector2(cell - danger).length_squared()
    for direction in WALK_DIRECTIONS:
        var candidate: Vector2i = cell + direction
        if world.config.region_of(candidate) != region \
                or Vector2(candidate - home).length_squared() \
                    > MAX_WANDER_CELLS * MAX_WANDER_CELLS:
            continue
        if not Paths.walkable(world, hydro, surface, candidate):
            continue
        var candidate_distance := Vector2(candidate - danger).length_squared()
        if candidate_distance > distance:
            distance = candidate_distance
            best = candidate
    return best


func _chase_step(movement: Dictionary, prey_cell: Vector2i) -> Vector2i:
    # Визуальное сближение после подтверждённой охоты —
    # максимум одна соседняя клетка, без поиска несуществующей
    # позиции убитой особи. До живой добычи не доходим вплотную.
    var cell: Vector2i = movement["cell"]
    var home: Vector2i = movement["home"]
    var region: Vector2i = world.config.region_of(home)
    var nearest: float = Vector2(cell - prey_cell).length_squared()
    var best := cell
    for direction in WALK_DIRECTIONS:
        var candidate: Vector2i = cell + direction
        if candidate == prey_cell or world.config.region_of(candidate) != region \
                or Vector2(candidate - home).length_squared() \
                    > MAX_WANDER_CELLS * MAX_WANDER_CELLS:
            continue
        if not Paths.walkable(world, hydro, surface, candidate):
            continue
        var distance: float = Vector2(candidate - prey_cell).length_squared()
        if distance < nearest:
            nearest = distance
            best = candidate
    return best


func _chase_target_valid(key: String, movement: Dictionary) -> bool:
    # Событие охоты относится к прошедшим физическим суткам.
    # Перед показом удара проверяем: видимые участники и живые
    # стада ещё существуют, а календарь не сменил контекст.
    if world == null or wildlife == null or predators == null \
            or not _visible.has(key) or not _movement.has(key):
        return false
    var prey_key := str(movement.get("chase_prey", ""))
    if prey_key.is_empty() or not _visible.has(prey_key) \
            or not _movement.has(prey_key):
        return false
    if int(movement.get("chase_day", -1)) != predators.last_day \
            or predators.last_day != wildlife.last_day:
        return false
    var hunter_cell: Vector2i = movement["cell"]
    var prey_cell: Vector2i = _movement[prey_key]["cell"]
    var region: Vector2i = world.config.region_of(hunter_cell)
    if world.config.region_of(prey_cell) != region \
            or Vector2(hunter_cell - prey_cell).length_squared() \
                > HUNT_SCARE_RADIUS * HUNT_SCARE_RADIUS:
        return false
    var hunter := _visible[key] as Node3D
    var prey_actor := _visible[prey_key] as Node3D
    # Проверка реестров не изменяет добычу, численность или
    # маршруты. Удалённую стаю нельзя заменить картинкой.
    return predators.count_at(region, str(hunter.get("species"))) > 0 \
        and wildlife.population_at(region, str(prey_actor.get("species"))) > 0


func _start_flee(key: String, danger: Vector2i) -> bool:
    # Природное бедствие и реальная охота используют одну
    # физическую проверку соседней суши и одного скелетного актёра.
    if not _visible.has(key) or not _movement.has(key):
        return false
    var movement: Dictionary = _movement[key]
    if bool(movement.get("flee", false)):
        return false
    var cell: Vector2i = movement["cell"]
    var next: Vector2i = _flee_target(movement, danger)
    if next == cell:
        return false
    var actor := _visible[key] as Node3D
    var flat := Vector2(float(next.x) + 0.5, float(next.y) + 0.5)
    var target: Vector3 = world.config.to_scene(flat, world.height_at(flat))
    var direction := target - actor.position
    actor.rotation.y = atan2(-direction.x, -direction.z)
    movement["target"] = target
    movement["next"] = next
    movement["walking"] = true
    movement["flee"] = true
    # Бегство от реальной угрозы прекращает жест атаки,
    # но не меняет численность и не создаёт новых особей.
    movement["attack"] = 0.0
    movement["chase"] = false
    movement["chase_prey"] = ""
    movement["chase_day"] = -1
    movement["rest"] = 0.0
    actor.set_motion("бег")
    return true


func react_hazards(hazards: Array) -> int:
    # Получаем только завершённые события WorldDayRunner, уже
    # применённые к живым стадам. Здесь нет вызова consume_prey,
    # рождения животных или самостоятельной симуляции бедствий.
    if world == null or wildlife == null or predators == null:
        return 0
    var reacted := 0
    for hazard in hazards:
        if not (hazard is Dictionary) \
                or not (hazard.get("cell") is Vector2i):
            continue
        if str(hazard.get("kind", "")) not in DANGERS:
            continue
        var strength: float = float(hazard.get("severity", 0.0))
        var danger: Vector2i = hazard["cell"]
        if not is_finite(strength) or strength < 0.50 \
                or not world.config.contains_cell(danger):
            continue
        for key in _visible:
            var movement: Dictionary = _movement.get(key, {})
            if movement.is_empty() or bool(movement.get("flee", false)):
                continue
            var actor := _visible[key] as Node3D
            var cell: Vector2i = movement["cell"]
            if Vector2(cell - danger).length_squared() \
                    > HAZARD_RADIUS * HAZARD_RADIUS:
                continue
            # Если физическая особь уже погибла или переселилась,
            # её старую графическую копию не заставляем убегать.
            if _population(world.config.region_of(cell),
                    str(actor.get("species"))) <= 0:
                continue
            if _start_flee(str(key), danger):
                reacted += 1
    return reacted


func react_hunts() -> int:
    # Только завершённые физические поедания FoodWeb могут
    # вызвать жест атаки. Ни добычу, ни само преследование
    # графика не создаёт; далёкие хищники не получают Node3D.
    if world == null or wildlife == null or predators == null:
        return 0
    if predators.last_day != wildlife.last_day \
            or predators.last_day <= _last_hunt_day:
        return 0
    _last_hunt_day = predators.last_day
    var reacted := 0
    for hunt in predators.last_hunts:
        if not (hunt is Dictionary) \
                or not (hunt.get("region") is Vector2i) \
                or int(hunt.get("count", 0)) <= 0:
            continue
        var region: Vector2i = hunt["region"]
        var kind := str(hunt.get("predator", ""))
        var key := "%s:%d:%d" % [kind, region.x, region.y]
        # Стаю могли уничтожить или камера уже ушла: показывать
        # удар несуществующего хищника в таком случае нельзя.
        if not _visible.has(key) or not _movement.has(key) \
                or predators.count_at(region, kind) <= 0:
            continue
        var movement: Dictionary = _movement[key]
        if bool(movement.get("walking", false)) \
                or bool(movement.get("flee", false)) \
                or float(movement.get("attack", 0.0)) > 0.0:
            continue
        var actor := _visible[key] as Node3D
        if not actor.has_attack_animation():
            continue
        if actor.attack_duration() <= 0.0:
            continue
        # Пространственный ориентир — только уже видимый живой
        # представитель группы, не координата съеденной особи.
        # Никаких телепортаций, новых убийств и фиктивных трупов.
        var prey_kind := str(hunt.get("prey", ""))
        var prey_key := "%s:%d:%d" % [prey_kind, region.x, region.y]
        var prey_cell := Vector2i(-1, -1)
        var hunter_cell: Vector2i = movement["cell"]
        if _visible.has(prey_key) and _movement.has(prey_key) \
                and wildlife.population_at(region, prey_kind) > 0:
            var visible_cell: Vector2i = _movement[prey_key]["cell"]
            if Vector2(visible_cell - hunter_cell).length_squared() \
                    <= HUNT_SCARE_RADIUS * HUNT_SCARE_RADIUS:
                prey_cell = visible_cell
                # Представитель уцелевшего стада реагирует на
                # угрозу независимо от будущего шага хищника.
                _start_flee(prey_key, hunter_cell)
        # Один физически проходимый шаг визуальной погони
        # заканчивается атакой, если не прерван настоящим бедствием.
        var next := _chase_step(movement, prey_cell) \
            if prey_cell.x >= 0 else hunter_cell
        if next != hunter_cell:
            var flat := Vector2(next) + Vector2(0.5, 0.5)
            var destination: Vector3 = world.config.to_scene(
                flat, world.height_at(flat))
            var direction: Vector3 = destination - actor.position
            actor.rotation.y = atan2(-direction.x, -direction.z)
            movement["target"] = destination
            movement["next"] = next
            movement["walking"] = true
            movement["chase"] = true
            movement["chase_prey"] = prey_key
            movement["chase_day"] = predators.last_day
            movement["rest"] = 0.0
            actor.set_motion("бег")
        else:
            # Нет безопасного пути или видимой добычи — поведение
            # предыдущего этапа остаётся работоспособным.
            movement["attack"] = actor.attack_duration()
            actor.set_motion("атака")
        reacted += 1
    return reacted


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
        # Короткая скелетная атака не сдвигает животное с клетки.
        # После проигрывания возвращаем штатные отдых и прогулку.
        if float(movement.get("attack", 0.0)) > 0.0:
            movement["attack"] = maxf(0.0,
                float(movement["attack"]) - frame_time)
            if float(movement["attack"]) <= 0.0:
                actor.set_motion("покой")
                movement["rest"] = 1.4
            continue
        if bool(movement["walking"]):
            var destination: Vector3 = movement["target"]
            # Убегает быстрее обычной прогулки, но каждый кадр
            # проходит только допустимое расстояние по суше.
            var speed := FLEE_SPEED if bool(movement.get("flee", false)) \
                else CHASE_SPEED if bool(movement.get("chase", false)) \
                else LOCAL_WALK_SPEED
            actor.position = actor.position.move_toward(
                destination, frame_time * speed)
            if actor.position.distance_to(destination) < 0.0001:
                # move_toward сам доводит актёра до цели. Второй
                # принудительный скачок меша нарушал лимит пути
                # за кадр и выглядел бы как микротелепортация.
                movement["cell"] = movement["next"]
                movement["walking"] = false
                movement["flee"] = false
                if bool(movement.get("chase", false)):
                    # Не обрываем шаг посередине клетки, но и не
                    # показываем удар по исчезнувшей добыче.
                    var can_attack := _chase_target_valid(str(key), movement)
                    movement["chase"] = false
                    movement["chase_prey"] = ""
                    movement["chase_day"] = -1
                    if can_attack:
                        movement["attack"] = actor.attack_duration()
                        actor.set_motion("атака")
                    else:
                        movement["rest"] = 1.4
                        actor.set_motion("покой")
                else:
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
            "rest": 1.5, "walking": false, "flee": false,
            "attack": 0.0, "chase": false,
            "chase_prey": "", "chase_day": -1
        }


func active_count() -> int:
    # Для мобильного бюджета отслеживаем только настоящие
    # скелетные узлы, создаваемые текущим видимым участком.
    return _visible.size()


func stats() -> Dictionary:
    # Отладка не должна объявлять отсутствующие модели готовыми.
    return {"installed": available_models(), "catalog": MODELS.size(),
        "visible": active_count(), "limit": MAX_VISIBLE}
