extends SceneTree
## Серия генераций: геометрические центры, строительные участки и ресурсы.
## Без игровой экономики, государств и утверждённого масштаба метра.

const Config = preload("res://scripts/world_config.gd")
const Map = preload("res://scripts/world_map.gd")
const Hydro = preload("res://scripts/hydrology.gd")
const Surface = preload("res://scripts/surface.gd")
const Climate = preload("res://scripts/climate.gd")
const Nature = preload("res://scripts/nature_registry.gd")
const Scenario = preload("res://scripts/world_spatial_scenario.gd")
const Envelope = preload("res://scripts/world_settlement_envelope.gd")
const Mature = preload("res://scripts/world_mature_capacity_audit.gd")
const Geography = preload("res://scripts/world_geography_audit.gd")
const Selection = preload("res://scripts/world_seed_selection.gd")

const OUTPUT := "res://tests/world-spatial-seeds-10.json"


static func _options() -> Dictionary:
    var options := {
        "samples": 2, "width": 96, "height": 80,
        "seed_start": 1729, "radius": 12, "profile": ""
    }
    for argument in OS.get_cmdline_user_args():
        if not argument.begins_with("--") or not argument.contains("="):
            continue
        var parts := argument.substr(2).split("=", false, 1)
        if parts.size() != 2 or not options.has(parts[0]):
            continue
        if parts[0] == "profile":
            options["profile"] = parts[1]
        elif parts[1].is_valid_int():
            options[parts[0]] = int(parts[1])
    if str(options["profile"]) != "":
        var chosen := Envelope.profile(str(options["profile"]))
        if not chosen.is_empty():
            options["radius"] = chosen["radius"]
    return options


static func _valid(options: Dictionary) -> bool:
    if str(options["profile"]) != "" \
            and Envelope.profile(str(options["profile"])).is_empty():
        return false
    return int(options["samples"]) >= 1 \
        and int(options["samples"]) <= 500 \
        and int(options["width"]) >= 64 \
        and int(options["width"]) <= 1024 \
        and int(options["height"]) >= 64 \
        and int(options["height"]) <= 768 \
        and int(options["radius"]) >= 6 \
        and int(options["radius"]) <= 40


static func _sample(world_seed: int, width: int,
        height: int, radius: int, profile: Dictionary) -> Dictionary:
    var started := Time.get_ticks_usec()
    var world := Map.new(Config.new(width, height, world_seed))
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

    var geographic: Dictionary = Geography.report(world, hydro)
    var scenario: Dictionary = Scenario.report(
        world, hydro, surface, nature, radius)
    var trial: Dictionary = scenario["trial"]
    var centers := 0
    var complete_groups := 0
    var valid: bool = trial["states"].size() == 6
    for state in trial["states"]:
        var sites: Array = state["centers"]
        var routes: Array = state["resource_routes"]
        centers += sites.size()
        complete_groups += int(sites.size() == 5)
        if routes.size() != sites.size() or sites.size() > 5:
            valid = false
    valid = valid and centers == int(trial["assigned_centers"])
    valid = valid and complete_groups == int(trial["full_states"])
    valid = valid and bool(trial["resource_route_checked"])
    valid = valid and (complete_groups == 6) \
        == bool(trial["trial_30_centers_found"])

    var mature_fit := 0
    var mature_groups := 0
    var unique_wood := 0
    var unique_stones := 0
    var neutral_land := 0
    var states_with_both_resources := 0
    var min_state_buildable := 0
    if not profile.is_empty():
        var audit: Dictionary = Mature.report(
            world, hydro, surface, nature, scenario, profile)
        mature_fit = int(audit["hypothetical_mature_centers"])
        mature_groups = int(
            audit["states_with_five_hypothetical_mature_centers"])
        neutral_land = int(
            audit["remaining_walkable_outside_test_influences"])
        valid = valid and int(audit["selected_center_count"]) == centers
        valid = valid and mature_fit <= centers and mature_groups <= 6
        var first_state := true
        for state in audit["state_territory_proxy"]["states"]:
            unique_wood += int(state["wood_units"])
            unique_stones += int(state["boulders"])
            if int(state["wood_units"]) > 0 and int(state["boulders"]) > 0:
                states_with_both_resources += 1
            if first_state:
                min_state_buildable = int(state["buildable_cells"])
                first_state = false
            else:
                min_state_buildable = mini(
                    min_state_buildable, int(state["buildable_cells"]))
    var components: Array = scenario["largest_walkable_components"]
    var largest := 0
    if not components.is_empty():
        largest = int(components[0])
    var walkable: int = scenario["land"]["walkable"]
    var share := float(largest) / float(maxi(walkable, 1))
    var archetype := "смешанная суша"
    if share >= 0.8:
        archetype = "связная суша"
    elif share <= 0.4:
        archetype = "островная суша"
    return {
        "seed": world_seed, "radius": radius,
        "geography_heuristic": archetype,
        "geography_archetype": geographic["archetype"],
        "geography_metrics": geographic,
        "largest_walkable_share": snappedf(share, 0.001),
        "water_share": snappedf(1.0 - float(scenario["land"]["dry"])
            / float(width * height), 0.001),
        "dry": scenario["land"]["dry"],
        "walkable": walkable,
        "buildable": scenario["land"]["buildable"],
        "candidates": scenario["candidate_count"],
        "centers": centers, "complete_groups": complete_groups,
        "six_starts": bool(trial["six_starts_found"]),
        "thirty_sites": bool(trial["trial_30_centers_found"]),
        "starts_with_wood_route": int(trial["starts_with_reachable_wood"]),
        "starts_with_boulder_route": int(trial["starts_with_reachable_boulders"]),
        "starts_with_both_routes": int(trial["starts_with_both_resources"]),
        "hypothetical_mature_sites": mature_fit,
        "states_with_five_hypothetical_mature_sites": mature_groups,
        "buildable_profile_checked": not profile.is_empty(),
        "walkable_land_outside_center_influence": neutral_land,
        "unique_provisional_territory_wood": unique_wood,
        "unique_provisional_territory_boulders": unique_stones,
        "states_with_both_territory_resources": states_with_both_resources,
        "minimum_state_buildable_cells": min_state_buildable,
        "invariants_valid": valid,
        "duration_ms": snappedf(
            float(Time.get_ticks_usec() - started) / 1000.0, 0.001)
    }


func _run() -> void:
    var options: Dictionary = _options()
    if not _valid(options):
        push_error("Неверные параметры пространственной выборки")
        quit(1)
        return
    var count: int = options["samples"]
    var radius: int = options["radius"]
    var profile := Envelope.for_radius(radius)
    if str(options["profile"]) != "":
        profile = Envelope.profile(str(options["profile"]))
    var rows: Array[Dictionary] = []
    var failures: Array[int] = []
    var full := 0
    var starts := 0
    var stocked := 0
    var mature := 0
    var geography := {}
    for index in range(count):
        var world_seed: int = int(options["seed_start"]) + index * 73
        var row: Dictionary = _sample(world_seed, int(options["width"]),
            int(options["height"]), radius, profile)
        rows.append(row)
        full += int(row["thirty_sites"])
        starts += int(row["six_starts"])
        stocked += int(int(row["starts_with_both_routes"]) == 6)
        mature += int(int(row["states_with_five_hypothetical_mature_sites"]) == 6)
        var archetype: String = row["geography_heuristic"]
        geography[archetype] = int(geography.get(archetype, 0)) + 1
        if not bool(row["invariants_valid"]):
            failures.append(world_seed)
        if index % 10 == 0:
            print("Пространственный аудит: ", index + 1, " / ", count)

    var result := {
        "stage": "10.0", "options": options,
        "samples": count, "seed_step": 73,
        "thirty_geometric_sites_found": full,
        "six_initial_sites_found": starts,
        "six_starts_with_both_resources": stocked,
        "six_territories_with_five_hypothetical_mature_sites": mature,
        "geography_heuristic_counts": geography,
        "seed_selection": Selection.summarize(rows),
        "profile_assumptions": profile,
        "mature_settlement_capacity_proven": false,
        "geographic_archetypes_controlled": false,
        "full_world_capacity_confirmed": false,
        "failures": failures, "rows": rows
    }
    var file := FileAccess.open(OUTPUT, FileAccess.WRITE)
    if file == null:
        push_error("Не удалось сохранить пространственную выборку")
        quit(1)
        return
    file.store_string(JSON.stringify(result, "  ") + "\n")
    file.close()
    if not failures.is_empty():
        push_error("Многосидовая пространственная проверка нарушила инварианты")
        quit(1)
        return
    print("Этап 10.0: проверено ", count, " seed, отчёт готов")
    quit(0)


func _initialize() -> void:
    call_deferred("_run")
