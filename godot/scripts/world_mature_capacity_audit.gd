extends RefCounted
## Географический аудит развитых поселений без строительства и ИИ.
## Макеты зданий — измерительные допущения; физические данные не меняются.

const Scenario = preload("res://scripts/world_spatial_scenario.gd")
const Envelope = preload("res://scripts/world_settlement_envelope.gd")
const DIRECTIONS := [
    Vector2i(1, 0), Vector2i(-1, 0),
    Vector2i(0, 1), Vector2i(0, -1)
]


static func _within(cell: Vector2i, center: Vector2i, radius: int) -> bool:
    return absi(cell.x - center.x) + absi(cell.y - center.y) <= radius


static func _local_index(x: int, y: int, x0: int, y0: int,
        side: int) -> int:
    return (y - y0) * side + x - x0


static func _reachable(buildable: PackedByteArray,
        walkable: PackedByteArray, width: int, height: int,
        center: Vector2i, radius: int) -> Dictionary:
    var side := radius * 2 + 1
    var x0 := center.x - radius
    var y0 := center.y - radius
    var marked := PackedByteArray()
    marked.resize(side * side)
    var queue: Array[Vector2i] = [center]
    var steps: Array[int] = [0]
    var cursor := 0
    marked[_local_index(center.x, center.y, x0, y0, side)] = 1
    var walkable_count := 0
    var buildable_count := 0
    while cursor < queue.size():
        var cell: Vector2i = queue[cursor]
        var step_count: int = steps[cursor]
        cursor += 1
        var index := cell.y * width + cell.x
        walkable_count += 1
        if buildable[index] != 0:
            buildable_count += 1
        if step_count >= radius * 4:
            continue
        for direction in DIRECTIONS:
            var neighbor: Vector2i = cell + direction
            if neighbor.x < 0 or neighbor.y < 0 \
                    or neighbor.x >= width or neighbor.y >= height:
                continue
            if not _within(neighbor, center, radius):
                continue
            var local := _local_index(neighbor.x, neighbor.y, x0, y0, side)
            if marked[local] != 0:
                continue
            if walkable[neighbor.y * width + neighbor.x] == 0:
                continue
            marked[local] = 1
            queue.append(neighbor)
            steps.append(step_count + 1)
    return {
        "mask": marked, "x0": x0, "y0": y0, "side": side,
        "walkable": walkable_count, "buildable": buildable_count
    }


static func _fits_lot(cell: Vector2i, width_cells: int, height_cells: int,
        width: int, height: int, center: Vector2i, radius: int,
        buildable: PackedByteArray, reachable: Dictionary,
        occupied: PackedByteArray) -> bool:
    var x0: int = reachable["x0"]
    var y0: int = reachable["y0"]
    var side: int = reachable["side"]
    for dy in range(height_cells):
        for dx in range(width_cells):
            var here := cell + Vector2i(dx, dy)
            if here.x < 0 or here.y < 0 \
                    or here.x >= width or here.y >= height:
                return false
            if not _within(here, center, radius):
                return false
            var local := _local_index(here.x, here.y, x0, y0, side)
            if occupied[local] != 0 or reachable["mask"][local] == 0:
                return false
            if buildable[here.y * width + here.x] == 0:
                return false
    return true


static func _occupy_lot(cell: Vector2i, width_cells: int, height_cells: int,
        reachable: Dictionary, occupied: PackedByteArray) -> void:
    var x0: int = reachable["x0"]
    var y0: int = reachable["y0"]
    var side: int = reachable["side"]
    for dy in range(height_cells):
        for dx in range(width_cells):
            occupied[_local_index(cell.x + dx, cell.y + dy,
                x0, y0, side)] = 1


static func _pack_lots(buildable: PackedByteArray,
        width: int, height: int, center: Vector2i,
        profile: Dictionary, reachable: Dictionary) -> Dictionary:
    var radius: int = profile["radius"]
    var occupied := PackedByteArray()
    occupied.resize(int(reachable["side"]) * int(reachable["side"]))
    var placed := {}
    var missing := {}
    var occupied_cells := 0
    for plot in profile["building_plots"]:
        var kind: String = plot["kind"]
        var needed: int = plot["count"]
        var plot_width: int = plot["width"]
        var plot_height: int = plot["height"]
        var count := 0
        if kind == "центр":
            if _fits_lot(center, plot_width, plot_height,
                    width, height, center, radius,
                    buildable, reachable, occupied):
                _occupy_lot(center, plot_width, plot_height,
                    reachable, occupied)
                count = 1
        else:
            for y in range(center.y - radius,
                    center.y + radius - plot_height + 2):
                if count == needed:
                    break
                for x in range(center.x - radius,
                        center.x + radius - plot_width + 2):
                    if count == needed:
                        break
                    var cell := Vector2i(x, y)
                    if not _fits_lot(cell, plot_width, plot_height,
                            width, height, center, radius,
                            buildable, reachable, occupied):
                        continue
                    _occupy_lot(cell, plot_width, plot_height,
                        reachable, occupied)
                    count += 1
        placed[kind] = count
        missing[kind] = needed - count
        occupied_cells += count * plot_width * plot_height
    var accessible: int = reachable["walkable"]
    var buildable_accessible: int = reachable["buildable"]
    var leftover_buildable := buildable_accessible - occupied_cells
    var free_walkable := accessible - occupied_cells
    var packed := true
    for amount in missing.values():
        if int(amount) != 0:
            packed = false
            break
    var budget_ok := leftover_buildable >= int(profile["yard_cells"]) \
        and free_walkable >= int(profile["road_cells"]) \
        + int(profile["free_cells"]) + int(profile["yard_cells"])
    return {
        "center": [center.x, center.y],
        "reachable_walkable_cells": accessible,
        "reachable_buildable_cells": buildable_accessible,
        "packed_lots": placed, "missing_lots": missing,
        "packed_footprint_cells": occupied_cells,
        "building_plan_fit": packed,
        "infrastructure_area_fit": budget_ok,
        "hypothetical_mature_fit": packed and budget_ok,
        "road_network_constructed": false
    }


static func _path_lengths(walkable: PackedByteArray,
        width: int, height: int, positions: Array,
        max_steps: int) -> Array[int]:
    var result: Array[int] = []
    for ignored in positions:
        result.append(-1)
    if positions.is_empty():
        return result
    var start := Vector2i(int(positions[0][0]), int(positions[0][1]))
    var start_index := start.y * width + start.x
    if walkable[start_index] == 0:
        return result
    var distance := PackedInt32Array()
    distance.resize(walkable.size())
    distance.fill(-1)
    distance[start_index] = 0
    var queue: Array[int] = [start_index]
    var cursor := 0
    while cursor < queue.size():
        var index: int = queue[cursor]
        cursor += 1
        var steps: int = distance[index]
        if steps >= max_steps:
            continue
        var x := index % width
        var y := floori(float(index) / float(width))
        for direction in DIRECTIONS:
            var nx: int = x + direction.x
            var ny: int = y + direction.y
            if nx < 0 or ny < 0 or nx >= width or ny >= height:
                continue
            var neighbor := ny * width + nx
            if distance[neighbor] != -1 or walkable[neighbor] == 0:
                continue
            distance[neighbor] = steps + 1
            queue.append(neighbor)
    for i in range(positions.size()):
        var point: Array = positions[i]
        result[i] = distance[int(point[1]) * width + int(point[0])]
    return result


static func _ownership(walkable: PackedByteArray,
        buildable: PackedByteArray, width: int, height: int,
        states: Array, nature: RefCounted) -> Dictionary:
    # Географические зоны влияния: кратчайший путь от шести стартов.
    # Это НЕ политические границы и не генерация государств.
    var owner := PackedInt32Array()
    owner.resize(walkable.size())
    owner.fill(-1)
    var queue: Array[int] = []
    var summaries := []
    for state in states:
        summaries.append({
            "state": state["state"], "walkable_cells": 0,
            "buildable_cells": 0, "wood_units": 0,
            "boulders": 0
        })
        if state["centers"].is_empty():
            continue
        var start: Array = state["centers"][0]
        var index := int(start[1]) * width + int(start[0])
        if walkable[index] == 0:
            continue
        owner[index] = summaries.size() - 1
        queue.append(index)
    var cursor := 0
    while cursor < queue.size():
        var index: int = queue[cursor]
        cursor += 1
        var x := index % width
        var y := floori(float(index) / float(width))
        var state_id: int = owner[index]
        for direction in DIRECTIONS:
            var nx: int = x + direction.x
            var ny: int = y + direction.y
            if nx < 0 or ny < 0 or nx >= width or ny >= height:
                continue
            var next := ny * width + nx
            if walkable[next] == 0 or owner[next] != -1:
                continue
            owner[next] = state_id
            queue.append(next)
    var unassigned := 0
    var frontiers := 0
    for index in range(owner.size()):
        if walkable[index] == 0:
            continue
        var state_id: int = owner[index]
        if state_id < 0:
            unassigned += 1
            continue
        summaries[state_id]["walkable_cells"] += 1
        if buildable[index] != 0:
            summaries[state_id]["buildable_cells"] += 1
        var x := index % width
        var y := floori(float(index) / float(width))
        if x + 1 < width and owner[index + 1] >= 0 \
                and owner[index + 1] != state_id:
            frontiers += 1
        if y + 1 < height and owner[index + width] >= 0 \
                and owner[index + width] != state_id:
            frontiers += 1
    if nature != null:
        for obj in nature.to_data().get("objects", []):
            var x: int = obj[3]
            var y: int = obj[4]
            if x < 0 or y < 0 or x >= width or y >= height:
                continue
            var state_id: int = owner[y * width + x]
            if state_id < 0:
                continue
            if obj[1] == "дерево":
                summaries[state_id]["wood_units"] += int(obj[7]) + int(obj[8])
            elif obj[1] == "валун":
                summaries[state_id]["boulders"] += 1
    return {
        "states": summaries,
        "unassigned_walkable_cells": unassigned,
        "shared_frontier_edges": frontiers,
        "exclusive_resource_ownership": true,
        "political_borders_approved": false
    }


static func report(world: RefCounted, hydro: RefCounted,
        surface: RefCounted, nature: RefCounted,
        scenario: Dictionary, profile: Dictionary) -> Dictionary:
    var width: int = world.config.width
    var height: int = world.config.height
    var radius: int = profile["radius"]
    var terrain: Dictionary = Scenario._terrain(world, hydro, surface)
    var walkable: PackedByteArray = terrain["walkable"]
    var buildable: PackedByteArray = terrain["buildable"]
    var states: Array = scenario["trial"]["states"]
    var trials := []
    var complete_groups := 0
    var complete_mature_centers := 0
    var sites := 0
    var consumed_walkable := 0
    for state in states:
        var centers: Array = state["centers"]
        var plots := []
        var distances: Array[int] = _path_lengths(
            walkable, width, height, centers, radius * 24)
        var all_paths := not centers.is_empty()
        var mature_count := 0
        for i in range(centers.size()):
            var raw: Array = centers[i]
            var point := Vector2i(int(raw[0]), int(raw[1]))
            var reachable: Dictionary = _reachable(
                buildable, walkable, width, height, point, radius)
            var measured: Dictionary = _pack_lots(
                buildable, width, height, point, profile, reachable)
            measured["road_distance_from_start"] = distances[i]
            measured["walkable_intercenter_route"] = distances[i] >= 0
            if distances[i] < 0:
                all_paths = false
            mature_count += int(measured["hypothetical_mature_fit"])
            consumed_walkable += int(reachable["walkable"])
            plots.append(measured)
            sites += 1
        complete_mature_centers += mature_count
        if mature_count == 5 and centers.size() == 5 and all_paths:
            complete_groups += 1
        trials.append({
            "state": state["state"], "centers": plots,
            "mature_fit_centers": mature_count,
            "intercenter_routes_walkable": all_paths,
            "fully_fits_hypothetical_mature_profile":
                mature_count == 5 and centers.size() == 5 and all_paths
        })
    var ownership: Dictionary = _ownership(
        walkable, buildable, width, height, states, nature)
    return {
        "profile": profile,
        "selected_center_count": sites,
        "hypothetical_mature_centers": complete_mature_centers,
        "states_with_five_hypothetical_mature_centers": complete_groups,
        "all_30_hypothetical_mature_fit": complete_groups == 6,
        "remaining_walkable_outside_test_influences": maxi(0,
            int(terrain["counts"]["walkable"]) - consumed_walkable),
        "state_territory_proxy": ownership,
        "states": trials,
        "assumptions_approved": false,
        "full_game_capacity_confirmed": false
    }
