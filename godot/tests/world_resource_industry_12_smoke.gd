extends SceneTree
## Полный контракт полезности материалов: настоящая добыча → доставка →
## производство → фундамент и дорога. Никакой стартовой выдачи сырья.

const Config = preload("res://scripts/world_config.gd")
const Map = preload("res://scripts/world_map.gd")
const Hydro = preload("res://scripts/hydrology.gd")
const Surface = preload("res://scripts/surface.gd")
const Climate = preload("res://scripts/climate.gd")
const Nature = preload("res://scripts/nature_registry.gd")
const Resources = preload("res://scripts/natural_resource_registry.gd")
const Generation = preload("res://scripts/natural_resource_generation.gd")
const Economy = preload("res://scripts/world_first_economy.gd")
const Industry = preload("res://scripts/world_resource_industry.gd")
const Recipes = preload("res://scripts/natural_resource_recipes.gd")
const Weather = preload("res://scripts/weather_events.gd")
const Natural = preload("res://scripts/natural_processes.gd")
const Disasters = preload("res://scripts/natural_disasters.gd")
const Fire = preload("res://scripts/fire_registry.gd")
const Save = preload("res://scripts/world_save.gd")


func _initialize() -> void:
    # Тест проверяется GitHub Actions по коду возврата и явной подписи.
    var ok := _check()
    print("STAGE12-INDUSTRY: успешно" if ok else "STAGE12-INDUSTRY: ошибка")
    quit(0 if ok else 1)


func _supply(workshop: RefCounted, deposits: RefCounted,
        kind: String, count: int) -> bool:
    # Сырьё исчезает в месторождении при фактическом прибытии рабочего,
    # а не в момент появления заказа или нажатия кнопки.
    if not workshop.order_deposit(kind, count):
        push_error("Нет маршрута поставки: " + kind)
        return false
    var pending: Dictionary = workshop.delivery.duplicate(true)
    var target := Vector2i(int(pending["target"][0]),
        int(pending["target"][1]))
    var before: Dictionary = deposits.source_at(kind, target)
    var amount: int = int(before["remaining_units"])
    if workshop.stock.has(kind):
        push_error("Товар появился до отправления перевозчика")
        return false
    var duration := ceili(float(pending["length"]) /
        float(Industry.STEPS_PER_DAY)) * 2 + 2
    workshop.advance_day(workshop.last_day + duration)
    if not workshop.delivery.is_empty() \
            or int(workshop.stock.get(kind, 0)) != count \
            or int(deposits.source_at(kind, target)["remaining_units"]) != amount - count:
        push_error("Ресурс не был физически доставлен: " + kind)
        return false
    return true


func _wood(workshop: RefCounted, nature: RefCounted, count: int) -> bool:
    # Древесина берётся из исходного NatureRegistry, а не пополняется
    # автоматически из названия лесной профессии или рецепта.
    var before: int = nature.wood_total()
    if not workshop.order_wood(count):
        push_error("Нет физической древесины для металлургии")
        return false
    var distance: int = workshop.delivery["length"]
    var days := ceili(float(distance) / float(Industry.STEPS_PER_DAY)) * 2 + 2
    workshop.advance_day(workshop.last_day + days)
    if not workshop.delivery.is_empty() \
            or int(workshop.stock.get("древесина", 0)) != count \
            or nature.wood_total() != before - count:
        push_error("Древесина доставлена без физического списания")
        return false
    return true


func _check() -> bool:
    # Генерируем одну и ту же живую карту, которой пользуется игра.
    var world = Map.new(Config.new(256, 192, 1729))
    var hydro = Hydro.new(world)
    hydro.rebuild()
    var ground = Surface.new(world, hydro)
    ground.rebuild()
    var climate = Climate.new(world, hydro)
    climate.rebuild()
    climate.set_day(1)
    ground.advance_climate_day(climate)
    hydro.apply_rainfall_map(ground.runoff_map())
    var nature = Nature.new(world, hydro, ground, climate)
    nature.generate()
    var deposits = Resources.new(world)
    Generation.populate(world, hydro, ground, deposits)
    if not Recipes.validate():
        push_error("Производственные цепочки содержат недостижимые материалы")
        return false
    var initial = Economy.new(world, hydro, ground, nature, deposits, 1)
    if not initial.start():
        push_error("Не удалось выбрать реальное место мастерской")
        return false
    var workshop = Industry.new(world, hydro, ground, nature, deposits, 1)
    if not workshop.activate(initial.site):
        push_error("Хозяйственная площадка оказалась непроходимой")
        return false
    var stock_before: Dictionary = workshop.state()
    if workshop.produce("тесать камень") \
            or workshop.construct("каменный фундамент") \
            or workshop.research_next():
        push_error("Производство прошло без необходимых материалов")
        return false
    if workshop.state() != stock_before:
        push_error("Отказавший рецепт изменил склад")
        return false

    # Реальный WorldSave должен сохранять новый склад вместе со
    # старыми геологией, климатом, лесом и физическими последствиями.
    var state := {
        "world": world, "hydro": hydro, "surface": ground,
        "climate": climate,
        "weather": Weather.new(world, climate, ground, hydro),
        "natural": Natural.new(world, hydro, ground, climate),
        "disasters": Disasters.new(world, hydro, ground, climate),
        "nature": nature, "fire": Fire.new(world, hydro, ground, climate, nature),
        "resources": deposits, "industry": workshop
    }
    var snapshot: Dictionary = Save.capture(state)
    if snapshot.is_empty() or not snapshot.has("industry"):
        push_error("Склад не вошёл в общий WorldSave")
        return false
    var restored: Dictionary = Save.restore(snapshot)
    if restored.is_empty() or restored["industry"].to_data() != workshop.to_data():
        push_error("Загрузка мира изменила производственный склад")
        return false

    # Две разные постройки проверяют, что продукты реально тратятся
    # и что дорожное покрытие нельзя получить из одного камня.
    if not _supply(workshop, deposits, "камень", 2):
        return false
    if not workshop.produce("тесать камень"):
        return false
    if not _supply(workshop, deposits, "глина", 1):
        return false
    if not _supply(workshop, deposits, "песок", 3):
        return false
    if not workshop.produce("связующий раствор") \
            or not workshop.construct("каменный фундамент"):
        return false
    if not _supply(workshop, deposits, "щебень", 2):
        return false
    if not workshop.produce("дорожная подсыпка") \
            or not workshop.construct("участок дороги"):
        return false

    var end: Dictionary = workshop.state()
    if not end["stock"].is_empty() \
            or int(end["completed"].get("каменный фундамент", 0)) != 1 \
            or int(end["completed"].get("участок дороги", 0)) != 1:
        push_error("Строительство не израсходовало продукцию полностью")
        return false

    # Новые технологические ступени нельзя открывать бесплатно.
    if workshop.technology != 0 or workshop.research_next():
        push_error("Технология открылась без материальных затрат")
        return false

    # Вторая, независимая цепочка: настоящий лес и железная руда
    # открывают производство креплений через материальное исследование.
    if not _supply(workshop, deposits, "камень", 2) \
            or not workshop.produce("тесать камень"):
        return false
    if not _supply(workshop, deposits, "глина", 3) \
            or not _wood(workshop, nature, 3):
        return false
    if not workshop.produce("обжиг кирпича") \
            or not workshop.research_next() or workshop.technology != 1:
        push_error("Технология не потребовала настоящий кирпич и камень")
        return false
    if not _supply(workshop, deposits, "железная руда", 3) \
            or not _wood(workshop, nature, 3):
        return false
    if not workshop.produce("выжиг древесного угля") \
            or not workshop.produce("плавка железа") \
            or not workshop.construct("железные крепления"):
        push_error("Не удалось использовать добытое железо")
        return false
    if not workshop.stock.is_empty() \
            or int(workshop.completed.get("железные крепления", 0)) != 1:
        push_error("Металл или топливо продублированы после потребления")
        return false
    var saved: Dictionary = workshop.to_data()
    var clone = Industry.new(world, hydro, ground, nature, deposits,
        workshop.last_day)
    if not clone.load_data(saved, workshop.last_day) \
            or clone.to_data() != saved:
        push_error("Производственные результаты не восстановились")
        return false
    var bad: Dictionary = saved.duplicate(true)
    bad["stock"]["железо"] = Industry.MAX_STOCK + 1
    if clone.load_data(bad, workshop.last_day) \
            or clone.to_data() != saved:
        push_error("Повреждённый склад был принят")
        return false
    print("STAGE12-INDUSTRY-REPORT: ", JSON.stringify({
        "day": workshop.last_day, "site": [initial.site.x, initial.site.y],
        "built": workshop.completed, "remaining": workshop.stock,
        "technology": workshop.technology
    }))
    return true
