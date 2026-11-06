extends SceneTree
## 11.1 — полная регрессия различимых климатических осадков.
## Headless проверяет физические контракты; художественные кадры
## должны отдельно подтверждаться графическим Godot.

const Config = preload("res://scripts/world_config.gd")
const Map = preload("res://scripts/world_map.gd")
const Hydrology = preload("res://scripts/hydrology.gd")
const Climate = preload("res://scripts/climate.gd")
const Visual = preload("res://scripts/weather_visual_state.gd")
const Effects = preload("res://scripts/weather_fx_controller.gd")

class Front extends RefCounted:
    var revision := 1

    func weather_at(cell: Vector2i) -> Dictionary:
        # По одну сторону фронта — мороз и снег, по другую —
        # тёплый ливень с градом, в центральной полосе — мокрый снег.
        if cell.x < 12:
            return {
                "temperature": -9.0, "rainfall": 0.0, "snowfall": 1.4,
                "wind_speed": 21.0, "wind_gust": 29.0
            }
        if cell.x < 20:
            return {
                "temperature": 0.4, "rainfall": 0.85, "snowfall": 0.75,
                "wind_speed": 9.0, "wind_gust": 12.0
            }
        return {
            "temperature": 12.0, "rainfall": 2.2, "snowfall": 0.0,
            "storm_intensity": 0.88, "wind_speed": 18.0,
            "wind_gust": 30.0
        }


var failures: Array[String] = []


func _check(ok: bool, name: String) -> void:
    # Каждое условие протоколируется отдельно: результат одного
    # погодного режима не скрывает сбой другого.
    if not ok:
        failures.append(name)


func _weather(temp: float, rain: float, snow: float,
        storm: float, wind: float, gust: float) -> Dictionary:
    # Только входной снимок климата; рендер не создаёт осадки
    # и не записывает событий или температуры в физические модели.
    return Visual.from_weather({
        "temperature": temp, "rainfall": rain, "snowfall": snow,
        "storm_intensity": storm, "wind_speed": wind,
        "wind_gust": gust, "wind_direction_x": 1.0,
        "wind_direction_y": 0.0, "humidity": 0.85
    })


func _test_classification() -> Dictionary:
    # Морось, ливень, мокрый снег, метель и град должны быть
    # различимы по независимым, уже существующим полям Climate.
    var dry: Dictionary = _weather(13.0, 0.0, 0.0, 0.0, 3.0, 3.0)
    var drizzle: Dictionary = _weather(13.0, 0.20, 0.0, 0.0, 4.0, 5.0)
    var downpour: Dictionary = _weather(14.0, 2.4, 0.0, 0.45, 13.0, 18.0)
    var wet: Dictionary = _weather(0.4, 0.85, 0.75, 0.0, 7.0, 9.0)
    var blizzard: Dictionary = _weather(-9.0, 0.0, 1.6, 0.0, 21.0, 29.0)
    var hail: Dictionary = _weather(13.0, 2.2, 0.0, 0.88, 18.0, 30.0)

    _check(float(dry["rain"]) == 0.0 and float(dry["snow"]) == 0.0
        and float(dry["hail"]) == 0.0 and float(dry["wet_snow"]) == 0.0,
        "Сухой климат не запускает осадки")
    _check(float(drizzle["drizzle"]) > 0.0
        and float(drizzle["downpour"]) == 0.0
        and float(drizzle["hail"]) == 0.0,
        "Морось мелкая, без ливня или града")
    _check(float(downpour["downpour"]) > 0.85
        and float(downpour["drizzle"]) == 0.0,
        "Ливень заметно интенсивнее мороси")
    _check(float(wet["wet_snow"]) > 0.35
        and float(wet["hail"]) == 0.0,
        "Мокрый снег возможен только при смешанных осадках")
    _check(float(blizzard["blizzard"]) > 0.7
        and float(blizzard["hail"]) == 0.0,
        "Метель нуждается в настоящем снегопаде и ветре")
    _check(float(hail["hail"]) > 0.65
        and float(hail["snow"]) == 0.0,
        "Град — визуальная форма мощного тёплого грозового фронта")
    _check(float(_weather(13.0, 0.0, 0.0, 1.0, 18.0, 30.0)["hail"]) == 0.0
        and float(_weather(13.0, 2.0, 0.0, 0.0, 18.0, 30.0)["hail"]) == 0.0,
        "Град не возникает без дождя или грозового фронта")
    _check(float(_weather(0.4, 0.0, 0.85, 0.0, 8.0, 8.0)["wet_snow"]) == 0.0,
        "Сухой снег не превращается в мокрый без дождя")
    return {"dry": dry, "drizzle": drizzle, "downpour": downpour,
        "wet": wet, "blizzard": blizzard, "hail": hail}


func _test_emitters(states: Dictionary, world: RefCounted,
        climate: RefCounted, hydro: RefCounted) -> void:
    # Контроллер создаёт все узлы один раз и не расширяет
    # сцену при панорамировании и смене типа осадков.
    var fx := Effects.new()
    root.add_child(fx)
    var fixed_nodes := fx.get_child_count()
    _check(fixed_nodes == 8, "Число GPU-эмиттеров постоянно и ограничено")

    fx.set_quality(1)
    fx.apply_snapshot(states["drizzle"], Vector2(14, 12), 0.0, 44.0, 1729)
    var rain: GPUParticles3D = fx._rain
    var snow: GPUParticles3D = fx._snow
    var wet: GPUParticles3D = fx._wet_snow
    var hail: GPUParticles3D = fx._hail
    var splashes: GPUParticles3D = fx._splashes
    var drift: GPUParticles3D = fx._snowdrift
    var light_length: float = (rain.draw_pass_1 as QuadMesh).size.y
    _check(rain.emitting and not snow.emitting and not hail.emitting
        and not wet.emitting and not drift.emitting,
        "Морось не создаёт снег, град или метель")

    fx.apply_snapshot(states["downpour"], Vector2(14, 12), 0.0, 44.0, 1729)
    _check((rain.draw_pass_1 as QuadMesh).size.y > light_length * 2.0
        and splashes.emitting and not hail.emitting,
        "Ливень усиливает струи и создаёт низовые брызги")

    fx.apply_snapshot(states["wet"], Vector2(14, 12), 0.0, 44.0, 1729)
    _check(wet.emitting and snow.emitting and not hail.emitting,
        "Мокрый снег сочетает тяжёлые хлопья и обычный снег")

    fx.apply_snapshot(states["blizzard"], Vector2(14, 12), 0.0, 44.0, 1729)
    _check(snow.emitting and drift.emitting and not wet.emitting
        and not hail.emitting,
        "Метель добавляет снежную позёмку, но не град")

    fx.apply_snapshot(states["hail"], Vector2(14, 12), 0.0, 44.0, 1729)
    _check(hail.emitting and rain.emitting and not snow.emitting
        and not wet.emitting, "Грозовой ливень даёт ограниченный град")
    var shader := hail.draw_pass_1.material as ShaderMaterial
    _check(int(shader.get_shader_parameter("particle_kind")) == 3,
        "Для града используется собственная геометрическая маска")
    _check(fixed_nodes == fx.get_child_count(),
        "Новые кадры не создают новые узлы и частицы сверх лимита")
    _check(hail.amount == Effects.HAIL_PARTICLES
        and splashes.amount == Effects.SPLASH_PARTICLES
        and drift.amount == Effects.DRIFT_PARTICLES,
        "Бюджет осадков независим от площади карты")

    # Дальний LOD и отключение визуализации обязаны выключать
    # все четыре новых режима, оставляя симуляцию неизменной.
    fx.apply_snapshot(states["hail"], Vector2(14, 12), 0.0, 110.0, 1729)
    _check(not hail.emitting and not splashes.emitting
        and not rain.emitting,
        "На дальнем масштабе частицы осадков не расходуют GPU")
    fx.set_effects_enabled(false)
    fx.apply_snapshot(states["blizzard"], Vector2(14, 12), 0.0, 44.0, 1729)
    _check(not rain.emitting and not snow.emitting and not drift.emitting,
        "Визуальное отключение останавливает все эффекты")
    fx.set_effects_enabled(true)

    # Четыре канала локальной маски: дождь, снег, град, мокрый снег.
    # Разные фронты существуют одновременно на одной карте.
    var front := Front.new()
    fx.sync_world(front, world, Vector2(16, 12), 44.0)
    var texture: Image = fx._mask_texture.get_image()
    var left := texture.get_pixel(7, 8)
    var mid := texture.get_pixel(8, 8)
    var right := texture.get_pixel(9, 8)
    _check(left.g > 0.0 and left.r == 0.0
        and left.b == 0.0 and left.a == 0.0,
        "Холодная область показывает только снег")
    _check(mid.r > 0.0 and mid.g > 0.0 and mid.a > 0.0
        and mid.b == 0.0, "Пограничная область показывает мокрый снег")
    _check(right.r > 0.0 and right.b > 0.0 and right.g == 0.0
        and right.a == 0.0, "Тёплая гроза локализует град в своём фронте")
    for emitter in [rain, snow, wet, hail, splashes, drift]:
        var material := emitter.draw_pass_1.material as ShaderMaterial
        _check(bool(material.get_shader_parameter("use_map")),
            "Маска локальных осадков подключена к каждому виду")

    var original_world := JSON.stringify(world.to_data())
    var original_climate := JSON.stringify(climate.to_data())
    var original_hydro := JSON.stringify(hydro.to_data())
    fx.sync_world(climate, world, Vector2(18, 10), 55.0)
    fx.apply_snapshot(states["hail"], Vector2(18, 10), 0.0, 44.0, 1729)
    _check(original_world == JSON.stringify(world.to_data())
        and original_climate == JSON.stringify(climate.to_data())
        and original_hydro == JSON.stringify(hydro.to_data()),
        "Камерные эффекты не меняют карту, климат и воду")
    _check(fixed_nodes == fx.get_child_count(),
        "Камера не размножает частицы и узлы")
    root.remove_child(fx)
    fx.free()


func _run() -> void:
    # Один сценарий проверяет полный первоначальный перечень
    # осадков 11.1 и ограничения физики, а не новые Issues.
    var states := _test_classification()
    var world := Map.new(Config.new(32, 24, 1729, 8, 16))
    var hydro := Hydrology.new(world)
    hydro.rebuild()
    var climate := Climate.new(world, hydro)
    climate.rebuild()
    climate.set_day(1)
    _test_emitters(states, world, climate, hydro)
    if not failures.is_empty():
        for reason in failures:
            printerr("Этап 11.1: ", reason)
        quit(1)
        return
    print("Этап 11.1: все типы осадков, климат и бюджет — успешно")
    quit(0)


func _initialize() -> void:
    # В SceneTree готова среда для выделения GPU-эмиттеров.
    call_deferred("_run")
