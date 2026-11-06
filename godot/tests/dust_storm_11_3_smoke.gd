extends SceneTree
## Этап 11.3/V2.7: пыльный ветер переносит землю, а не декоративные частицы.

const Config = preload("res://scripts/world_config.gd")
const Map = preload("res://scripts/world_map.gd")
const Hydro = preload("res://scripts/hydrology.gd")
const Surface = preload("res://scripts/surface.gd")
const Climate = preload("res://scripts/climate.gd")
const Nature = preload("res://scripts/nature_registry.gd")
const Weather = preload("res://scripts/weather_events.gd")
const Processes = preload("res://scripts/natural_processes.gd")
const Disasters = preload("res://scripts/natural_disasters.gd")
const Runner = preload("res://scripts/world_day_runner.gd")
const Visual = preload("res://scripts/weather_visual_state.gd")
const FX = preload("res://scripts/weather_fx_controller.gd")

var failures: Array[String] = []


func _check(ok: bool, message: String) -> void:
    # Собираем ошибки за один запуск, чтобы сравнить физику,
    # долговечность сохранения и работу графики в одном CI.
    if not ok:
        failures.append(message)


func _models(seed: int) -> Dictionary:
    # Создаём реальную географию и грунт; пик ветра ниже задаётся
    # только в испытании, а не в коде обычного игрового климата.
    var world := Map.new(Config.new(96, 80, seed, 16, 32))
    var hydro := Hydro.new(world)
    hydro.rebuild()
    var surface := Surface.new(world, hydro)
    surface.rebuild()
    var climate := Climate.new(world, hydro)
    climate.rebuild()
    climate.set_day(1)
    surface.advance_climate_day(climate)
    hydro.apply_rainfall_map(surface.runoff_map())
    return {"world": world, "hydro": hydro,
        "surface": surface, "climate": climate}


func _source_for(disasters: RefCounted, world: RefCounted,
        hydro: RefCounted, climate: RefCounted,
        forecast: RefCounted = null) -> Vector2i:
    # Ищем источник, откуда ветер сможет вынести пыль на сушу.
    # За границей карты и в воде перенос безусловно запрещён.
    for y in range(8, world.config.height - 8):
        for x in range(8, world.config.width - 8):
            var cell := Vector2i(x, y)
            if not disasters.dust_source_ready(cell):
                continue
            var index: int = hydro.cell_index(cell)
            if forecast != null:
                # Для следующего игрового дня заранее исключаем
                # будущий снег и сильный дождь, сохраняя климат неизменным.
                if forecast.temperature_at_index(index) < 6.0 \
                        or forecast.precipitation_at_index(index) > 0.18 \
                        or hydro.wetness_at(index) > 0.42:
                    continue
            var direction: Vector2 = climate.wind_direction_at_index(index)
            if forecast != null:
                direction = forecast.wind_direction_at_index(index)
            var target := cell + Vector2i(roundi(direction.x * 3.0),
                roundi(direction.y * 3.0))
            if not world.config.contains_cell(target):
                continue
            if hydro.has_water(hydro.cell_index(target)):
                continue
            return cell
    return Vector2i(-1, -1)


func _total_sediment(surface: RefCounted) -> float:
    # Массу сверяем непосредственно по всем отложениям, поскольку
    # противоположные знаки на источнике и приёмнике должны сократиться.
    var total := 0.0
    for volume in surface._sediment:
        total += volume
    return total


func _test_physics_and_save() -> void:
    # Пробная буря переносит реальный грунт по направлению Climate.
    var models: Dictionary = _models(1729)
    var world: RefCounted = models["world"]
    var hydro: RefCounted = models["hydro"]
    var surface: RefCounted = models["surface"]
    var climate: RefCounted = models["climate"]
    climate.set_day(2)
    surface.advance_climate_day(climate)
    surface._moisture.fill(0.025)
    surface._snow.fill(0.0)
    surface._frost.fill(0.0)
    climate._wind.fill(34.0)
    climate._rain.fill(0.0)
    climate._storm.fill(0.0)
    var disasters := Disasters.new(world, hydro, surface, climate)
    var source := _source_for(disasters, world, hydro, climate)
    if source.x < 0:
        _check(false, "Существует сухой рыхлый участок с направлением на сушу")
        return

    var wind: Vector2 = climate.wind_direction_at_index(
        hydro.cell_index(source))
    var target := source + Vector2i(roundi(wind.x * 3.0),
        roundi(wind.y * 3.0))
    var dry_risk: Dictionary = disasters.conditions_at(source, false)
    _check(float(dry_risk["пыльная буря"]) > 0.65,
        "Сухость, открытый субстрат и сильный порыв дают риск")
    var before_source: float = world.vertex_at(source)
    var before_target: float = world.vertex_at(target)
    var before_mass := _total_sediment(surface)
    var before_revision: int = world.revision
    var impact: Dictionary = disasters.apply_dust_storm(source, 1.0)

    _check(int(impact.get("vertices", 0)) >= 2
        and float(impact.get("sediment_volume", 0.0)) > 0.0
        and float(impact.get("sediment_volume", 0.0)) <= 0.05,
        "Буря переносит ограниченную массу и меняет рельеф")
    _check(world.revision > before_revision
        and world.vertex_at(source) < before_source
        and world.vertex_at(target) > before_target,
        "Грунт физически уходит с наветренной клетки на подветренную")
    _check(absf(_total_sediment(surface) - before_mass) < 0.00001,
        "Перемещение не создаёт и не уничтожает массу")

    # Вода или снежная поверхность не должны отдавать пыль даже в
    # диагностике при максимальной интенсивности.
    var after_revision: int = world.revision
    var index: int = hydro.cell_index(source)
    surface._snow[index] = 0.5
    _check(not disasters.dust_source_ready(source)
        and disasters.apply_dust_storm(source, 1.0).is_empty()
        and world.revision == after_revision,
        "Снежная клетка не превращается в пылевой источник")
    surface._snow[index] = 0.0
    surface._moisture[index] = 0.8
    _check(not disasters.dust_source_ready(source),
        "Влажный грунт блокирует новый пылевой перенос")

    # Снимок Surface хранит подписанный JSON и точные Float32
    # отложения. Геометрия карты уже была изменена до сохранения.
    var saved: Dictionary = JSON.parse_string(JSON.stringify(
        surface.to_snapshot()))
    var restored := Surface.new(world, hydro)
    restored.rebuild()
    _check(restored.load_snapshot(saved),
        "Реальная поверхность после пылевого переноса загружается из JSON")
    _check(absf(_total_sediment(restored) -
        _total_sediment(surface)) < 0.00001
        and absf(float(restored.profile_at(source)["sediment"]) -
            float(surface.profile_at(source)["sediment"])) < 0.00001,
        "Снятый и нанесённый грунт переживают сохранение")


func _test_natural_origin() -> void:
    # Природное событие требует ветра и сухих открытых клеток:
    # генератор не должен создавать бурю просто по времени суток.
    var models: Dictionary = _models(2719)
    var world: RefCounted = models["world"]
    var hydro: RefCounted = models["hydro"]
    var surface: RefCounted = models["surface"]
    var climate: RefCounted = models["climate"]
    var disasters := Disasters.new(world, hydro, surface, climate)
    var generated := false
    for day in range(2, 20):
        climate.set_day(day)
        surface.advance_climate_day(climate)
        surface._moisture.fill(0.025)
        surface._snow.fill(0.0)
        surface._frost.fill(0.0)
        climate._rain.fill(0.0)
        climate._wind.fill(34.0)
        climate._storm.fill(0.0)
        for event in disasters.advance_day(day):
            if event["kind"] != "пыльная буря":
                continue
            generated = true
            _check(int(event["duration_days"]) == 1
                and int(event["vertices"]) >= 2
                and float(event["sediment_volume"]) > 0.0,
                "Естественная буря оставляет материальный след за один день")
            break
        if generated:
            break
    _check(generated, "Сухой фронт может породить естественную пыльную бурю")
    if not generated:
        return

    # Сохраняем именно полное стихийное событие, включая физический
    # объём, не меняя девятипольную запись формата v1.
    var saved: Dictionary = JSON.parse_string(JSON.stringify(
        disasters.to_data()))
    var restored := Disasters.new(world, hydro, surface, climate)
    _check(restored.load_data(saved),
        "Событие пыльной бури читается из прежнего JSON v1")
    var restored_dust := false
    for event in restored.last_events:
        if event["kind"] == "пыльная буря":
            restored_dust = float(event["sediment_volume"]) > 0.0
    _check(restored_dust
        and restored.total_events == disasters.total_events,
        "Событие, перенесённый грунт и счётчик не потеряны")


func _test_runner_and_fx() -> void:
    # Диагностическая команда не подменяет грунт вручную: она
    # добавляет один запрос, который исполняется суточным Runner.
    var seed := 1739
    var models: Dictionary = _models(seed)
    var world: RefCounted = models["world"]
    var hydro: RefCounted = models["hydro"]
    var surface: RefCounted = models["surface"]
    var climate: RefCounted = models["climate"]
    surface._moisture.fill(0.02)
    surface._snow.fill(0.0)
    var nature := Nature.new(world, hydro, surface, climate)
    _check(nature.generate(), "Лес подготовлен для обычного суточного цикла")
    var disasters := Disasters.new(world, hydro, surface, climate)
    var preview := Climate.new(world, hydro)
    preview.rebuild()
    preview.set_day(2)
    # Следующий день может принести снег; выбираем будущую
    # устойчиво тёплую сухую клетку без изменения физики игры.
    var source := _source_for(disasters, world, hydro, climate, preview)
    if source.x < 0:
        _check(false, "Найден тёплый сухой участок для диагностики")
        return
    var weather := Weather.new(world, climate, surface, hydro)
    var processes := Processes.new(world, hydro, surface, climate)
    var runner := Runner.new(world, hydro, surface, climate,
        weather, processes, disasters, nature)
    runner.test_dust_cell = source
    runner.run_day()

    var count := 0
    var moved := 0.0
    for event in runner.last_result["hazards"]:
        if event.get("source", "") != "диагностика":
            continue
        count += 1
        _check(event["kind"] == "пыльная буря" and event["cell"] == source,
            "Runner создал именно материальную пыльную бурю")
        moved = float(event["sediment_volume"])
    if count != 1 or moved <= 0.0:
        # При отказе показываем реальные условия, чтобы отличить
        # мокрый грунт от отсутствующего подветренного приёмника.
        printerr("11.3/V2.7 диагностика: клетка=", source,
            " почва=", surface.profile_at(source),
            " погода=", climate.weather_at(source),
            " день=", climate.day, " событий=", count)
    _check(count == 1 and moved > 0.0 and runner.test_dust_cell.x < 0,
        "Физическое испытание переносит грунт ровно один раз")

    var fx := FX.new()
    root.add_child(fx)
    var snapshot: Dictionary = Visual.sample(climate,
        world.config, Vector2(source), 36.0)
    var before_climate: Dictionary = climate.to_data()
    var direction: Vector2 = climate.wind_direction_at_index(
        hydro.cell_index(source))
    fx.show_dust_storm_event(1.0, direction)
    fx.apply_snapshot(snapshot, Vector2(source), 3.0, 36.0, seed)
    var dust: GPUParticles3D = fx.get("_dust")
    _check(dust != null and dust.emitting,
        "Буря видна цветным камерным GPU-эмиттером")
    if dust != null:
        var motion: ParticleProcessMaterial = dust.process_material
        _check(dust.amount == 220 and motion.emission_box_extents.y == 2.0
            and Vector2(motion.direction.x,
                motion.direction.z).dot(direction) > 0.98,
            "Пыль движется по направлению ветра без миллионов узлов")
    _check(climate.to_data() == before_climate,
        "Визуальная пыль не изменяет физический климат")
    fx.set_effects_enabled(false)
    _check(dust != null and not dust.emitting,
        "Выключение эффектов скрывает пыль, не отменяя эрозию")
    root.remove_child(fx)
    fx.free()

    runner.run_day()
    for event in runner.last_result["hazards"]:
        _check(event.get("source", "") != "диагностика",
            "Кнопка не создаёт повторную пыльную бурю без действия")


func _run() -> void:
    # Обособленные миры исключают зависимость физических проверок
    # от порядка их запуска и от состояния графической сцены.
    _test_physics_and_save()
    _test_natural_origin()
    _test_runner_and_fx()
    if not failures.is_empty():
        for reason in failures:
            printerr("11.3/V2.7: ", reason)
        quit(1)
        return
    print("11.3/V2.7: сухой грунт, перенос по ветру, FX, JSON — успешно")
    quit(0)


func _initialize() -> void:
    # Сначала подготавливается SceneTree, затем тест GPU-эмиттера.
    call_deferred("_run")
