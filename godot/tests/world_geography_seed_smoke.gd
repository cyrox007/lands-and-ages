extends SceneTree
## Синтетические географии и отказ при недостаточной вместимости.

const Geo = preload("res://scripts/world_geography_audit.gd")
const SelectSeed = preload("res://scripts/world_seed_selection.gd")


static func _water(width: int, height: int, flooded: bool) -> PackedByteArray:
    var mask := PackedByteArray()
    mask.resize(width * height)
    mask.fill(1 if flooded else 0)
    return mask


static func _land_rectangle(mask: PackedByteArray, width: int,
        start: Vector2i, extent: Vector2i) -> void:
    for y in range(start.y, start.y + extent.y):
        for x in range(start.x, start.x + extent.x):
            mask[y * width + x] = 0


static func _water_rectangle(mask: PackedByteArray, width: int,
        start: Vector2i, extent: Vector2i) -> void:
    for y in range(start.y, start.y + extent.y):
        for x in range(start.x, start.x + extent.x):
            mask[y * width + x] = 1


static func _test_geography() -> bool:
    var all_land := _water(30, 30, false)
    var continent: Dictionary = Geo.classify_mask(all_land, 30, 30)
    if continent["archetype"] != "материк" \
            or continent["land_components"] != 1:
        return false

    var islands := _water(32, 24, true)
    for x in [2, 12, 22]:
        _land_rectangle(islands, 32, Vector2i(x, 6), Vector2i(4, 5))
    var archipelago: Dictionary = Geo.classify_mask(islands, 32, 24)
    if archipelago["archetype"] != "архипелаг" \
            or int(archipelago["large_islands"]) != 3:
        return false

    var inland := _water(30, 30, false)
    _water_rectangle(inland, 30, Vector2i(9, 9), Vector2i(12, 12))
    var sea: Dictionary = Geo.classify_mask(inland, 30, 30)
    if sea["archetype"] != "внутреннее море" \
            or int(sea["largest_inland_water_cells"]) != 144:
        return false

    var coast := _water(40, 30, true)
    _land_rectangle(coast, 40, Vector2i(2, 18), Vector2i(36, 10))
    _land_rectangle(coast, 40, Vector2i(15, 3), Vector2i(6, 16))
    var peninsula: Dictionary = Geo.classify_mask(coast, 40, 30)
    if peninsula["archetype"] != "полуостров":
        return false

    var bad := _water(9, 9, false)
    return not Geo.classify_mask(bad, 10, 10)["valid"] \
        and Geo.classify_mask(inland, 30, 30) == sea


static func _candidate(world_seed: int, geography: String) -> Dictionary:
    return {
        "seed": world_seed,
        "geography_archetype": geography,
        "invariants_valid": true,
        "six_starts": true,
        "centers": 30,
        "hypothetical_mature_sites": 30,
        "states_with_five_hypothetical_mature_sites": 6,
        "starts_with_both_routes": 6,
        "states_with_both_territory_resources": 6,
        "walkable": 1000,
        "walkable_land_outside_center_influence": 200
    }


static func _test_selection() -> bool:
    var fine := _candidate(123, "материк")
    var good := _candidate(234, "архипелаг")
    var bad := _candidate(345, "полуостров")
    bad["centers"] = 25
    bad["hypothetical_mature_sites"] = 23
    bad["states_with_five_hypothetical_mature_sites"] = 4
    var missing := _candidate(456, "внутреннее море")
    missing["states_with_both_territory_resources"] = 5

    var rows: Array[Dictionary] = [bad, fine, missing, good]
    var found: Dictionary = SelectSeed.summarize(rows)
    if int(found["eligible"]) != 2 or int(found["rejected"]) != 2:
        return false
    if found["rejected_examples"].size() != 2 \
            or int(found["rejection_reason_counts"].get(
                "менее 30 геометрических центров", 0)) != 1:
        return false
    if found["best_overall"].size() != 2 \
            or int(found["best_overall"][0]["seed"]) != 123:
        return false
    if found["by_archetype"]["полуостров"]["eligible_seeds"] != 0:
        return false
    if not "не все государства вмещают пять проектных поселений" \
            in SelectSeed.reasons(bad):
        return false
    if not SelectSeed.reasons(fine).is_empty():
        return false
    var repeat: Dictionary = SelectSeed.summarize(rows)
    return repeat == found \
        and "внутреннее море" in found["missing_eligible_archetypes"]


func _initialize() -> void:
    if not _test_geography():
        push_error("Этап 10.0: ошибка географических архетипов")
        quit(1)
        return
    if not _test_selection():
        push_error("Этап 10.0: ошибка строгого отбора seed")
        quit(1)
        return
    print("Этап 10.0: географические архетипы и отбор seed проверены")
    quit(0)
