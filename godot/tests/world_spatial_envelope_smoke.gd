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
    return not sizes["meters_per_cell_approved"] \
        and not sizes["mature_settlement_profile_approved"] \
        and sizes["alternatives"].size() == 3


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
            or not _test_paths_and_territories() or not _test_real_routes():
        push_error("Этап 10.0.2–10.0.4: инвариант пространственного профиля")
        quit(1)
        return
    print("Этап 10.0: профили и территории проверены успешно")
    quit(0)
