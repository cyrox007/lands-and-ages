extends SceneTree
## Приёмка 13.0–13.1: территория, оплаченный цех, коллизия, WorldSave.

const Config = preload("res://scripts/world_config.gd")
const Map = preload("res://scripts/world_map.gd")
const Hydro = preload("res://scripts/hydrology.gd")
const Surface = preload("res://scripts/surface.gd")
const Climate = preload("res://scripts/climate.gd")
const Nature = preload("res://scripts/nature_registry.gd")
const Resources = preload("res://scripts/natural_resource_registry.gd")
const Generation = preload("res://scripts/natural_resource_generation.gd")
const Economy = preload("res://scripts/world_first_economy.gd")
const Settlement = preload("res://scripts/world_settlement.gd")
const Headquarters = preload("res://scripts/world_headquarters_rules.gd")
const Industry = preload("res://scripts/world_resource_industry.gd")
const Topology = preload("res://scripts/world_road_topology.gd")
const Paths = preload("res://scripts/world_resource_path.gd")
const Visual = preload("res://scripts/world_settlement_visual.gd")
const Weather = preload("res://scripts/weather_events.gd")
const Natural = preload("res://scripts/natural_processes.gd")
const Disasters = preload("res://scripts/natural_disasters.gd")
const Fire = preload("res://scripts/fire_registry.gd")
const Save = preload("res://scripts/world_save.gd")
const Runner = preload("res://scripts/world_day_runner.gd")


func _initialize() -> void:
    # GitHub Actions получает явный статус, а не только текстовый вывод.
    var passed := _verify()
    print("STAGE13-SETTLEMENT: успешно" if passed \
        else "STAGE13-SETTLEMENT: ошибка")
    quit(0 if passed else 1)


func _verify() -> bool:
    # Создаём настоящие рельеф, водосбор, лес и залежи seed=1729.
    var world = Map.new(Config.new(256, 192, 1729))
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
    var deposits = Resources.new(world)
    Generation.populate(world, hydro, surface, deposits)
    var economy = Economy.new(world, hydro, surface, nature, deposits, 1)
    var village = Settlement.new(world, economy)

    # Нельзя создать посёлок до реального строительного заказа.
    if village.found(Vector2i(0, 0)) or not economy.start():
        push_error("Поселение создано без сырьевого заказа")
        return false
    if not village.found(economy.site) or village.found(economy.site) \
            or village.has_workshop() or village.occupies(economy.site) \
            or not village.within_territory(economy.site):
        push_error("Ошибки территории и уникальности нового поселения")
        return false
    if village.within_territory(Vector2i(-1, -1)):
        push_error("Граница поселения проходит за картой")
        return false

    # Незавершённая мастерская не должна попасть в сохранение как здание.
    var weather = Weather.new(world, climate, surface, hydro)
    var natural = Natural.new(world, hydro, surface, climate)
    var disasters = Disasters.new(world, hydro, surface, climate)
    var fire = Fire.new(world, hydro, surface, climate, nature)
    var runner = Runner.new(world, hydro, surface, climate,
        weather, natural, disasters, nature, fire)
    var state := {
        "world": world, "hydro": hydro, "surface": surface,
        "climate": climate, "weather": weather, "natural": natural,
        "disasters": disasters, "nature": nature, "fire": fire,
        "resources": deposits, "economy": economy, "settlement": village
    }
    var pending := Save.capture(state)
    if pending.is_empty() or not pending.has("settlement"):
        push_error("Раздел поселения отсутствует в WorldSave")
        return false
    var restored_pending: Dictionary = Save.restore(pending)
    if restored_pending.is_empty() \
            or restored_pending["settlement"].to_data() != village.to_data():
        push_error("Не восстановлен незавершённый заказ")
        return false

    # Атомарная загрузка отвергает поддельный ID и бесплатное здание.
    var bad: Dictionary = village.to_data()
    bad["id"] = "поддельное:поселение"
    if village.load_data(bad):
        push_error("Принят неподтверждённый ID поселения")
        return false
    bad = village.to_data()
    bad["buildings"] = [{"id": "поддельный:цех",
        "kind": Settlement.WORKSHOP, "x": village.center.x,
        "y": village.center.y}]
    if village.load_data(bad) or village.has_workshop():
        push_error("Принято здание до расхода кирпичей")
        return false

    # Дни, перевозка и строительные ресурсы берутся из действующей
    # физики этапа 12; не симулируем бесплатное нажатие "готово".
    var finished := false
    for day in range(2, 90):
        runner.run_day()
        economy.advance_day(climate.day)
        village.sync_workshop()
        if economy.phase == "приостановлено":
            push_error("Стройка остановилась: " + economy.last_event)
            return false
        if economy.built:
            finished = true
            break
    if not finished or not village.has_workshop() \
            or not village.occupies(economy.site) \
            or village.buildings().size() != 1 or village.sync_workshop():
        push_error("Реальный цех не построен либо создался дважды")
        return false
    if economy.bricks != 0 or economy.stored_clay != 0 \
            or economy.stored_wood != 0:
        push_error("Нарушено списание кирпичей и топлива")
        return false

    # Проверяем, что на карте есть настоящий StaticBody3D,
    # а не один MeshInstance3D без физической коллизии.
    var view = Visual.new()
    get_root().add_child(view)
    view.rebuild(village, world)
    var body := view.get_node_or_null("Кирпичная мастерская")
    if not (body is StaticBody3D):
        push_error("Нет физического тела мастерской")
        return false
    var collider := body.get_node_or_null("CollisionShape3D")
    var mesh := body.get_node_or_null("MeshInstance3D")
    if not (collider is CollisionShape3D) or not (mesh is MeshInstance3D):
        push_error("Отсутствует коллизия или корпус здания")
        return false
    if not (collider.shape is BoxShape3D) \
            or collider.shape.size != Visual.WORKSHOP_SIZE:
        push_error("Основание и физический размер мастерской расходятся")
        return false

    # Проверяем платный склад без повторной геологической симуляции:
    # тестовая партия продукции существует только в этой фикстуре.
    # В игровом сценарии она приходит через настоящую добычу/рецепты.
    var industry = Industry.new(world, hydro, surface, nature,
        deposits, climate.day)
    if not industry.activate(economy.site):
        push_error("Не активирован производственный участок")
        return false
    village.bind_industry(industry)
    var storage_cell := Vector2i(-1, -1)
    for distance in range(1, 4):
        if storage_cell.x >= 0:
            break
        for dx in range(-distance, distance + 1):
            var dy := distance - absi(dx)
            for sign_y in [-1, 1]:
                var candidate: Vector2i = economy.site \
                    + Vector2i(dx, dy * sign_y)
                if economy._buildable(candidate):
                    storage_cell = candidate
                    break
            if storage_cell.x >= 0:
                break
    if storage_cell.x < 0:
        push_error("В контрольном поселении нет места для склада")
        return false
    if village.build_storage(storage_cell) or village.has_storage():
        push_error("Склад появился без строительных материалов")
        return false
    if village.placement_problem(Settlement.STORAGE, storage_cell) \
            != "Для склада нужны 2 каменных блока и 2 раствора":
        push_error("UI не сообщил реальную стоимость фундамента")
        return false
    industry.stock = {"каменные блоки": 2, "строительный раствор": 2}
    if not village.placement_problem(Settlement.STORAGE, storage_cell).is_empty():
        push_error("Разрешённая площадка склада ошибочно запрещена")
        return false
    if not village.build_storage(storage_cell) or not village.has_storage() \
            or industry.stock.size() != 0 \
            or village.build_storage(storage_cell) \
            or not village.occupies(storage_cell):
        push_error("Оплаченный склад или запрет повторного строительства")
        return false
    state["industry"] = industry
    var visual = Visual.new()
    get_root().add_child(visual)
    visual.rebuild(village, world)
    var storage_body := visual.get_node_or_null("Малый склад")
    # В реестре имя хранится в нижнем регистре; имя узла совпадает.
    if storage_body == null:
        storage_body = visual.get_node_or_null(Settlement.STORAGE)
    if not (storage_body is StaticBody3D) \
            or not (storage_body.get_node_or_null("CollisionShape3D") \
                is CollisionShape3D):
        push_error("Нет физического корпуса малого склада")
        return false

    # Дорога — физический результат существующего рецепта. Сначала
    # проверяем отсутствие бесплатной постройки, затем оплату покрытия.
    var road_cell := Vector2i(-1, -1)
    for side in Topology.SIDES:
        var candidate: Vector2i = village.center + side
        if village.can_build_road(candidate):
            road_cell = candidate
            break
    if road_cell.x < 0:
        push_error("На исходном участке нет достижимой дорожной клетки")
        return false
    if village.build_road(road_cell) or not village.roads().is_empty():
        push_error("Дорога появилась без оплаченных материалов")
        return false
    if village.placement_problem("участок дороги", road_cell) \
            != "Для участка дороги нужны 3 единицы покрытия":
        push_error("UI не сообщил недостающие дорожные материалы")
        return false
    industry.stock = {"дорожное покрытие": 3}
    if not village.placement_problem("участок дороги", road_cell).is_empty():
        push_error("Разрешённая дорожная клетка ошибочно запрещена")
        return false
    if not village.build_road(road_cell) or village.roads().size() != 1 \
            or not industry.stock.is_empty() \
            or int(industry.completed.get("участок дороги", 0)) != 1 \
            or village.build_road(road_cell) or village.road_mask(road_cell) != 0:
        push_error("Нет материальной дороги или нарушено списание")
        return false
    if village.placement_problem(Settlement.STORAGE, road_cell) \
            != "Клетка уже занята дорогой" \
            or village.placement_problem("участок дороги", road_cell) \
                != "Клетка уже занята дорогой" \
            or village.placement_problem("участок дороги", village.center) \
                != "Здесь уже стоит здание" \
            or village.placement_problem("участок дороги", Vector2i(-1, -1)) \
                != "Площадка вне границ карты":
        push_error("Размещение приняло занятую или выходящую за карту клетку")
        return false

    # Существующая дорога влияет на путь и скорость перевозчика;
    # природная проверка проходимости при этом не отключается.
    var path: Array[Vector2i] = Paths.find(
        world, hydro, surface, village.center, road_cell, industry.road_tiles)
    if path.size() != 1 or path[0] != road_cell:
        push_error("Маршрут не использует готовую дорогу")
        return false
    var segment: Array[Vector2i] = []
    var paved := {}
    for x in range(16):
        var point := Vector2i(x, 0)
        segment.append(point)
        paved[point] = true
    if Industry.travel_steps(segment, {}) != Industry.STEPS_PER_DAY \
            or Industry.travel_steps(segment, paved) != 16:
        push_error("Дорога не ускоряет физический переход клеток")
        return false

    visual.rebuild(village, world)
    var road_body := visual.get_node_or_null(
        "Дорога %d_%d" % [road_cell.x, road_cell.y])
    if not (road_body is StaticBody3D):
        push_error("Отсутствует физическое дорожное полотно")
        return false
    var road_collision := road_body.get_node_or_null("CollisionShape3D")
    if not (road_collision is CollisionShape3D) \
            or not (road_collision.shape is BoxShape3D) \
            or road_collision.shape.size != Visual.ROAD_SIZE:
        push_error("Дорожное полотно не имеет размера и коллизии")
        return false

    # Главный 3D-центр занимает четыре действительных клетки и
    # не получает бесплатного здания от самого факта основания поселения.
    var hq_cell := Vector2i(-1, -1)
    for dx in range(-8, 8):
        if hq_cell.x >= 0:
            break
        for dy in range(-8, 8):
            var candidate: Vector2i = village.center + Vector2i(dx, dy)
            if village.can_build_headquarters(candidate):
                hq_cell = candidate
                break
    if hq_cell.x < 0 or village.build_headquarters(hq_cell):
        push_error("Центр 2×2 отсутствует или построен без материалов")
        return false
    industry.stock = {
        "обожжённый кирпич": 3, "каменные блоки": 2,
        "строительный раствор": 2
    }
    if not village.build_headquarters(hq_cell) \
            or not industry.stock.is_empty() \
            or village.build_headquarters(hq_cell):
        push_error("Не выполнено атомарное списание центра поселения")
        return false
    for plot in Headquarters.footprint(hq_cell):
        if not village.occupies(plot) or not industry.blocked_tiles.has(plot):
            push_error("3D-центр не закрыл настоящие четыре клетки")
            return false
    if Headquarters.visual_stage(village.headquarters_state()) != "фундамент":
        push_error("Начальная стадия строительства неверна")
        return false
    visual.rebuild(village, world)
    var hq_body := visual.get_node_or_null("Центр поселения")
    if not (hq_body is StaticBody3D) \
            or not (hq_body.get_node_or_null("CollisionShape3D") \
                is CollisionShape3D) \
            or hq_body.get_node_or_null("Каменный фундамент") == null:
        push_error("Нет объёмного 3D-центра или коллизии фундамента 2×2")
        return false

    # Порт выбирается на доступной клетке снаружи складского корпуса.
    # Он обслуживает один реальный производственный запас, не создавая
    # второй склад и не нарушая ранее проложенную дорогу.
    var storage_port: Vector2i = village.port_for(Settlement.STORAGE)
    if storage_port.x < 0 or village.occupies(storage_port) \
            or industry.home_port != storage_port \
            or not Paths.walkable(world, hydro, surface, storage_port) \
            or not industry.blocked_tiles.has(village.center) \
            or not industry.blocked_tiles.has(storage_cell):
        push_error("Рабочий получил неверный порт физического склада")
        return false
    if not Paths.find(world, hydro, surface, storage_port,
            village.center, industry.road_tiles,
            industry.blocked_tiles).is_empty():
        push_error("Рабочий может пройти сквозь мастерскую")
        return false

    # Новый и старый формат восстановления сохраняют расход, объект
    # и координаты. Порченое положение должно заблокировать весь файл.
    var complete := Save.capture(state)
    var restored: Dictionary = Save.restore(complete)
    if complete.is_empty() or restored.is_empty() \
            or restored["settlement"].to_data() != village.to_data() \
            or restored["economy"].to_data() != economy.to_data() \
            or restored["industry"].road_tiles.size() != 1 \
            or restored["industry"].home_port != storage_port \
            or restored["industry"].blocked_tiles.size() != 6:
        push_error("WorldSave изменил физическую постройку или запасы")
        return false
    bad = complete.duplicate(true)
    bad["industry"]["completed"].erase(Headquarters.CONSUMERS[1])
    if not Save.restore(bad).is_empty():
        push_error("WorldSave принял неоплаченный центр поселения")
        return false
    bad = complete.duplicate(true)
    bad["settlement"]["headquarters"]["level"] = 4
    if not Save.restore(bad).is_empty():
        push_error("WorldSave принял поддельный IV уровень центра")
        return false
    bad = complete.duplicate(true)
    bad["settlement"]["headquarters"]["x"] = village.center.x
    if not Save.restore(bad).is_empty():
        push_error("WorldSave принял центр поверх мастерской")
        return false
    bad = complete.duplicate(true)
    bad["industry"]["completed"].erase("участок дороги")
    if not Save.restore(bad).is_empty():
        push_error("WorldSave принял бесплатную дорогу")
        return false
    bad = complete.duplicate(true)
    bad["settlement"]["roads"][0] = [village.center.x, village.center.y]
    if not Save.restore(bad).is_empty():
        push_error("WorldSave принял дорогу через фундамент здания")
        return false
    bad = complete.duplicate(true)
    bad["settlement"]["buildings"][0]["x"] += 1
    if not Save.restore(bad).is_empty():
        push_error("WorldSave принял поддельную координату постройки")
        return false
    var legacy: Dictionary = complete.duplicate(true)
    legacy.erase("settlement")
    var old: Dictionary = Save.restore(legacy)
    if old.is_empty() or old["settlement"].established() \
            or not old["settlement"].attach_legacy_workshop() \
            or old["settlement"].buildings().size() != 1:
        push_error("Нарушена совместимость старого готового цеха")
        return false
    # Новая поставка начинает путь у двери, а не в фундаменте.
    # Сохранение во время маршрута должно восстановить ровно то же
    # положение рабочего и тот же порт, без появления лишнего груза.
    var stock_before: int = int(industry.stock.get("камень", 0))
    if not industry.order_deposit("камень", 1):
        push_error("Перевозчик не смог заказать реальный камень")
        return false
    if industry.delivery["position"] != [storage_port.x, storage_port.y] \
            or int(industry.stock.get("камень", 0)) != stock_before:
        push_error("Перевозчик начал путь внутри склада или бесплатно получил груз")
        return false
    var in_transit: Dictionary = Save.capture(state)
    var resumed: Dictionary = Save.restore(in_transit)
    if in_transit.is_empty() or resumed.is_empty() \
            or resumed["industry"].delivery != industry.delivery \
            or resumed["industry"].home_port != storage_port:
        push_error("Маршрут перевозчика и порт не пережили WorldSave")
        return false

    # После прибытия к источнику товар ещё находится в пути. Только
    # возвращение к действительному порту позволяет разгрузить камень.
    var distance: int = int(industry.delivery["length"])
    var days := mini(200, ceili(float(distance) /
        float(Industry.STEPS_PER_DAY)) * 3 + 8)
    for step in range(days):
        if industry.delivery.is_empty():
            break
        industry.advance_day(industry.last_day + 1)
        if not industry.delivery.is_empty():
            var pair: Array = industry.delivery["position"]
            var worker := Vector2i(int(pair[0]), int(pair[1]))
            if village.occupies(worker) \
                    or int(industry.stock.get("камень", 0)) != stock_before:
                push_error("Перевозчик прошёл через здание или выгрузил в пути")
                return false
    if not industry.delivery.is_empty() \
            or int(industry.stock.get("камень", 0)) != stock_before + 1:
        push_error("Перевозчик не доставил камень к доступному порту")
        return false

    if not _verify_headquarters_lifecycle(village, industry, visual, world):
        return false
    print("STAGE13: центр ", village.center, " · день ", climate.day,
        " · здания ", village.buildings().size(),
        " · вход ", storage_port, " · дорог ", village.roads().size())
    return true


func _verify_headquarters_lifecycle(village: RefCounted, industry: RefCounted,
        visual: Node3D, world: RefCounted) -> bool:
    # Дни здесь ускорены только в фикстуре: сами правила центра
    # проверяют каждый оплаченный переход и защищают от повторного дня.
    # В игровой сцене эти же правила вызываются после WorldDayRunner.
    var day: int = industry.last_day
    industry.last_day = day + Headquarters.BUILD_DAYS
    if not village.advance_day(industry.last_day) \
            or village.advance_day(industry.last_day) \
            or str(village.headquarters_state()["state"]) != "готово":
        push_error("Стройка центра не завершилась через восемь суток")
        return false

    # Каждое улучшение платное, а не просто смена графики.
    var costs := [
        {"обожжённый кирпич": 3, "каменные блоки": 4,
            "строительный раствор": 4},
        {"железо": 2, "каменные блоки": 6,
            "строительный раствор": 4},
        {"бронза": 3, "железо": 4, "каменные блоки": 8}
    ]
    for level in range(2, 5):
        if village.upgrade_headquarters():
            push_error("Разрешено бесплатное улучшение центра")
            return false
        # Технологию и товарные партии настраивает только тест:
        # обычный игрок обязан исследовать их и произвести сам.
        industry.technology = level - 2 if level <= 3 else 2
        industry.stock = costs[level - 2].duplicate(true)
        if not village.upgrade_headquarters() or not industry.stock.is_empty() \
                or village.upgrade_headquarters():
            push_error("Дважды оплачено улучшение уровня %d" % level)
            return false
        if village.within_territory(village.center +
                Vector2i(Headquarters.RADII[level - 1], 0)):
            push_error("Территория расширилась до завершения улучшения")
            return false
        industry.last_day += Headquarters.BUILD_DAYS
        village.advance_day(industry.last_day)
        if int(village.headquarters_state()["level"]) != level \
                or not village.within_territory(village.center +
                    Vector2i(Headquarters.RADII[level - 1], 0)) \
                or not village.load_data(village.to_data()):
            push_error("Не закреплён оплаченный уровень %d" % level)
            return false
        visual.rebuild(village, world)
        var hq: Node3D = visual.get_node_or_null("Центр поселения")
        if hq == null or (level >= 3 \
                and hq.get_node_or_null("Башня") == null) \
                or (level == 4 and hq.get_node_or_null("Донжон") == null):
            push_error("Отсутствует трёхмерная архитектура уровня %d" % level)
            return false

    # Повреждения меняют вид, руины стареют, но место 2×2 остаётся
    # занятым. Ремонт возможен только после нового расхода материалов.
    if not village.damage_headquarters(45) \
            or village.headquarters_state()["state"] != "повреждено" \
            or not village.damage_headquarters(60) \
            or village.headquarters_state()["state"] != "свежие руины":
        push_error("Не работают реальные повреждения и разрушение")
        return false
    visual.rebuild(village, world)
    var ruin: Node3D = visual.get_node_or_null("Центр поселения")
    if ruin == null or ruin.get_node_or_null("Обломки") == null \
            or ruin.get_node_or_null("Левый скат крыши") != null:
        push_error("Разрушенный центр продолжает показывать целую крышу")
        return false
    industry.last_day += 30
    village.advance_day(industry.last_day)
    if village.headquarters_state()["state"] != "заросшие руины" \
            or village.repair_headquarters():
        push_error("Старение руин или запрет бесплатного ремонта нарушены")
        return false
    industry.stock = {
        "каменные блоки": 2, "строительный раствор": 2
    }
    if not village.repair_headquarters() or village.repair_headquarters():
        push_error("Двойное восстановление прошло без платы")
        return false
    industry.last_day += Headquarters.BUILD_DAYS
    village.advance_day(industry.last_day)
    var restored: Dictionary = village.headquarters_state()
    if restored["state"] != "готово" or int(restored["integrity"]) != 100 \
            or int(restored["level"]) != 4 \
            or not village.load_data(village.to_data()):
        push_error("Ремонт не восстановил оплаченный центр IV уровня")
        return false
    return true
