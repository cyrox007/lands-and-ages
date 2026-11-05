extends RefCounted
## Измерительные профили поселения, не утверждённые правила игры.
## Начальные 2×2 и радиус 9 — исторический контракт; уровни 2–4 пока графика.

const START_FOOTPRINT := [2, 2]
const START_RADIUS := 9
const TARGET_STATES := 6
const TARGET_CENTERS_PER_STATE := 5

const ENVELOPES := {
    "compact": {
        "radius": 12, "houses": 12, "workshops": 4,
        "fields": 2, "yard_cells": 16, "road_cells": 30,
        "free_cells": 20
    },
    "balanced": {
        "radius": 16, "houses": 20, "workshops": 8,
        "fields": 3, "yard_cells": 24, "road_cells": 54,
        "free_cells": 56
    },
    "spacious": {
        "radius": 20, "houses": 30, "workshops": 12,
        "fields": 5, "yard_cells": 40, "road_cells": 88,
        "free_cells": 80
    }
}

const OBJECT_METERS := {
    "human_height": 1.75,
    "road_width": 4.0,
    "reference_adult_tree_height": 18.0
}
const IMPORTED_TREE_HEIGHT_SCENE := 3.4


static func names() -> Array[String]:
    return ["compact", "balanced", "spacious"]


static func profile(name: String) -> Dictionary:
    if not ENVELOPES.has(name):
        return {}
    var result: Dictionary = ENVELOPES[name].duplicate(true)
    result["name"] = name
    result["approved"] = false
    result["headquarters_footprint"] = START_FOOTPRINT.duplicate()
    result["building_plots"] = [
        {"kind": "центр", "count": 1, "width": 2, "height": 2},
        {"kind": "дома", "count": result["houses"], "width": 2, "height": 2},
        {"kind": "мастерские", "count": result["workshops"],
            "width": 3, "height": 3},
        {"kind": "поля", "count": result["fields"], "width": 4, "height": 4}
    ]
    var footprint_cells := 4 + 4 * int(result["houses"]) \
        + 9 * int(result["workshops"]) + 16 * int(result["fields"])
    var buildable_budget := footprint_cells + int(result["yard_cells"])
    result["building_footprint_cells"] = footprint_cells
    result["required_buildable_cells"] = buildable_budget
    result["required_walkable_cells"] = buildable_budget \
        + int(result["road_cells"]) + int(result["free_cells"])
    result["diamond_influence_cells"] = 1 + 2 * int(result["radius"]) \
        * (int(result["radius"]) + 1)
    return result


static func for_radius(radius: int) -> Dictionary:
    for name in names():
        var chosen := profile(name)
        if int(chosen["radius"]) == radius:
            return chosen
    return {}


static func scale_candidates(height_scale: float) -> Dictionary:
    var result := []
    for meters_per_cell in [2.0, 3.0, 4.0]:
        var cell_area := meters_per_cell * meters_per_cell
        var settlements: Array[Dictionary] = []
        for name in names():
            var measured: Dictionary = profile(name)
            settlements.append({
                "profile": name,
                "radius_meters": int(measured["radius"]) * meters_per_cell,
                "influence_hectares": snappedf(
                    int(measured["diamond_influence_cells"]) * cell_area
                    / 10000.0, 0.0001),
                "building_footprints_m2": int(
                    measured["building_footprint_cells"]) * cell_area,
                "required_buildable_m2": int(
                    measured["required_buildable_cells"]) * cell_area,
                "required_walkable_m2": int(
                    measured["required_walkable_cells"]) * cell_area,
                "thirty_influence_hectares": snappedf(
                    int(measured["diamond_influence_cells"]) * cell_area
                    * TARGET_STATES * TARGET_CENTERS_PER_STATE
                    / 10000.0, 0.0001),
                "house_plot_side_meters": 2.0 * meters_per_cell,
                "workshop_plot_side_meters": 3.0 * meters_per_cell,
                "field_plot_side_meters": 4.0 * meters_per_cell,
                "area_is_hypothetical": true
            })
        var maps: Array[Dictionary] = []
        for dimensions in [[256, 192], [512, 384],
                [768, 576], [1024, 768]]:
            var width: int = dimensions[0]
            var height: int = dimensions[1]
            maps.append({
                "cells": [width, height],
                "width_km": snappedf(
                    width * meters_per_cell / 1000.0, 0.001),
                "height_km": snappedf(
                    height * meters_per_cell / 1000.0, 0.001),
                "area_km2": snappedf(
                    width * height * cell_area / 1000000.0, 0.0001)
            })
        result.append({
            "mature_settlement_areas": settlements,
            "map_dimensions": maps,
            "meters_per_cell": meters_per_cell,
            "human_height_scene_units": snappedf(
                OBJECT_METERS["human_height"] / meters_per_cell, 0.001),
            "road_width_scene_units": snappedf(
                OBJECT_METERS["road_width"] / meters_per_cell, 0.001),
            "historic_headquarters_meters": [2.0 * meters_per_cell,
                2.0 * meters_per_cell],
            "imported_tree_height_meters_unscaled": snappedf(
                IMPORTED_TREE_HEIGHT_SCENE * meters_per_cell, 0.01),
            "reference_adult_tree_scale_multiplier": snappedf(
                OBJECT_METERS["reference_adult_tree_height"] \
                / (IMPORTED_TREE_HEIGHT_SCENE * meters_per_cell), 0.001),
            "height_scale_requires_physical_calibration": true,
            "not_approved": true
        })
    return {
        "horizontal_scene_units_per_cell": 1.0,
        "scene_vertical_multiplier": height_scale,
        "historic_headquarters_footprint_cells": START_FOOTPRINT,
        "historic_influence_radius_cells": START_RADIUS,
        "height_reference_meters": OBJECT_METERS.duplicate(),
        "profiles": names(),
        "meters_per_cell_approved": false,
        "mature_settlement_profile_approved": false,
        "alternatives": result
    }
