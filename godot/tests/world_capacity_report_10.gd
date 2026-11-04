extends SceneTree
## Этап 10.0: измерение пространственного эталона, без игровых государств.

const Config = preload("res://scripts/world_config.gd")
const Map = preload("res://scripts/world_map.gd")
const Hydro = preload("res://scripts/hydrology.gd")
const Surface = preload("res://scripts/surface.gd")
const Climate = preload("res://scripts/climate.gd")
const Nature = preload("res://scripts/nature_registry.gd")
const Capacity = preload("res://scripts/world_capacity_audit.gd")
const Scenario = preload("res://scripts/world_spatial_scenario.gd")
const REPORT_PATH := "res://tests/world-capacity-10.json"


static func _scale_hypotheses(height_scale: float) -> Dictionary:
    var proposals := []
    for meters_per_cell in [2.0, 3.0, 4.0]:
        proposals.append({
            "meters_per_cell": meters_per_cell,
            "human_1_75_m_scene_units": snappedf(
                1.75 / meters_per_cell, 0.001),
            "road_4_m_scene_units": snappedf(
                4.0 / meters_per_cell, 0.001),
            "pine_3_4_scene_units_in_meters": snappedf(
                3.4 * meters_per_cell, 0.01)
        })
    return {
        "horizontal_cell_in_scene_units": 1.0,
        "scene_vertical_height_multiplier": height_scale,
        "historic_headquarters_footprint_cells": [2, 2],
        "historic_initial_influence_radius_cells": 9,
        "meters_per_cell_approved": false,
        "mature_headquarters_radius_approved": false,
        "provisional_reference_only": true,
        "hypotheses": proposals
    }


static func _options() -> Dictionary:
    var result := {"width": 256, "height": 192, "seed": 1729}
    for argument in OS.get_cmdline_user_args():
        if not argument.begins_with("--") or not argument.contains("="):
            continue
        var pair := argument.substr(2).split("=", false, 1)
        if pair.size() != 2 or not result.has(pair[0]):
            continue
        if pair[1].is_valid_int():
            result[pair[0]] = int(pair[1])
    return result


static func _layout_valid(case: Dictionary, width: int, height: int) -> bool:
    var data: Dictionary = case["connected_six_state_trial"]["trial"]
    var radius: int = case["radius"]
    if data["states"].size() != 6:
        return false
    var seen: Array[Dictionary] = []
    var total := 0
    var full := 0
    for state in data["states"]:
        var points: Array = state["centers"]
        if points.size() > 5:
            return false
        if not points.is_empty() and int(state["connected_component"]) < 0:
            return false
        if points.size() == 5:
            full += 1
        for point in points:
            if point.size() != 2:
                return false
            var x := int(point[0])
            var y := int(point[1])
            if x < 0 or y < 0 or x >= width or y >= height:
                return false
            for other in seen:
                var buffer := 3 if int(other["state"]) == int(state["state"]) else 9
                var required := 2 * radius + buffer
                var dx := x - int(other["x"])
                var dy := y - int(other["y"])
                if dx * dx + dy * dy < required * required:
                    return false
            seen.append({"x": x, "y": y, "state": int(state["state"])})
            total += 1
    return total == int(data["assigned_centers"]) \
        and full == int(data["full_states"]) \
        and bool(data["trial_30_centers_found"]) == (full == 6)


func _run() -> void:
    var options: Dictionary = _options()
    var width: int = options["width"]
    var height: int = options["height"]
    if width < 64 or width > 1024 or height < 64 or height > 768:
        push_error("Размер проверки вне предусмотренного диапазона")
        quit(1)
        return
    var map := Map.new(Config.new(width, height, int(options["seed"])))
    var hydro := Hydro.new(map)
    hydro.rebuild()
    var surface := Surface.new(map, hydro)
    surface.rebuild()
    var climate := Climate.new(map, hydro)
    climate.rebuild()
    climate.set_day(1)
    surface.advance_climate_day(climate)
    hydro.apply_rainfall_map(surface.runoff_map())
    var nature := Nature.new(map, hydro, surface, climate)
    nature.generate()

    var cases := []
    var geometry_valid := true
    for radius in [9, 12, 16, 20]:
        var legacy: Dictionary = Capacity.report(
            map, hydro, surface, nature, radius)
        var trial: Dictionary = Scenario.report(
            map, hydro, surface, nature, radius)
        var trial_case := {"radius": radius,
            "legacy_capacity_estimate": legacy,
            "connected_six_state_trial": trial}
        geometry_valid = geometry_valid and _layout_valid(
            trial_case, width, height)
        cases.append(trial_case)

    # Повторный расчёт на том же seed не должен менять распределение.
    var repeated: Dictionary = Scenario.report(
        map, hydro, surface, nature, 9)
    var reproducible: bool = (
        repeated == cases[0]["connected_six_state_trial"])

    var result := {
        "stage": "10.0",
        "seed": map.config.world_seed,
        "size": [map.config.width, map.config.height],
        "goal": {"states": 6, "mature_centers": 30},
        "spatial_contract": _scale_hypotheses(map.config.height_scale),
        "reproducible": reproducible,
        "geometry_invariants_valid": geometry_valid,
        "experimental_only": true,
        "full_world_capacity_confirmed": false,
        "cases": cases
    }
    var file := FileAccess.open(REPORT_PATH, FileAccess.WRITE)
    if file == null:
        push_error("Не удалось записать отчёт о пространственном эталоне")
        quit(1)
        return
    file.store_string(JSON.stringify(result, "  ") + "\n")
    file.close()
    if not reproducible or not geometry_valid:
        push_error("Пространственный подбор нарушил инварианты")
        quit(1)
        return
    print("Этап 10.0: отчёт готов — ", REPORT_PATH)
    quit(0)


func _initialize() -> void:
    call_deferred("_run")
