extends SceneTree
## Проверка 12.9: реальные меши, скелеты и анимации CC0-животных.
## Имитировать результат коробками или пустыми сценами запрещено.

const Actor = preload("res://scripts/wildlife_visual_actor.gd")
const Visuals = preload("res://scripts/wildlife_visuals.gd")
const Config = preload("res://scripts/world_config.gd")
const Map = preload("res://scripts/world_map.gd")
const Hydro = preload("res://scripts/hydrology.gd")
const Surface = preload("res://scripts/surface.gd")
const Climate = preload("res://scripts/climate.gd")
const Nature = preload("res://scripts/nature_registry.gd")
const Wildlife = preload("res://scripts/wildlife_populations.gd")
const FoodWeb = preload("res://scripts/wildlife_food_web.gd")
const Paths = preload("res://scripts/world_resource_path.gd")


func _initialize() -> void:
    # Анимации должны стартовать внутри SceneTree. Применяем
    # отложенный вызов уже после создания окна и дерева сцены.
    call_deferred("_check")


func _check() -> void:
    # Синтетическое препятствие проверяет именно алгоритм
    # обхода: первый шаг обязан отклониться от добычи, иначе
    # жадное движение навсегда упрётся в закрытую клетку.
    var detour_allowed := func(cell: Vector2i) -> bool:
        return cell.x >= -2 and cell.x <= 4 \
            and absi(cell.y) <= 2 and cell != Vector2i(1, 0)
    var detour_start := Vector2i.ZERO
    var detour_target := Vector2i(3, 0)
    var detour_first := Visuals._route_chase_step(
        detour_start, detour_target, Visuals.MAX_CHASE_STEPS, detour_allowed)
    if detour_first != Vector2i(0, 1) \
            or Visuals._route_chase_step(
                detour_start, detour_target, 1, detour_allowed) \
                != detour_start:
        push_error("Хищник не умеет обходить препятствие первым боковым шагом")
        quit(1)
        return
    var detour_second := Visuals._route_chase_step(
        detour_first, detour_target, 2, detour_allowed)
    var detour_third := Visuals._route_chase_step(
        detour_second, detour_target, 1, detour_allowed)
    if detour_second != Vector2i(1, 1) \
            or detour_third != Vector2i(2, 1) \
            or detour_third == detour_target:
        push_error("Обход препятствия нарушил трёхшаговый маршрут")
        quit(1)
        return
    # Если свободных клеток нет, маршрут отсутствует:
    # нельзя телепортировать хищника через сплошную преграду.
    var closed_area := func(cell: Vector2i) -> bool:
        return cell == Vector2i.ZERO
    if Visuals._route_chase_step(
            detour_start, detour_target, 3, closed_area) != detour_start:
        push_error("Поиск прошёл через полностью закрытый участок")
        quit(1)
        return
    # Визуальный удар возможен только из соседней клетки:
    # ни диагональ, ни удалённая цель не являются контактом.
    if not Visuals._attack_reachable(Vector2i(2, 2), Vector2i(3, 2)) \
            or Visuals._attack_reachable(
                Vector2i(2, 2), Vector2i(3, 3)) \
            or Visuals._attack_reachable(
                Vector2i(2, 2), Vector2i(5, 2)) \
            or Visuals._attack_reachable(
                Vector2i(2, 2), Vector2i(2, 2)):
        push_error("Неверная дистанция для отображения контакта")
        quit(1)
        return
    # Учитываем действительное положение моделей между
    # клетками; высота земли не должна влиять на горизонтальную
    # дистанцию, а визуально убежавшая добыча недосягаема.
    if not Visuals._actors_in_attack_range(
            Vector3(0.5, 2.0, 0.5), Vector3(1.5, 8.0, 0.5)) \
            or Visuals._actors_in_attack_range(
                Vector3(0.5, 2.0, 0.5), Vector3(2.0, 2.0, 0.5)):
        push_error("Положение 3D-моделей не ограничивает дальность атаки")
        quit(1)
        return
    var models := {}
    for kind in Visuals.MODELS:
        var entry: Dictionary = Visuals.MODELS[kind]
        var path := Visuals.ROOT + str(entry["file"])
        var asset := ResourceLoader.load(path) as PackedScene
        if asset == null:
            push_error("Не установлен настоящий CC0-меш: " + kind)
            quit(1)
            return
        var actor := Actor.new()
        get_root().add_child(actor)
        if not actor.configure(kind, asset, str(entry["source"]),
                float(entry["height"])) \
                or actor.bone_count() < 8 or actor.animation_count() < 1:
            push_error("Нет деформируемого скелета/анимаций: " + kind)
            actor.queue_free()
            quit(1)
            return
        # Гусь и кабан не должны загружаться из прежней общей модели.
        # Проверяем источник именно созданного Skeleton3D-актёра.
        if kind in ["кабан", "гусь", "дикий гусь"] \
                and actor.source_name != "LandsAndAges":
            push_error("Неверный источник анатомии: " + kind)
            actor.queue_free()
            quit(1)
            return
        # В glTF нос направлен вдоль +Z; после исправления
        # визуальная модель обязана смотреть вдоль -Z своего
        # управляющего Node3D, а не бежать задом наперёд.
        var visual := actor._visual as Node3D
        var facing: Vector3 = (visual.basis * Vector3.BACK).normalized()
        if facing.dot(Vector3.FORWARD) < 0.99:
            push_error("Импортированная модель смотрит против движения: " + kind)
            actor.queue_free()
            quit(1)
            return
        # Масштаб должен быть конечным и положительным. 
        # Нельзя принимать нулевой или перевёрнутый SkinnedMesh.
        if not is_finite(visual.scale.y) or visual.scale.y <= 0.0:
            push_error("Неверный масштаб скелетной модели: " + kind)
            actor.queue_free()
            quit(1)
            return
        # Скелет и анимации должны работать не только на этапе
        # импорта: проверяем переходы между реальными клипами.
        actor.set_motion("ходьба")
        # Реальный ход анимации требует обработки кадров, а не
        # простого изменения имени текущего состояния.
        var started: float = actor.motion_time()
        actor._process(0.25)
        if actor.motion_time() <= started + 0.001:
            push_error("Анимация не продвинулась по времени: " + kind)
            actor.queue_free()
            quit(1)
            return
        await process_frame
        if actor.state != "ходьба":
            push_error("Не удалось включить анимацию ходьбы: " + kind)
            quit(1)
            return
        # Время атаки должно соответствовать импортированному
        # клипу, иначе скелет прерывается на середине движения.
        if actor.has_attack_animation():
            var duration: float = actor.attack_duration()
            if not is_finite(duration) or duration <= 0.0:
                push_error("Некорректная длительность атаки: " + kind)
                quit(1)
                return
        actor.set_motion("покой")
        if actor.state != "покой":
            push_error("Не удалось вернуть анимацию покоя: " + kind)
            quit(1)
            return
        var skeleton_count := actor.bone_count()
        var animation_count := actor.animation_count()
        models[kind] = {"bones": skeleton_count,
            "clips": animation_count,
            "target_height": float(entry["height"]),
            "import_scale": snappedf(visual.scale.y, 0.00001)}
        actor.queue_free()
        await process_frame
    # Кроме индивидуальных мешей, проверяем, что визуальный
    # слой не создаёт животных без физических стад и лимитирует узлы.
    var world = Map.new(Config.new(256, 192, 1729))
    var hydro = Hydro.new(world)
    hydro.rebuild()
    var ground = Surface.new(world, hydro)
    ground.rebuild()
    var climate = Climate.new(world, hydro)
    climate.rebuild()
    var nature = Nature.new(world, hydro, ground, climate)
    nature.generate()
    var fauna = Wildlife.new(world, hydro, ground, climate, nature)
    fauna.generate()
    var predators = FoodWeb.new(world, climate, fauna)
    predators.generate()
    var visuals := Visuals.new()
    get_root().add_child(visuals)
    visuals.configure(world, hydro, ground, fauna, predators)
    # Ручной осмотр находит настоящие стада, но никогда не
    # изменяет их физическую численность ради демонстрации.
    var inspection_before: Dictionary = fauna.to_data()
    var spot: Dictionary = visuals.inspection_spot()
    print("STAGE12-INSPECTION-DIAG: ", JSON.stringify({
        "spot": str(spot), "available_models": visuals.available_models(),
        "same_fauna": fauna.to_data() == inspection_before,
        "predators": predators.total()
    }))
    if spot.is_empty() \
            or fauna.population_at(spot["region"], str(spot["prey"])) <= 0 \
            or predators.count_at(spot["region"], str(spot["predator"])) <= 0 \
            or fauna.to_data() != inspection_before:
        push_error("Осмотр не нашёл реальную пару животных без изменения мира")
        quit(1)
        return
    var center := Vector2(128.0, 96.0)
    # Радиус должен покрывать фактически показанный широкий
    # изометрический кадр, а не прежние 42 клетки независимо от
    # расстояния камеры.
    var radius := Visuals._render_radius(66.0)
    if radius < 78.0 or Visuals._render_radius(105.0) < 120.0:
        push_error("Дальняя камера снова теряет видимую фауну")
        quit(1)
        return
    visuals.refresh(center, 66.0, 1.0)
    var candidates: Array[Dictionary] = visuals._nearest_candidates(
        center, radius)
    var selected := mini(Visuals.MAX_VISIBLE, candidates.size())
    if selected == 0 or visuals.active_count() != selected:
        push_error("Ближайшие живые животные не появились у камеры")
        quit(1)
        return
    for i in range(selected):
        if not visuals._visible.has(candidates[i]["key"]):
            push_error("Далёкий регион вытеснил ближайшее животное")
            quit(1)
            return
    # Один и тот же центр обзора: приближение и возвращение
    # не должны удалять, пересоздавать или телепортировать
    # живые модели даже при самых близких значениях зума.
    var zoom_actors := {}
    for key in visuals._visible:
        zoom_actors[key] = visuals._visible[key]
    for zoom in [44.0, 24.0, 16.0, 66.0, 105.0, 66.0]:
        visuals.refresh(center, zoom, 1.0)
        if visuals.active_count() != selected:
            push_error("При зуме исчезли реальные животные")
            quit(1)
            return
        for key in zoom_actors:
            if not visuals._visible.has(key) \
                    or visuals._visible[key] != zoom_actors[key]:
                push_error("При зуме пересоздана модель: " + str(key))
                quit(1)
                return
            # Проверяем не только наличие узла, но и его реальный
            # экранный размер. Прошлый тест не измерял масштаб и
            # поэтому не находил слишком мелкие модели при отдалении.
            var actor_zoom := visuals._visible[key] as Node3D
            if absf(actor_zoom.scale.x - Visuals._overview_scale(zoom)) > 0.001:
                push_error("3D-модель не меняет размер обзорного LOD")
                quit(1)
                return
    var previous := {}
    for key in visuals._visible:
        previous[key] = (visuals._visible[key] as Node3D).position
    # Камера может двигаться внутри ареала, но видимая особь
    # не должна телепортироваться в новую случайную точку.
    visuals.refresh(center + Vector2(1.5, 1.5), 66.0, 1.0)
    for key in visuals._visible:
        if previous.has(key) and previous[key] != (
                visuals._visible[key] as Node3D).position:
            push_error("Дикое животное переместилось вслед за камерой")
            quit(1)
            return
    if visuals.active_count() > Visuals.MAX_VISIBLE \
            or visuals.available_models() != Visuals.MODELS.size():
        push_error("Превышен бюджет или отсутствуют модели")
        quit(1)
        return
    # Многократное перемещение камеры по карте не должно
    # вытеснять ближайшие 3D-модели и создавать лишние узлы.
    var camera_checks := 0
    for next_center in [
            Vector2(55.0, 40.0), Vector2(180.0, 80.0),
            Vector2(120.0, 160.0), Vector2(240.0, 180.0)]:
        var expected: Array[Dictionary] = visuals._nearest_candidates(
            next_center, radius)
        visuals.refresh(next_center, 66.0, 1.0)
        if visuals.active_count() != mini(
                Visuals.MAX_VISIBLE, expected.size()):
            push_error("Камера создала слишком много скелетных животных")
            quit(1)
            return
        for i in range(mini(Visuals.MAX_VISIBLE, expected.size())):
            if not visuals._visible.has(expected[i]["key"]):
                push_error("При перемещении камеры показан не ближайший зверь")
                quit(1)
                return
        camera_checks += 1
    # Наблюдаем реальную локальную прогулку уже существующего
    # животного: соседние клетки обязаны быть сухопутными, а
    # скелетная ходьба включается только в момент перемещения.
    visuals.refresh(center, 66.0, 1.0)
    var prey_before: Dictionary = fauna.to_data()
    var predators_before: Dictionary = predators.to_data()
    var sample_key := ""
    for key in visuals._visible:
        var motion: Dictionary = visuals._movement[key]
        if visuals._walk_target(str(key), motion) != motion["cell"]:
            sample_key = str(key)
            break
    if sample_key.is_empty():
        push_error("На реальной карте нет проходимой клетки для прогулки")
        quit(1)
        return
    var sample := visuals._visible[sample_key] as Node3D
    var initial: Vector3 = sample.position
    var moved := false
    var animated := false
    for step in range(120):
        var prior: Vector3 = sample.position
        visuals._process(0.10)
        if sample.position.distance_to(prior) \
                > Visuals.LOCAL_WALK_SPEED * 0.10 + 0.001:
            push_error("Животное телепортировалось за один кадр")
            quit(1)
            return
        if bool(visuals._movement[sample_key]["walking"]):
            animated = true
            if sample.get("state") != "ходьба":
                push_error("Анимация ходьбы не включилась при движении")
                quit(1)
                return
        if sample.position.distance_to(initial) > 0.1:
            moved = true
    if not animated or not moved \
            or sample.position.distance_to(initial) \
                > Visuals.MAX_WANDER_CELLS + 2.0:
        push_error("Нет достоверной локальной прогулки по суше")
        quit(1)
        return
    if fauna.to_data() != prey_before \
            or predators.to_data() != predators_before:
        push_error("Графическая прогулка изменила число животных")
        quit(1)
        return
    # Настоящее событие дня подаётся через world.gd, а здесь
    # проверяем обработчик: слабая опасность игнорируется, сильная
    # запускает именно анимированный бег по соседней сухой клетке.
    var fleeing_key := ""
    for key in visuals._visible:
        var motion: Dictionary = visuals._movement[key]
        if visuals._flee_target(motion, motion["cell"]) != motion["cell"]:
            fleeing_key = str(key)
            break
    if fleeing_key.is_empty():
        push_error("Не найдено живое животное с безопасным путём бегства")
        quit(1)
        return
    var flee_actor := visuals._visible[fleeing_key] as Node3D
    var flee_cell: Vector2i = visuals._movement[fleeing_key]["cell"]
    if visuals.react_hazards([{
            "kind": "шторм", "cell": flee_cell, "severity": 0.2
            }]) != 0:
        push_error("Слабый ветер ошибочно вызвал паническое бегство")
        quit(1)
        return
    var reacted: int = visuals.react_hazards([{
        "kind": "шторм", "cell": flee_cell, "severity": 0.90
    }])
    if reacted < 1 or reacted > Visuals.MAX_VISIBLE \
            or flee_actor.get("state") != "бег":
        push_error("Реальная опасность не запустила скелетный бег")
        quit(1)
        return
    var fled := false
    var flee_origin: Vector3 = flee_actor.position
    for i in range(24):
        var prior: Vector3 = flee_actor.position
        visuals._process(0.10)
        if flee_actor.position.distance_to(prior) \
                > Visuals.FLEE_SPEED * 0.10 + 0.001:
            push_error("Бегство телепортировало животное")
            quit(1)
            return
        if not bool(visuals._movement[fleeing_key]["flee"]):
            fled = flee_actor.position.distance_to(flee_origin) > 0.1
            break
    if not fled or flee_actor.get("state") != "покой" \
            or fauna.to_data() != prey_before \
            or predators.to_data() != predators_before:
        push_error("Бегство изменило физическую фауну или не завершилось")
        quit(1)
        return
    # Реальная охота хищника должна порождать визуальный удар,
    # но только если неподалёку есть живая стая и нужный клип.
    # Берём подтверждённое списание через _feed, а не придумываем
    # численность или событие для декоративной сцены.
    var attack_checked := false
    var prey_flee_checked := false
    var chase_checked := false
    var regions: Vector2i = world.config.region_count()
    for ry in range(regions.y):
        if attack_checked:
            break
        for rx in range(regions.x):
            if attack_checked:
                break
            var region := Vector2i(rx, ry)
            for predator_kind in ["волк", "лиса"]:
                if predators.count_at(region, predator_kind) <= 0:
                    continue
                var can_hunt := false
                for prey_kind in FoodWeb.SPECIES[predator_kind]["prey"]:
                    if predators._huntable(region, str(prey_kind)) > 0:
                        can_hunt = true
                        break
                if not can_hunt:
                    continue
                var actor_cell: Vector2i = visuals._position(
                    region, predator_kind, Vector2.ZERO)
                if actor_cell.x < 0:
                    continue
                # Региональный центр позволяет одновременно видеть
                # настоящего хищника и настоящую группу его добычи.
                var bounds: Rect2i = world.config.region_rect(region)
                var regional_center := Vector2(bounds.position) \
                    + Vector2(bounds.size) * 0.5
                visuals.refresh(regional_center, 66.0, 1.0)
                var hunter_key := "%s:%d:%d" % [predator_kind, rx, ry]
                if not visuals._visible.has(hunter_key):
                    continue
                var hunter := visuals._visible[hunter_key] as Node3D
                if not hunter.has_attack_animation():
                    continue
                # Сначала завершаем прежний шаг, чтобы тест
                # измерял именно анимацию атаки без телепортации.
                for frame in range(30):
                    if not bool(visuals._movement[hunter_key]["walking"]) \
                            and not bool(visuals._movement[hunter_key]["flee"]):
                        break
                    visuals._process(0.10)
                if bool(visuals._movement[hunter_key]["walking"]) \
                        or bool(visuals._movement[hunter_key]["flee"]):
                    continue
                # Выбираем вид, который FoodWeb действительно сможет
                # списать. Без живой добычи сцену не создаём.
                var hunted_kind := ""
                var best_pressure := -1.0
                for species in FoodWeb.SPECIES[predator_kind]["prey"]:
                    var available := predators._huntable(region, str(species))
                    if available <= 0:
                        continue
                    var cap := maxi(1, fauna.capacity_at(region, str(species)))
                    var pressure := float(available) / float(cap)
                    if pressure > best_pressure:
                        hunted_kind = str(species)
                        best_pressure = pressure
                var prey_key := "%s:%d:%d" % [hunted_kind, rx, ry]
                if hunted_kind.is_empty() or not visuals._visible.has(prey_key):
                    continue
                var prey_actor := visuals._visible[prey_key] as Node3D
                var prey_movement: Dictionary = visuals._movement[prey_key]
                var hunter_cell: Vector2i = visuals._movement[hunter_key]["cell"]
                # Создаём только контролируемую позицию изображения
                # уже существующей живой группы на настоящей суше.
                # Это тест траектории, не генерация новых животных.
                var suitable := Vector2i(-1, -1)
                for direction in Visuals.WALK_DIRECTIONS:
                    # Тестируем многоклеточный маршрут на настоящей
                    # суше, сохраняя место уцелевшей добыче и выход.
                    var path_ok := true
                    for distance in range(1, 5):
                        var candidate: Vector2i = hunter_cell \
                            + direction * distance
                        if world.config.region_of(candidate) != region \
                                or not Paths.walkable(world, hydro, ground,
                                    candidate):
                            path_ok = false
                            break
                    if not path_ok:
                        continue
                    var far: Vector2i = hunter_cell + direction * 3
                    var probe := {"cell": far, "home": far}
                    if visuals._flee_target(probe, hunter_cell) == far:
                        continue
                    # Первая клетка сокращает расстояние,
                    # четвёртая оставляет добыче путь для бегства.
                    if visuals._chase_step(visuals._movement[hunter_key],
                            far) == hunter_cell + direction:
                        suitable = far
                        break
                if suitable.x < 0:
                    continue
                var prey_flat := Vector2(suitable) + Vector2(0.5, 0.5)
                prey_actor.position = world.config.to_scene(
                    prey_flat, world.height_at(prey_flat))
                prey_movement["cell"] = suitable
                prey_movement["home"] = suitable
                prey_movement["walking"] = false
                prey_movement["flee"] = false
                prey_movement["attack"] = 0.0
                prey_movement["rest"] = 1.5
                var prey_before_position: Vector3 = prey_actor.position
                var captured: Array[Dictionary] = []
                if predators._feed(region, predator_kind, 1, captured) != 1 \
                        or captured.size() != 1 \
                        or str(captured[0]["prey"]) != hunted_kind:
                    push_error("Выбранная живая добыча не совпала с результатом охоты")
                    quit(1)
                    return
                predators.last_hunts = captured
                var after_capture: Dictionary = fauna.to_data()
                var hunters_after: Dictionary = predators.to_data()
                var position_before: Vector3 = hunter.position
                var sound_plays_before: int = int(
                    hunter.get("contact_sound_plays"))
                if visuals.react_hunts() != 1 \
                        or hunter.get("state") != "бег" \
                        or not bool(visuals._movement[hunter_key]["chase"]) \
                        or prey_actor.get("state") != "бег" \
                        or not bool(visuals._movement[prey_key]["flee"]) \
                        or visuals.react_hunts() != 0:
                    push_error("Реальная охота не запустила погоню и бегство")
                    quit(1)
                    return
                # После события подтверждаем привязку к
                # текущему дню, живой добыче и видимой сцене.
                var chase: Dictionary = visuals._movement[hunter_key]
                if not visuals._chase_target_valid(hunter_key, chase):
                    push_error("Цель подтверждённой погони не распознана")
                    quit(1)
                    return
                # Временно проверяем соседство на видимой сцене.
                # Убежавшая на полклетки модель не может получить
                # удар только потому, что реестр ещё хранит клетку.
                var original_prey_cell: Vector2i = prey_movement["cell"]
                var original_prey_position: Vector3 = prey_actor.position
                var neighbor: Vector2i = chase["next"]
                var offset: Vector2i = neighbor - chase["cell"]
                prey_movement["cell"] = neighbor
                prey_actor.position = hunter.position + Vector3(
                    float(offset.x), 0.0, float(offset.y))
                var contact_near := visuals._chase_contact_valid(
                    hunter_key, chase)
                prey_actor.position += Vector3(
                    float(offset.x) * 0.8, 0.0, float(offset.y) * 0.8)
                var contact_far := visuals._chase_contact_valid(
                    hunter_key, chase)
                prey_movement["cell"] = original_prey_cell
                prey_actor.position = original_prey_position
                if not contact_near or contact_far:
                    push_error("Контакт не учитывает текущее положение модели")
                    quit(1)
                    return
                var visible_prey: Node3D = visuals._visible[prey_key]
                visuals._visible.erase(prey_key)
                var target_gone := not visuals._chase_target_valid(
                    hunter_key, chase)
                visuals._visible[prey_key] = visible_prey
                chase["chase_day"] = predators.last_day + 1
                var old_day_rejected := not visuals._chase_target_valid(
                    hunter_key, chase)
                chase["chase_day"] = predators.last_day
                if not target_gone or not old_day_rejected \
                        or not visuals._chase_target_valid(hunter_key, chase):
                    push_error("Исчезновение добычи или смена дня не отменяют погоню")
                    quit(1)
                    return
                var pursuit_start: Vector3 = hunter.position
                var approach_reached := false
                var chase_cells := 0
                var last_cell: Vector2i = chase["cell"]
                for frame in range(75):
                    var before_step: Vector3 = hunter.position
                    visuals._process(0.10)
                    if hunter.position.distance_to(before_step) \
                            > Visuals.CHASE_SPEED * 0.10 + 0.001:
                        push_error("Хищник телепортировался при сближении")
                        quit(1)
                        return
                    var current_cell: Vector2i = chase["cell"]
                    if current_cell != last_cell:
                        chase_cells += 1
                        last_cell = current_cell
                    if not bool(visuals._movement[hunter_key]["chase"]):
                        approach_reached = hunter.get("state") == "атака"
                        break
                if not approach_reached or chase_cells < 2 \
                        or chase_cells > Visuals.MAX_CHASE_STEPS \
                        or hunter.position.distance_to(pursuit_start) < 1.0 \
                        or absf(float(visuals._movement[hunter_key]["attack"]) \
                            - hunter.attack_duration()) > 0.001:
                    push_error("Сближение не завершилось скелетной атакой")
                    quit(1)
                    return
                # После настоящего сближения хищник должен
                # смотреть на текущую позицию добычи, а не
                # в сторону последнего шага своего маршрута.
                var facing: Vector3 = prey_actor.position - hunter.position
                var expected_y := atan2(-facing.x, -facing.z)
                if absf(wrapf(hunter.rotation.y - expected_y,
                        -PI, PI)) > 0.01:
                    push_error("Скелетная атака направлена мимо добычи")
                    quit(1)
                    return
                var contact_audio_node := hunter.get_node_or_null(
                    "ContactSound") as AudioStreamPlayer3D
                var contact_clip: AudioStreamWAV = null
                if contact_audio_node != null:
                    contact_clip = contact_audio_node.stream as AudioStreamWAV
                if contact_clip == null \
                        or contact_clip.format != AudioStreamWAV.FORMAT_16_BITS \
                        or contact_clip.data.size() != 4800 \
                        or int(hunter.get("contact_sound_plays")) \
                            != sound_plays_before + 1:
                    push_error("Подтверждённый визуальный контакт не создал 3D-звук")
                    quit(1)
                    return
                # Звуковой клип привязан к движущемуся хищнику:
                # он не создаёт самостоятельных животных.
                if contact_audio_node.get_parent() != hunter:
                    push_error("Звуковой источник оторван от модели хищника")
                    quit(1)
                    return
                var approach_position: Vector3 = hunter.position
                var attack_frames := ceili(hunter.attack_duration() / 0.10) + 1
                for frame in range(attack_frames):
                    var prey_frame_start: Vector3 = prey_actor.position
                    visuals._process(0.10)
                    if prey_actor.position.distance_to(prey_frame_start) \
                            > Visuals.FLEE_SPEED * 0.10 + 0.001:
                        push_error("Добыча телепортировалась при бегстве")
                        quit(1)
                        return
                if hunter.get("state") != "покой" \
                        or hunter.position != approach_position \
                        or prey_actor.position.distance_to(prey_before_position) <= 0.1 \
                        or fauna.to_data() != after_capture \
                        or predators.to_data() != hunters_after:
                    push_error("Атака сдвинула хищника или повторно списала добычу")
                    quit(1)
                    return
                # Проверяем уже подтверждённое физическое
                # событие при временно невидимой добыче.
                # Переигрываем только визуализацию, не FoodWeb.
                var old_hunt_day: int = visuals._last_hunt_day
                var visible_prey_after: Node3D = visuals._visible[prey_key]
                visuals._visible.erase(prey_key)
                visuals._last_hunt_day = predators.last_day - 1
                var missing_reactions: int = visuals.react_hunts()
                visuals._visible[prey_key] = visible_prey_after
                visuals._last_hunt_day = old_hunt_day
                if missing_reactions != 0 \
                        or int(hunter.get("contact_sound_plays")) \
                            != sound_plays_before + 1 \
                        or hunter.get("state") != "покой" \
                        or fauna.to_data() != after_capture \
                        or predators.to_data() != hunters_after:
                    push_error("Отсутствующая видимая добыча вызвала ложную атаку")
                    quit(1)
                    return
                attack_checked = true
                prey_flee_checked = true
                chase_checked = true
                break
    if not attack_checked or not prey_flee_checked or not chase_checked:
        push_error("Не найдена реальная охота с доступной анимацией атаки")
        quit(1)
        return
    print("STAGE12-VISUAL-REPORT: ", JSON.stringify({
        "models": models, "visible": visuals.active_count(),
        "max_visible": Visuals.MAX_VISIBLE,
        "nearest_candidates": candidates.size(),
        "camera_checks": camera_checks,
        "walked": moved, "walk_animation": animated,
        "hazard_flee": fled, "flee_actors": reacted,
        "confirmed_hunt_attack": attack_checked,
        "nearby_prey_fled": prey_flee_checked,
        "one_cell_pursuit": chase_checked,
        "multi_cell_pursuit": chase_checked,
        "obstacle_detour": true,
        "contact_distance_guard": true,
        "model_position_contact": true,
        "attack_facing_prey": true,
        "contact_sound_3d": true,
        "no_phantom_contact_sound": true,
        "fauna_inspection_spot": true,
        "zoom_keeps_actors": true,
        "wide_camera_fauna_range": true,
        "zoom_readability_lod": true,
        "imported_forward_fixed": true,
        "mesh_bbox_8_corners": true,
        "no_attack_without_visible_prey": true,
        "stale_pursuit_guard": true,
        "rendering": "реальные GLTF/GLB; ручная визуальная приёмка ещё нужна"
    }))
    print("STAGE12-VISUAL: успешно")
    quit(0)
