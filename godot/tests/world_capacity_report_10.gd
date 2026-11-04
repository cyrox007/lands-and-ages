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


func _run() -> void:
    var map := Map.new(Config.new())
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
    for radius in [9, 12, 16, 20]:
        var legacy: Dictionary = Capacity.report(
            map, hydro, surface, nature, radius)
        var trial: Dictionary = Scenario.report(
            map, hydro, surface, nature, radius)
        cases.append({"radius": radius,
            "legacy_capacity_estimate": legacy,
            "connected_six_state_trial": trial})

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
    if not reproducible:
        push_error("Пространственный подбор не воспроизводится")
        quit(1)
        return
    print("Этап 10.0: отчёт готов — ", REPORT_PATH)
    quit(0)


func _initialize() -> void:
    call_deferred("_run")
