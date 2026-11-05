extends SceneTree
## Проверки профилей без генерации карты, экономики и визуальных сцен.

const Envelope = preload("res://scripts/world_settlement_envelope.gd")
const Audit = preload("res://scripts/world_mature_capacity_audit.gd")
const Scenario = preload("res://scripts/world_spatial_scenario.gd")


static func _test_profiles() -> bool:
    var last_radius := 0
    for name in Envelope.names():
        var profile: Dictionary = Envelope.profile(name)
        var radius: int = profile["radius"]
        if radius <= last_radius or profile["approved"]:
            return false
        last_radius = radius
        var expected := 4 + int(profile["houses"]) * 4 \
            + int(profile["workshops"]) * 9 \
            + int(profile["fields"]) * 16
        if int(profile["building_footprint_cells"]) != expected:
            return false
        if int(profile["required_buildable_cells"]) != expected \
                + int(profile["yard_cells"]):
            return false
        if int(profile["required_walkable_cells"]) \
                > int(profile["diamond_influence_cells"]):
            return false
        if Envelope.for_radius(radius)["name"] != name:
            return false
    if not Envelope.profile("unknown").is_empty():
        return false
    var sizes: Dictionary = Envelope.scale_candidates(0.9)
    if sizes["meters_per_cell_approved"] \
            or sizes["mature_settlement_profile_approved"] \
            or sizes["alternatives"].size() != 3:
        return false
    var previous_area := 0.0
    for alternative in sizes["alternatives"]:
        var meters: float = alternative["meters_per_cell"]
        var profiles: Array = alternative["mature_settlement_areas"]
        var maps: Array = alternative["map_dimensions"]
        if profiles.size() != 3 or maps.size() != 4:
            return false
        for measured in profiles:
            var source: Dictionary = Envelope.profile(measured["profile"])
            var cell_area := meters * meters
            if not is_equal_approx(float(measured["required_buildable_m2"]),
                    int(source["required_buildable_cells"]) * cell_area):
                return false
            if not is_equal_approx(float(measured["required_walkable_m2"]),
                    int(source["required_walkable_cells"]) * cell_area):
                return false
            if not is_equal_approx(float(measured["thirty_influence_hectares"]),
                    snappedf(int(source["diamond_influence_cells"])
                    * cell_area * 30.0 / 10000.0, 0.0001)):
                return false
        var area: float = maps[2]["area_km2"]
        if area <= previous_area or maps[2]["cells"] != [768, 576]:
            return false
        previous_area = area
    return true


static func _test_foundations() -> bool:
    var width := 96
    var height := 96
    var walkable := PackedByteArray()
    var buildable := PackedByteArray()
    walkable.resize(width * height)
    buildable.resize(width * height)
    walkable.fill(1)
    buildable.fill(1)
    var center := Vector2i(48, 48)
    var profile: Dictionary = Envelope.profile("compact")
    var free: Dictionary = Audit._reachable(
        buildable, walkable, width, height, center, profile["radius"])
    var packed: Dictionary = Audit._pack_lots(
        buildable, width, height, center, profile, free)
    if not packed["building_plan_fit"] \
            or int(packed["packed_footprint_cells"]) \
            != int(profile["building_footprint_cells"]):
        return false
    # Фундамент не может оказаться в воде даже при просторном районе.
    buildable[center.y * width + center.x] = 0
    var broken: Dictionary = Audit._pack_lots(
        buildable, width, height, center, profile, free)
    if int(broken["packed_lots"]["центр"]) != 0:
        return false
    # Река разрывает сухопутную связность при свободных клетках по прямой.
    for y in range(height):
        walkable[y * width + 50] = 0
    var reduced: Dictionary = Audit._reachable(
        buildable, walkable, width, height, center, profile["radius"])
    return int(reduced["walkable"]) < int(free["walkable"])


# Дома не должны занимать единственный участок 4×4, нужный под поле.
# Старый порядок (дома перед полями) проваливал эту примерку.
static func _test_large_plots_first() -> bool:
    var width := 48
    var height := 48
    var center := Vector2i(24, 24)
    var walkable := PackedByteArray()
    var buildable := PackedByteArray()
    walkable.resize(width * height)
    buildable.resize(width * height)
    walkable.fill(1)
    var squares := [
        {"cell": center, "size": 2},
        {"cell": center + Vector2i(-3, -5), "size": 4},
        {"cell": center + Vector2i(3, -2), "size": 2},
        {"cell": center + Vector2i(3, 1), "size": 2}
    ]
    for square in squares:
        var start: Vector2i = square["cell"]
        var side: int = square["size"]
        for dy in range(side):
            for dx in range(side):
                buildable[(start.y + dy) * width + start.x + dx] = 1
    var profile := {
        "radius": 8, "yard_cells": 0, "road_cells": 0, "free_cells": 0,
        "required_buildable_cells": 28, "required_walkable_cells": 28,
        "building_plots": [
            {"kind": "центр", "count": 1, "width": 2, "height": 2},
            {"kind": "дома", "count": 2, "width": 2, "height": 2},
            {"kind": "поля", "count": 1, "width": 4, "height": 4}
        ]
    }
    if not Audit.site_fits(buildable, walkable, width, height,
            center, profile):
        return false
    var accessible: Dictionary = Audit._reachable(
        buildable, walkable, width, height, center, 8)
    var lots: Dictionary = Audit._pack_lots(
        buildable, width, height, center, profile, accessible)
    if not lots["hypothetical_mature_fit"] \
            or lots["packed_lots"]["поля"] != 1 \
            or lots["packed_lots"]["дома"] != 2:
        return false
    # Уничтожение одной клетки единственного поля делает план невозможным.
    buildable[(center.y - 5) * width + center.x - 3] = 0
    return not Audit.site_fits(
        buildable, walkable, width, height, center, profile)


static func _test_mature_candidates() -> bool:
    var width := 72
    var height := 72
    var walkable := PackedByteArray()
    var buildable := PackedByteArray()
    walkable.resize(width * height)
    buildable.resize(width * height)
    walkable.fill(1)
    buildable.fill(1)
    var acceptable := Vector2i(40, 40)
    var blocked := Vector2i(20, 20)
    buildable[blocked.y * width + blocked.x] = 0
    var candidates: Array[Dictionary] = [
        {"cell": blocked}, {"cell": acceptable}
    ]
    var profile: Dictionary = Envelope.profile("balanced")
    var validator := Callable(Audit, "site_fits").bind(profile)
    var filtered := Scenario._viable_candidates(
        candidates, buildable, walkable, width, height, validator)
    if filtered.size() != 1 or filtered[0]["cell"] != acceptable:
        return false
    return Scenario._viable_candidates(candidates, buildable, walkable,
        width, height, Callable()).size() == 2


static func _test_paths_and_territories() -> bool:
    var width := 12
    var height := 8
    var walkable := PackedByteArray()
    var buildable := PackedByteArray()
    walkable.resize(width * height)
    buildable.resize(width * height)
    walkable.fill(1)
    buildable.fill(1)
    for y in range(height):
        walkable[y * width + 6] = 0
        buildable[y * width + 6] = 0
    var centers: Array = [[2, 4], [9, 4]]
    var disconnected: Array[int] = Audit._path_lengths(
        walkable, width, height, centers, 100)
    if disconnected.size() != 2 or disconnected[0] != 0 \
            or disconnected[1] != -1:
        return false
    var states: Array = [
        {"state": 1, "centers": [[2, 4]]},
        {"state": 2, "centers": [[9, 4]]}
    ]
    var proxy: Dictionary = Audit._ownership(
        walkable, buildable, width, height, states, null)
    var assigned := 0
    for state in proxy["states"]:
        assigned += int(state["walkable_cells"])
    if assigned + int(proxy["unassigned_walkable_cells"]) \
            != width * height - height:
        return false
    if int(proxy["shared_frontier_edges"]) != 0:
        return false
    walkable[4 * width + 6] = 1
    var connected: Array[int] = Audit._path_lengths(
        walkable, width, height, centers, 100)
    return connected[1] > 0


static func _test_real_routes() -> bool:
    var width := 40
    var height := 24
    var walkable := PackedByteArray()
    walkable.resize(width * height)
    walkable.fill(1)
    # Разрыв суши: на карте соседний центр близко, но дорога отсутствует.
    for y in range(height):
        walkable[y * width + 20] = 0
    var anchor := {
        "cell": Vector2i(12, 12), "component": 0, "coverage": 1.0
    }
    var candidates: Array[Dictionary] = [
        {"cell": Vector2i(25, 12), "component": 0, "coverage": 1.0},
        {"cell": Vector2i(0, 12), "component": 0, "coverage": 0.9}
    ]
    var occupied: Array[Dictionary] = [
        {"cell": Vector2i(12, 12), "state": 0, "slot": 0}
    ]
    var distances := Scenario.walking_distances(
        walkable, width, height, Vector2i(12, 12), 96)
    if distances[12 * width + 25] != -1:
        return false
    var found: Dictionary = Scenario._next_center(
        candidates, anchor, occupied, 4, 0, distances, width)
    if found.is_empty() or found["cell"] != Vector2i(0, 12):
        return false
    # После появления сухопутного прохода центр становится доступным.
    walkable[12 * width + 20] = 1
    var reopened := Scenario.walking_distances(
        walkable, width, height, Vector2i(12, 12), 96)
    return reopened[12 * width + 25] > 0


func _initialize() -> void:
    if not _test_profiles() or not _test_foundations() \
            or not _test_large_plots_first() \
            or not _test_mature_candidates() \
            or not _test_paths_and_territories() or not _test_real_routes():
        push_error("Этап 10.0.2–10.0.4: инвариант пространственного профиля")
        quit(1)
        return
    print("Этап 10.0: профили и территории проверены успешно")
    quit(0)
