extends SceneTree
## Этап 10.7: полный год природной симуляции с сохранениями и сменой вида.
## Headless-проверка не заменяет 30 минут игры на реальном устройстве.

const Config = preload("res://scripts/world_config.gd")
const Map = preload("res://scripts/world_map.gd")
const Hydro = preload("res://scripts/hydrology.gd")
const Surface = preload("res://scripts/surface.gd")
const Climate = preload("res://scripts/climate.gd")
const Nature = preload("res://scripts/nature_registry.gd")
const Weather = preload("res://scripts/weather_events.gd")
const Natural = preload("res://scripts/natural_processes.gd")
const Disasters = preload("res://scripts/natural_disasters.gd")
const Runner = preload("res://scripts/world_day_runner.gd")
const Save = preload("res://scripts/world_save.gd")
const Renderer = preload("res://scripts/nature_renderer.gd")

const REPORT_PATH := "res://tests/world-nature-long-run-10-7.json"
const FILE_PATH := "user://nature-long-run-10-7.json"
const CHECKPOINT := 24


func _options() -> Dictionary:
    var result := {"days": 96, "samples": 2, "seed_start": 1729}
    for argument in OS.get_cmdline_user_args():
        if not argument.begins_with("--") or not argument.contains("="):
            continue
        var pair := argument.substr(2).split("=", false, 1)
        if pair.size() != 2 or not result.has(pair[0]):
            continue
        if pair[1].is_valid_int():
            result[pair[0]] = int(pair[1])
    result["days"] = clampi(int(result["days"]), 1, 384)
    result["samples"] = clampi(int(result["samples"]), 1, 8)
    return result


func _prepare(world_seed: int) -> Dictionary:
    var world := Map.new(Config.new(64, 48, world_seed, 16, 32))
    var hydro := Hydro.new(world)
    hydro.rebuild()
    var surface := Surface.new(world, hydro)
    surface.rebuild()
    var climate := Climate.new(world, hydro)
    climate.rebuild()
    climate.set_day(1)
    surface.advance_climate_day(climate)
    hydro.apply_rainfall_map(surface.runoff_map())
    var weather := Weather.new(world, climate, surface, hydro)
    var natural := Natural.new(world, hydro, surface, climate)
    var disasters := Disasters.new(world, hydro, surface, climate)
    var nature := Nature.new(world, hydro, surface, climate)
    nature.generate()
    return {
        "world": world, "hydro": hydro, "surface": surface,
        "climate": climate, "weather": weather, "natural": natural,
        "disasters": disasters, "nature": nature,
        "runner": Runner.new(world, hydro, surface, climate,
            weather, natural, disasters, nature)
    }


static func _percentile(values: Array[float], portion: float) -> float:
    if values.is_empty():
        return 0.0
    values.sort()
    var index := clampi(ceili(float(values.size()) * portion) - 1,
        0, values.size() - 1)
    return snappedf(values[index], 0.001)


static func _invariants(state: Dictionary, day: int) -> Array[String]:
    var errors: Array[String] = []
    var climate: RefCounted = state["climate"]
    var nature: RefCounted = state["nature"]
    if climate.day != day or state["surface"].day != day \
            or nature.last_day != day:
        errors.append("Несогласованные даты климат/грунт/растения")
    var ids := {}
    for entry in nature.to_data()["objects"]:
        var id: int = int(entry[0])
        if ids.has(id):
            errors.append("Повторяется идентификатор объекта")
            break
        ids[id] = true
        if int(entry[5]) < 0 or int(entry[6]) < 0 \
                or int(entry[6]) > 1000 or int(entry[7]) < 0 \
                or int(entry[8]) < 0:
            errors.append("Недопустимый возраст, здоровье или древесина")
            break
    if ids.size() != nature.count():
        errors.append("Размер реестра и число идентификаторов различаются")
    return errors


static func _compare(reference: Dictionary, repeated: Dictionary,
        day: int) -> Array[String]:
    var errors: Array[String] = []
    var a: Dictionary = Save.capture(reference)
    var b: Dictionary = Save.capture(repeated)
    if a.is_empty() or b.is_empty():
        errors.append("Снимок после дня %d не создаётся" % day)
        return errors
    for key in ["world", "hydrology", "climate", "surface",
            "nature", "weather", "natural", "disasters"]:
        if a.get(key) != b.get(key):
            errors.append("Различается %s на дне %d" % [key, day])
    return errors


func _run_case(world_seed: int, days: int) -> Dictionary:
    var errors: Array[String] = []
    var reference := _prepare(world_seed)
    var initial: Dictionary = Save.capture(reference)
    if initial.is_empty():
        return {"seed": world_seed, "errors": ["Начальный снимок недоступен"]}
    var replay: Dictionary = Save.restore(initial)
    if replay.is_empty():
        return {"seed": world_seed, "errors": ["Начальная загрузка не удалась"]}
    var samples_ms: Array[float] = []
    var checkpoints: Array[int] = []
    var start_us := Time.get_ticks_usec()
    var object_start: int = reference["nature"].count()

    for next_day in range(2, days + 2):
        var begin := Time.get_ticks_usec()
        reference["runner"].run_day()
        samples_ms.append(float(Time.get_ticks_usec() - begin) / 1000.0)
        replay["runner"].run_day()
        if next_day % CHECKPOINT != 1 and next_day != days + 1:
            continue

        checkpoints.append(next_day)
        errors.append_array(_invariants(reference, next_day))
        errors.append_array(_invariants(replay, next_day))
        errors.append_array(_compare(reference, replay, next_day))

        # Графическая детализация и положение камеры не вправе
        # изменять деревья, грунты или сохранённые природные события.
        var before: Dictionary = Save.capture(reference)
        for detail in [0.12, 1.0]:
            var visual := Renderer.create_chunk(
                reference["world"], reference["nature"],
                Vector2i(1, 1), detail)
            visual.free()
        if before != Save.capture(reference):
            errors.append("Отрисовка изменила физику на дне %d" % next_day)

        # Проверяем фактическую запись JSON, а не только словарь в памяти.
        if next_day == 49:
            if not Save.write_file(replay, FILE_PATH):
                errors.append("Не удалось записать контрольное сохранение")
            else:
                var disk: Dictionary = Save.read_file(FILE_PATH)
                if disk.is_empty():
                    errors.append("Не удалось восстановить JSON с диска")
                else:
                    errors.append_array(_compare(reference, disk, next_day))
                    replay = disk

        var snapshot: Dictionary = Save.capture(replay)
        var json: Variant = JSON.parse_string(JSON.stringify(snapshot))
        if not (json is Dictionary):
            errors.append("Ошибка сериализации JSON на дне %d" % next_day)
            break
        var restored: Dictionary = Save.restore(json)
        if restored.is_empty():
            errors.append("Загрузка JSON не прошла на дне %d" % next_day)
            break
        errors.append_array(_compare(reference, restored, next_day))
        replay = restored
        if not errors.is_empty():
            break

    var path := ProjectSettings.globalize_path(FILE_PATH)
    if FileAccess.file_exists(FILE_PATH):
        DirAccess.remove_absolute(path)
    var duration_ms := float(Time.get_ticks_usec() - start_us) / 1000.0
    return {
        "seed": world_seed, "days_requested": days,
        "days_completed": int(reference["climate"].day) - 1,
        "checkpoints": checkpoints,
        "objects_before": object_start,
        "objects_after": reference["nature"].count(),
        "wood_units_final": reference["nature"].wood_total(),
        "simulation_ms_total": snappedf(duration_ms, 0.01),
        "day_ms_p50": _percentile(samples_ms.duplicate(), 0.50),
        "day_ms_p95": _percentile(samples_ms.duplicate(), 0.95),
        "day_ms_p99": _percentile(samples_ms.duplicate(), 0.99),
        "errors": errors
    }


func _run() -> void:
    var options := _options()
    var reports: Array[Dictionary] = []
    var failures: Array[String] = []
    for index in range(int(options["samples"])):
        var world_seed: int = int(options["seed_start"]) + index * 73
        var result: Dictionary = _run_case(world_seed, int(options["days"]))
        reports.append(result)
        for message in result["errors"]:
            failures.append("seed %d: %s" % [world_seed, message])

    var report := {
        "stage": "10.7",
        "kind": "Продолжительная суточная регрессия с восстановлением",
        "days_per_seed": options["days"],
        "samples": options["samples"],
        "measures_real_fps": false,
        "measures_android_gpu": false,
        "requires_device_qa": true,
        "hard_errors": failures,
        "cases": reports
    }
    var file := FileAccess.open(REPORT_PATH, FileAccess.WRITE)
    if file == null:
        push_error("Не удалось записать отчёт длительной регрессии")
        quit(1)
        return
    file.store_string(JSON.stringify(report, "  ") + "\n")
    file.close()
    if not failures.is_empty():
        for message in failures.slice(0, 20):
            push_error(message)
        quit(1)
        return
    print("Этап 10.7: ", options["days"], " суток на ",
        options["samples"], " seed, ошибок нет")
    quit(0)


func _initialize() -> void:
    call_deferred("_run")
