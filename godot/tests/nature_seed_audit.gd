extends SceneTree
## Этап 10.7: проверка множества географий без запуска графики и старой экономики.

const Config = preload("res://scripts/world_config.gd")
const Map = preload("res://scripts/world_map.gd")
const Hydro = preload("res://scripts/hydrology.gd")
const Surface = preload("res://scripts/surface.gd")
const Climate = preload("res://scripts/climate.gd")
const Nature = preload("res://scripts/nature_registry.gd")
const Capacity = preload("res://scripts/world_capacity_audit.gd")

const REPORT_PATH := "res://tests/world-ecology-seeds-10.json"
const MAX_SAMPLES := 500


func _options() -> Dictionary:
    var result := {
        "samples": 4, "width": 96, "height": 80, "seed_start": 1729
    }
    for argument in OS.get_cmdline_user_args():
        if not argument.begins_with("--") or not argument.contains("="):
            continue
        var parts := argument.substr(2).split("=", false, 1)
        if parts.size() != 2 or not result.has(parts[0]):
            continue
        if not parts[1].is_valid_int():
            continue
        result[parts[0]] = int(parts[1])
    result["samples"] = clampi(int(result["samples"]), 1, MAX_SAMPLES)
    result["width"] = clampi(int(result["width"]), 32, 256)
    result["height"] = clampi(int(result["height"]), 32, 256)
    return result


func _prepare(world_seed: int, width: int, height: int) -> Dictionary:
    var world := Map.new(Config.new(width, height, world_seed, 16, 32))
    var hydro := Hydro.new(world)
    hydro.rebuild()
    var surface := Surface.new(world, hydro)
    surface.rebuild()
    var climate := Climate.new(world, hydro)
    climate.rebuild()
    climate.set_day(1)
    surface.advance_climate_day(climate)
    hydro.apply_rainfall_map(surface.runoff_map())
    var nature := Nature.new(world, hydro, surface, climate)
    nature.generate()
    return {
        "world": world, "hydro": hydro,
        "surface": surface, "climate": climate, "nature": nature
    }


func _check_objects(models: Dictionary) -> Array[String]:
    var errors: Array[String] = []
    var world: RefCounted = models["world"]
    var hydro: RefCounted = models["hydro"]
    var nature: RefCounted = models["nature"]
    var ids := {}
    var chunks: Vector2i = world.config.chunk_count()
    for cy in range(chunks.y):
        for cx in range(chunks.x):
            for item in nature.objects_in_chunk(Vector2i(cx, cy)):
                var id: int = item["id"]
                if ids.has(id):
                    errors.append("Дублируется ID %d" % id)
                ids[id] = true
                var cell := Vector2i(int(item["x"]), int(item["y"]))
                if not world.config.contains_cell(cell):
                    errors.append("Объект за границей: %d" % id)
                    continue
                var index: int = hydro.cell_index(cell)
                if hydro.has_water(index):
                    errors.append("Объект находится в воде: %d" % id)
                if not is_finite(world.height_at(
                        Vector2(float(cell.x) + 0.5, float(cell.y) + 0.5))):
                    errors.append("Некорректная высота: %d" % id)
                if int(item["wood_units"]) < 0 or int(item["fallen_wood"]) < 0:
                    errors.append("Отрицательный запас: %d" % id)
    if ids.size() != nature.count():
        errors.append("Пространственный индекс не совпадает с реестром")
    return errors


func _check_repeat(models: Dictionary) -> Array[String]:
    var errors: Array[String] = []
    var world: RefCounted = models["world"]
    var nature: RefCounted = models["nature"]
    var repeat: Dictionary = _prepare(world.config.world_seed,
        world.config.width, world.config.height)
    if nature.to_data() != repeat["nature"].to_data():
        errors.append("Повторная генерация отличается при одинаковом seed")

    var restored := Nature.new(world, models["hydro"],
        models["surface"], models["climate"])
    if not restored.load_data(nature.to_data()) \
            or restored.to_data() != nature.to_data():
        errors.append("Сохранение и загрузка природного слоя различаются")

    # Игровая физика проверяется без привязки к рендеру и частоте кадров.
    for day in range(2, 10):
        models["climate"].set_day(day)
        repeat["climate"].set_day(day)
        nature.advance_day(day)
        repeat["nature"].advance_day(day)
    if nature.to_data() != repeat["nature"].to_data():
        errors.append("Суточная экосистема недетерминирована")
    return errors


static func _distribution(entries: Array[Dictionary],
        key: String) -> Dictionary:
    var values: Array[float] = []
    for entry in entries:
        values.append(float(entry[key]))
    if values.is_empty():
        return {}
    values.sort()
    var total := 0.0
    for value in values:
        total += value
    var p95 := clampi(ceili(float(values.size()) * 0.95) - 1,
        0, values.size() - 1)
    return {
        "min": values.front(), "max": values.back(),
        "mean": snappedf(total / float(values.size()), 0.001),
        "p95": values[p95]
    }


func _run() -> void:
    var options: Dictionary = _options()
    var samples: int = options["samples"]
    var width: int = options["width"]
    var height: int = options["height"]
    var start_seed: int = options["seed_start"]
    var entries: Array[Dictionary] = []
    var failures: Array[String] = []

    for index in range(samples):
        var world_seed: int = start_seed + 73 * index
        var started := Time.get_ticks_usec()
        var models: Dictionary = _prepare(world_seed, width, height)
        var errors: Array[String] = _check_objects(models)
        var capacity: Dictionary = Capacity.report(models["world"],
            models["hydro"], models["surface"], models["nature"], 9)
        var elapsed_ms := float(Time.get_ticks_usec() - started) / 1000.0
        if index % 10 == 0:
            errors.append_array(_check_repeat(models))
        var row := {
            "seed": world_seed, "cells": int(capacity["cells"]),
            "sea_cells": int(capacity["ocean"]),
            "dry_cells": int(capacity["dry"]),
            "developable_cells": int(capacity["developable"]),
            "settlements_r9": int(capacity["greedy_nonoverlapping_centers"]),
            "natural_objects": int(capacity["natural_objects"]),
            "wood_units": int(capacity["wood_units"]),
            "generation_ms": snappedf(elapsed_ms, 0.01),
            "errors": errors
        }
        entries.append(row)
        for error in errors:
            failures.append("seed %d: %s" % [world_seed, error])

    var report := {
        "stage": "10.7",
        "purpose": "Детерминизм и географический охват, не замер FPS",
        "dimensions": [width, height],
        "samples": samples,
        "seed_start": start_seed,
        "seed_step": 73,
        "hard_errors": failures,
        "statistics": {
            "sea_cells": _distribution(entries, "sea_cells"),
            "developable_cells": _distribution(entries, "developable_cells"),
            "settlements_r9": _distribution(entries, "settlements_r9"),
            "natural_objects": _distribution(entries, "natural_objects"),
            "wood_units": _distribution(entries, "wood_units"),
            "generation_ms": _distribution(entries, "generation_ms")
        },
        "radii_approved": false,
        "meter_per_cell_approved": false,
        "full_six_country_simulation": false,
        "cases": entries
    }
    var file := FileAccess.open(REPORT_PATH, FileAccess.WRITE)
    if file == null:
        push_error("Не удалось записать отчёт многократной генерации")
        quit(1)
        return
    file.store_string(JSON.stringify(report, "  ") + "\n")
    file.close()
    if not failures.is_empty():
        for issue in failures.slice(0, 20):
            push_error(issue)
        print("Этап 10.7: ошибок ", failures.size())
        quit(1)
        return
    print("Этап 10.7: проверено ", samples, " seed, ошибок нет")
    quit(0)


func _initialize() -> void:
    call_deferred("_run")
