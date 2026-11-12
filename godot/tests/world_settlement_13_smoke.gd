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
const Industry = preload("res://scripts/world_resource_industry.gd")
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
    village.industry = industry
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
    industry.stock = {"каменные блоки": 2, "строительный раствор": 2}
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

    # Новый и старый формат восстановления сохраняют расход, объект
    # и координаты. Порченое положение должно заблокировать весь файл.
    var complete := Save.capture(state)
    var restored: Dictionary = Save.restore(complete)
    if complete.is_empty() or restored.is_empty() \
            or restored["settlement"].to_data() != village.to_data() \
            or restored["economy"].to_data() != economy.to_data():
        push_error("WorldSave изменил физическую постройку или запасы")
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
    print("STAGE13: центр ", village.center, " · день ", climate.day,
        " · мастерских ", village.buildings().size())
    return true
