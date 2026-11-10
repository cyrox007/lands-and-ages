extends SceneTree
## 12.10: физическая охота и домашнее потомство за полный год.
## Шторм используется из штатного природного WorldDayRunner.

const Config = preload("res://scripts/world_config.gd")
const Map = preload("res://scripts/world_map.gd")
const Hydro = preload("res://scripts/hydrology.gd")
const Surface = preload("res://scripts/surface.gd")
const Climate = preload("res://scripts/climate.gd")
const Nature = preload("res://scripts/nature_registry.gd")
const Weather = preload("res://scripts/weather_events.gd")
const Natural = preload("res://scripts/natural_processes.gd")
const Disasters = preload("res://scripts/natural_disasters.gd")
const Fire = preload("res://scripts/fire_registry.gd")
const Runner = preload("res://scripts/world_day_runner.gd")
const Save = preload("res://scripts/world_save.gd")
const Wildlife = preload("res://scripts/wildlife_populations.gd")
const FoodWeb = preload("res://scripts/wildlife_food_web.gd")
const Harvest = preload("res://scripts/wildlife_harvest.gd")
const Domestic = preload("res://scripts/wildlife_domestication.gd")
const Paths = preload("res://scripts/world_resource_path.gd")
const Access = preload("res://scripts/wildlife_region_access.gd")

const DAYS := 365
var _seed := 1729


func _initialize() -> void:
    # Каждый прогон получает отдельное зерно генерации, но один
    # и тот же физический код и строгие правила приёмки.
    for argument in OS.get_cmdline_user_args():
        if str(argument).begins_with("--seed="):
            _seed = int(str(argument).trim_prefix("--seed="))
    var ok := _check()
    print("STAGE12-ECONOMY-FAUNA: успешно" if ok else "STAGE12-ECONOMY-FAUNA: ошибка")
    quit(0 if ok else 1)


func _make_world() -> Dictionary:
    # Никаких фальшивых зверей: используем живую карту, лес и корм.
    var world = Map.new(Config.new(256, 192, _seed))
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
    var wildlife = Wildlife.new(world, hydro, ground, climate, nature)
    if not wildlife.generate():
        return {}
    var predators = FoodWeb.new(world, climate, wildlife)
    if not predators.generate():
        return {}
    # У охоты и домашнего стада — общая живая фауна, поэтому
    # поимка и убийство обязаны уменьшать природную численность.
    var harvest = Harvest.new(world, hydro, ground, climate, wildlife)
    var domestic = Domestic.new(world, hydro, ground, climate,
        wildlife, predators, harvest)
    var weather = Weather.new(world, climate, ground, hydro)
    var natural = Natural.new(world, hydro, ground, climate)
    var disasters = Disasters.new(world, hydro, ground, climate)
    var fire = Fire.new(world, hydro, ground, climate, nature)
    var runner = Runner.new(world, hydro, ground, climate,
        weather, natural, disasters, nature, fire)
    return {"world": world, "hydro": hydro, "surface": ground,
        "climate": climate, "nature": nature, "wildlife": wildlife,
        "food_web": predators, "harvest": harvest,
        "domestic": domestic, "human_removed": 0,
        "weather": weather, "natural": natural,
        "disasters": disasters, "fire": fire, "runner": runner}


func _simulate_day(state: Dictionary) -> bool:
    # Закон сохранения: хищники уменьшают популяцию ровно на
    # реально съеденных особей и реальные потери от катастроф.
    var wildlife: RefCounted = state["wildlife"]
    var predators: RefCounted = state["food_web"]
    var before_prey: int = wildlife.total()
    var before_predators: int = predators.total()
    state["runner"].run_day()
    var day: int = state["climate"].day
    if not wildlife.advance_day(day):
        return false
    var birth: int = int(wildlife.last_events["born"])
    var death: int = int(wildlife.last_events["died"])
    var hazards: Array = state["runner"].last_result["hazards"]
    if not predators.advance_day(day, hazards):
        return false
    var events: Dictionary = predators.last_events
    if wildlife.total() != before_prey + birth - death \
            - int(events["eaten"]) - int(events["prey_lost"]):
        push_error("Хищник съел несуществующего зверя")
        return false
    if predators.total() != before_predators + int(events["born"]) \
            - int(events["died"]):
        push_error("Миграция создала или уничтожила хищников")
        return false
    for species in FoodWeb.SPECIES:
        for y in range(state["world"].config.region_count().y):
            for x in range(state["world"].config.region_count().x):
                var amount: int = predators.count_at(Vector2i(x, y), species)
                if amount < 0 or amount > FoodWeb.MAX_PER_REGION:
                    return false
    # После хищников приходят настоящие охотники и отловщики.
    # Никаких животных от нажатия кнопки: их количество может
    # уменьшиться только по факту прибытия в доступный ареал.
    var before_humans: int = wildlife.total()
    if not state["harvest"].advance_day(day) \
            or not state["domestic"].advance_day(day):
        return false
    var removed := before_humans - wildlife.total()
    if removed < 0 or removed > 3:
        push_error("Охота/отлов создали животных или изъяли слишком много")
        return false
    state["human_removed"] = int(state["human_removed"]) + removed
    return true


func _farm_site(state: Dictionary) -> Dictionary:
    # Нужен пастбищный участок рядом с реально живущими турами.
    # Берём только проходимые клетки с кормом и питьевой водой.
    var map: RefCounted = state["world"]
    var water: RefCounted = state["hydro"]
    var soil: RefCounted = state["surface"]
    var animals: RefCounted = state["wildlife"]
    var habitat: RefCounted = state["domestic"].habitats
    var regions: Vector2i = map.config.region_count()
    for ry in range(regions.y):
        for rx in range(regions.x):
            var region := Vector2i(rx, ry)
            if animals.population_at(region, "тур") < 2:
                continue
            var bounds: Rect2i = map.config.region_rect(region)
            for y in range(bounds.position.y + 1, bounds.end.y, 6):
                for x in range(bounds.position.x + 1, bounds.end.x, 6):
                    var cell := Vector2i(x, y)
                    if not Paths.walkable(map, water, soil, cell):
                        continue
                    var profile: Dictionary = habitat.profile_at(cell)
                    if profile.is_empty() or float(profile["food"]) < 0.15 \
                            or float(profile["water"]) < 0.10:
                        continue
                    return {"site": cell, "region": region}
    return {}


func _hunt_source(state: Dictionary, amount: int = 5) -> Dictionary:
    # Спрос на мясо направляем только в доступный по суше ареал
    # с воспроизводящимся запасом оленей или зайцев.
    var map: RefCounted = state["world"]
    var animals: RefCounted = state["wildlife"]
    var site: Vector2i = state["harvest"].site
    var size: Vector2i = map.config.region_count()
    var best := {}
    var shortest := 100000
    for species in ["олень", "заяц"]:
        for ry in range(size.y):
            for rx in range(size.x):
                var region := Vector2i(rx, ry)
                var remaining: int = animals.population_at(region, species)
                var reserve := maxi(amount, ceili(
                    float(animals.capacity_at(region, species)) * 0.40))
                if remaining <= reserve:
                    continue
                var path: Dictionary = Access.entry(map, state["hydro"],
                    state["surface"], site, region)
                if path.is_empty() or int(path["steps"]) >= shortest:
                    continue
                shortest = int(path["steps"])
                best = {"region": region, "species": species}
    return best


func _check() -> bool:
    var state: Dictionary = _make_world()
    if state.is_empty():
        return false
    var wildlife: RefCounted = state["wildlife"]
    var predators: RefCounted = state["food_web"]
    var hunt: RefCounted = state["harvest"]
    var farm: RefCounted = state["domestic"]
    var selected: Dictionary = _farm_site(state)
    if selected.is_empty() or not hunt.activate(selected["site"]) \
            or not farm.activate(selected["site"]) \
            or not farm.order_capture(selected["region"], "корова", 2):
        push_error("Нет физического пастбища и двух живых туров")
        return false
    var first_hunt: Dictionary = _hunt_source(state)
    if first_hunt.is_empty() or not hunt.order_hunt(
            first_hunt["region"], str(first_hunt["species"]), 1):
        push_error("Невозможно отправить охотника к настоящему стаду")
        return false
    var hunts_ordered := 1
    var butchered := 0


    if predators.total() <= 0 or predators.generate():
        push_error("Хищники появились без добычи или повторно")
        return false
    # Повторяемость независимых реестров обязательна для одинакового
    # seed; без источника добычи создать новую стаю нельзя.
    var replay = FoodWeb.new(state["world"], state["climate"], wildlife)
    if not replay.generate() or replay.to_data() != predators.to_data():
        push_error("Начальные стаи не воспроизводятся")
        return false
    var storm_region := Vector2i(-1, -1)
    var max_prey := 0
    for y in range(state["world"].config.region_count().y):
        for x in range(state["world"].config.region_count().x):
            var region := Vector2i(x, y)
            var amount := 0
            for kind in Wildlife.SPECIES:
                amount += wildlife.population_at(region, kind)
            if amount > max_prey:
                storm_region = region
                max_prey = amount
    if storm_region.x < 0:
        return false
    var storm_cell: Vector2i = state["world"].config.region_rect(
        storm_region).position + Vector2i(12, 12)
    var eaten_total := 0
    var fled_total := 0
    var lost_total := 0
    var predator_births := 0
    var initial_fox: int = predators.total("лиса")
    var initial_deer: int = wildlife.total("олень")
    var minimum_deer := maxi(2, ceili(float(initial_deer) * 0.16))
    var peak_prey: int = wildlife.total()
    var peak_predators: int = predators.total()
    var days_with_hunting := 0
    var season_markers := {}
    for day in range(2, DAYS + 1):
        if day == 186:
            # День уже пройден при проверке перезапуска из WorldSave.
            continue
        # Сырьё и домашнее стадо конкурируют с живой природой
        # весь год, а не только в момент первого отлова.
        if day % 30 == 0 and hunt.summary()["order"].is_empty():
            var source: Dictionary = _hunt_source(state)
            if not source.is_empty() and hunt.order_hunt(
                    source["region"], str(source["species"]), 1):
                hunts_ordered += 1
        if day in [13, 146, 263]:
            # Три настоящих диагностических шторма в разные сезоны:
            # без подмены численности и без графических трюков.
            state["runner"].test_storm_cell = storm_cell
        if not _simulate_day(state):
            return false
        # Туша разделывается лишь после физического возвращения.
        # Одну и ту же тушу невозможно разделать повторно; мясо
        # расходуется в хозяйстве, не становится бесконечным запасом.
        var carcasses: Dictionary = hunt.summary()["carcasses"]
        for species in carcasses:
            if hunt.butcher(str(species), 1):
                butchered += 1
                if not hunt.consume_food(1):
                    push_error("Не удалось использовать настоящее мясо")
                    return false
        var event: Dictionary = predators.last_events
        eaten_total += int(event["eaten"])
        fled_total += int(event["prey_fled"])
        lost_total += int(event["prey_lost"])
        predator_births += int(event["born"])
        peak_prey = maxi(peak_prey, wildlife.total())
        peak_predators = maxi(peak_predators, predators.total())
        if int(event["eaten"]) > 0:
            days_with_hunting += 1
        # Численность ограничена экологической моделью и не
        # превращается в бесконечные популяции на малой карте.
        if wildlife.total() < 0 or predators.total() < 0 \
                or wildlife.total() > 100000 \
                or predators.total() > 10000:
            push_error("Неконтролируемое размножение животных")
            return false
        if day == 13 and int(event["prey_fled"]) \
                + int(event["prey_lost"]) == 0:
            push_error("Шторм не вызвал реальную реакцию травоядных")
            return false
        if day in [91, 182, 273, 365]:
            # Снимки четырёх сезонов позволяют увидеть выпадение
            # отдельных видов, скрытое за общей суммой животных.
            season_markers[str(day)] = {
                "олень": wildlife.total("олень"),
                "заяц": wildlife.total("заяц"),
                "кабан": wildlife.total("кабан"),
                "хищники": predators.total()
            }
        if day == 185:
            var saved: Dictionary = Save.capture(state)
            if saved.is_empty() or not saved.has("food_web") \
                    or not saved.has("wildlife"):
                push_error("WorldSave не сохранил хищников и жертв")
                return false
            var restored: Dictionary = Save.restore(saved)
            if restored.is_empty() \
                    or restored["food_web"].to_data() != predators.to_data() \
                    or restored["wildlife"].to_data() != wildlife.to_data() \
                    or restored["harvest"].to_data() != hunt.to_data() \
                    or restored["domestic"].to_data() != farm.to_data():
                push_error("Загрузка меняет числа жертв или хищников")
                return false
            var invalid: Dictionary = saved.duplicate(true)
            if invalid["food_web"]["entries"].is_empty():
                return false
            invalid["food_web"]["entries"][0]["count"] = 50000
            if not Save.restore(invalid).is_empty():
                push_error("Повреждённый реестр хищников был принят")
                return false
            # Счётчик теста не является частью игрового WorldSave:
            # после загрузки восстанавливаем только диагностический
            # итог из уже подтверждённых человеческих изъятий.
            restored["human_removed"] = state["human_removed"]
            if not _simulate_day(restored) or not _simulate_day(state):
                return false
            if restored["food_web"].to_data() != predators.to_data() \
                    or restored["wildlife"].to_data() != wildlife.to_data() \
                    or restored["harvest"].to_data() != hunt.to_data() \
                    or restored["domestic"].to_data() != farm.to_data():
                push_error("После загрузки пищевые цепочки расходятся")
                return false
            event = predators.last_events
            eaten_total += int(event["eaten"])
            fled_total += int(event["prey_fled"])
            lost_total += int(event["prey_lost"])
            predator_births += int(event["born"])
    # Если в начале действительно было воспроизводящее стадо,
    # в конце сезона нельзя объявлять нормой единственного оленя.
    # Порог относителен к исходному ресурсу, а не захардкожен
    # как «нарисовать дополнительных оленей».
    if initial_deer >= 2 and wildlife.total("олень") < minimum_deer:
        push_error("Олени истощены хищниками: было %d, осталось %d" % [
            initial_deer, wildlife.total("олень")])
        return false
    # Обилие зайцев не оправдывает исчезновение всех лис:
    # проверяем наличие хищника после четырёх сезонов, если
    # исходно его популяция состояла из нескольких особей.
    if initial_fox >= 2 and predators.total("лиса") <= 0:
        push_error("Лисы вымерли при доступной добыче: исходно %d" % initial_fox)
        return false
    if days_with_hunting < 3:
        push_error("Пищевая цепочка прекратилась слишком рано")
        return false
    if eaten_total <= 0 or fled_total + lost_total <= 0:
        push_error("Не подтверждена охота или реакция на бедствия")
        return false
    # За год из двух диких предков должны вывестись настоящие
    # домашние потомки; нулевая добыча не считается экономикой.
    if farm.total("корова", true) <= 0 or hunt.eaten_meat <= 0 \
            or butchered < 1 or state["human_removed"] < 3:
        push_error("Нет домашнего потомства или настоящей охоты за год")
        return false
    print("STAGE12-ECONOMY-FAUNA-REPORT: ", JSON.stringify({
        "day": predators.last_day, "prey": wildlife.summary()["population"],
        "predators": predators.summary(),
        "eaten": eaten_total, "fled": fled_total,
        "lost_to_hazards": lost_total, "predator_births": predator_births,
        "peak_prey": peak_prey, "peak_predators": peak_predators,
        "hunting_days": days_with_hunting, "days": DAYS,
        "seed": _seed, "seasons": season_markers,
        "hunts_ordered": hunts_ordered, "butchered": butchered,
        "human_removed": state["human_removed"],
        "consumed_meat": hunt.eaten_meat,
        "cattle_founders_and_young": farm.total("корова"),
        "domestic_cattle": farm.total("корова", true),
        "initial_deer": initial_deer, "minimum_deer": minimum_deer,
        "initial_fox": initial_fox, "remaining_fox": predators.total("лиса")
    }))
    return true
