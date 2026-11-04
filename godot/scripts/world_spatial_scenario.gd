extends RefCounted
## Этап 10.0: географическая примерка, не генератор государств.
## Природная область, государство и фактическая застройка не смешиваются.

const STATES := 6
const CENTERS_PER_STATE := 5
const FOUNDATION := 2
const DIRECTIONS := [
    Vector2i(1, 0), Vector2i(-1, 0),
    Vector2i(0, 1), Vector2i(0, -1)
]


static func _terrain(world: RefCounted, hydro: RefCounted,
        surface: RefCounted) -> Dictionary:
    var width: int = world.config.width
    var height: int = world.config.height
    var walkable := PackedByteArray()
    var buildable := PackedByteArray()
    walkable.resize(width * height)
    buildable.resize(width * height)
    var counts := {"dry": 0, "walkable": 0, "buildable": 0,
        "flooded_dry": 0}
    for y in range(height):
        for x in range(width):
            var index := y * width + x
            if hydro.has_water(index):
                continue
            counts["dry"] += 1
            if hydro.flooded_at(index):
                counts["flooded_dry"] += 1
                continue
            var normal: Vector3 = world.normal_at(Vector2i(x, y))
            var waterlogging: float = surface.waterlogging_at_index(index)
            if normal.y < 0.76 or waterlogging > 0.85:
                continue
            walkable[index] = 1
            counts["walkable"] += 1
            if normal.y < 0.88 or waterlogging > 0.70 \
                    or surface.soil_depth_at_index(index) < 0.12:
                continue
            buildable[index] = 1
            counts["buildable"] += 1
    return {"walkable": walkable, "buildable": buildable,
        "counts": counts}


static func _connected(walkable: PackedByteArray,
        width: int, height: int) -> Dictionary:
    var labels := PackedInt32Array()
    labels.resize(walkable.size())
    labels.fill(-1)
    var sizes: Array[int] = []
    for index in range(walkable.size()):
        if walkable[index] == 0 or labels[index] != -1:
            continue
        var component: int = sizes.size()
        var queue: Array[int] = [index]
        labels[index] = component
        var cursor := 0
        while cursor < queue.size():
            var current: int = queue[cursor]
            cursor += 1
            var x: int = current % width
            var y: int = floori(float(current) / float(width))
            for step in DIRECTIONS:
                var nx: int = x + step.x
                var ny: int = y + step.y
                if nx < 0 or ny < 0 or nx >= width or ny >= height:
                    continue
                var next: int = ny * width + nx
                if walkable[next] == 0 or labels[next] != -1:
                    continue
                labels[next] = component
                queue.append(next)
        sizes.append(queue.size())
    return {"labels": labels, "sizes": sizes}


static func _resources(nature: RefCounted, labels: PackedInt32Array,
        component_count: int, width: int, height: int) -> Dictionary:
    var wood := PackedInt32Array()
    var stones := PackedInt32Array()
    wood.resize(width * height)
    stones.resize(width * height)
    var connected_wood: Array[int] = []
    var connected_stones: Array[int] = []
    for component in range(component_count):
        connected_wood.append(0)
        connected_stones.append(0)
    if nature != null:
        for object in nature.to_data().get("objects", []):
            var x := int(object[3])
            var y := int(object[4])
            var index := y * width + x
            var component: int = labels[index]
            if component < 0:
                continue
            if object[1] == "дерево":
                var stock: int = int(object[7]) + int(object[8])
                wood[index] += stock
                connected_wood[component] += stock
            elif object[1] == "валун":
                stones[index] += 1
                connected_stones[component] += 1
    return {
        "wood": _integral(wood, width, height),
        "stones": _integral(stones, width, height),
        "connected_wood": connected_wood,
        "connected_stones": connected_stones
    }


static func _integral(values: PackedInt32Array,
        width: int, height: int) -> PackedInt64Array:
    var result := PackedInt64Array()
    var step := width + 1
    result.resize(step * (height + 1))
    for y in range(height):
        var row_total := 0
        for x in range(width):
            row_total += int(values[y * width + x])
            result[(y + 1) * step + x + 1] = (
                result[y * step + x + 1] + row_total)
    return result


static func _local_stock(prefix: PackedInt64Array, width: int,
        height: int, cell: Vector2i, reach: int) -> int:
    var x0 := clampi(cell.x - reach, 0, width)
    var x1 := clampi(cell.x + reach + 1, 0, width)
    var y0 := clampi(cell.y - reach, 0, height)
    var y1 := clampi(cell.y + reach + 1, 0, height)
    var step := width + 1
    return int(prefix[y1 * step + x1] - prefix[y0 * step + x1]
        - prefix[y1 * step + x0] + prefix[y0 * step + x0])


static func _candidates(buildable: PackedByteArray,
        labels: PackedInt32Array, resources: Dictionary,
        width: int, height: int, radius: int) -> Array[Dictionary]:
    var offsets: Array[Vector2i] = []
    for dy in range(-radius, radius + 1):
        for dx in range(-radius, radius + 1):
            if absi(dx) + absi(dy) <= radius:
                offsets.append(Vector2i(dx, dy))
    var result: Array[Dictionary] = []
    var stride := maxi(2, radius)
    for y in range(radius, height - radius - FOUNDATION, stride):
        for x in range(radius, width - radius - FOUNDATION, stride):
            var index := y * width + x
            var component: int = labels[index]
            if component < 0:
                continue
            # Только проверенный фундамент 2x2; будущие здания здесь не строим.
            var foundation_ok := true
            for dy in range(FOUNDATION):
                for dx in range(FOUNDATION):
                    if buildable[(y + dy) * width + x + dx] == 0:
                        foundation_ok = false
            if not foundation_ok:
                continue
            var suitable := 0
            for offset in offsets:
                var neighbor := (y + offset.y) * width + x + offset.x
                if buildable[neighbor] != 0 and labels[neighbor] == component:
                    suitable += 1
            var coverage: float = float(suitable) / float(offsets.size())
            if coverage < 0.75:
                continue
            var cell := Vector2i(x, y)
            var reach := radius * 3
            result.append({
                "cell": cell, "component": component,
                "coverage": snappedf(coverage, 0.0001),
                # Близость ресурса не доказывает наличие сухопутного маршрута.
                "nearby_wood": _local_stock(resources["wood"],
                    width, height, cell, reach),
                "nearby_boulders": _local_stock(resources["stones"],
                    width, height, cell, reach)
            })
    return result


static func _fits(candidate: Dictionary, occupied: Array[Dictionary],
        radius: int, state: int) -> bool:
    var cell: Vector2i = candidate["cell"]
    for taken in occupied:
        # Между разными предполагаемыми государствами оставлен буфер.
        var separation := 2 * radius + (
            3 if int(taken["state"]) == state else 9)
        if cell.distance_squared_to(taken["cell"]) < separation * separation:
            return false
    return true


static func _anchor(candidates: Array[Dictionary],
        occupied: Array[Dictionary], radius: int, state: int,
        component_counts: Dictionary) -> Dictionary:
    var best: Dictionary = {}
    var best_score := -INF
    for candidate in candidates:
        var component: int = candidate["component"]
        if int(component_counts.get(component, 0)) < CENTERS_PER_STATE:
            continue
        if not _fits(candidate, occupied, radius, state):
            continue
        var score: float = float(candidate["coverage"]) * 20.0
        if int(candidate["nearby_wood"]) > 0:
            score += 6.0
        if int(candidate["nearby_boulders"]) > 0:
            score += 6.0
        var nearest_anchor := INF
        for taken in occupied:
            if int(taken["slot"]) != 0:
                continue
            var distance: float = Vector2(
                candidate["cell"]).distance_to(Vector2(taken["cell"]))
            nearest_anchor = minf(nearest_anchor, distance)
        if nearest_anchor != INF:
            score += minf(nearest_anchor, 500.0) * 0.45
        if score > best_score:
            best = candidate
            best_score = score
    return best


static func _next_center(candidates: Array[Dictionary],
        anchor: Dictionary, occupied: Array[Dictionary],
        radius: int, state: int) -> Dictionary:
    var best: Dictionary = {}
    var best_score := INF
    var center: Vector2i = anchor["cell"]
    for candidate in candidates:
        if int(candidate["component"]) != int(anchor["component"]):
            continue
        if not _fits(candidate, occupied, radius, state):
            continue
        var distance: float = Vector2(
            candidate["cell"]).distance_to(Vector2(center))
        if distance > float(radius * 12):
            continue
        var score: float = distance - float(candidate["coverage"]) * 2.0
        if score < best_score:
            best = candidate
            best_score = score
    return best


static func _layout(candidates: Array[Dictionary],
        components: Dictionary, resources: Dictionary,
        radius: int) -> Dictionary:
    var counts := {}
    for candidate in candidates:
        var component: int = candidate["component"]
        counts[component] = int(counts.get(component, 0)) + 1
    var occupied: Array[Dictionary] = []
    var states: Array[Dictionary] = []
    for state in range(STATES):
        var anchor: Dictionary = _anchor(
            candidates, occupied, radius, state, counts)
        if anchor.is_empty():
            states.append({"state": state + 1, "centers": [],
                "connected_component": -1, "component_wood_units": 0,
                "component_boulders": 0, "nearby_wood_units": 0,
                "nearby_boulders": 0})
            continue
        var group: Array[Vector2i] = [anchor["cell"]]
        occupied.append({"cell": anchor["cell"], "state": state, "slot": 0})
        for slot in range(1, CENTERS_PER_STATE):
            var next: Dictionary = _next_center(
                candidates, anchor, occupied, radius, state)
            if next.is_empty():
                break
            group.append(next["cell"])
            occupied.append({"cell": next["cell"], "state": state,
                "slot": slot})
        var positions: Array = []
        for cell in group:
            positions.append([cell.x, cell.y])
        var component: int = anchor["component"]
        states.append({
            "state": state + 1, "centers": positions,
            "connected_component": component,
            "component_walkable_cells": components["sizes"][component],
            "component_wood_units": resources["connected_wood"][component],
            "component_boulders": resources["connected_stones"][component],
            "nearby_wood_units": anchor["nearby_wood"],
            "nearby_boulders": anchor["nearby_boulders"]
        })
    var full_states := 0
    for state in states:
        if state["centers"].size() == CENTERS_PER_STATE:
            full_states += 1
    return {
        "states": states, "assigned_centers": occupied.size(),
        "full_states": full_states,
        "six_starts_found": states.filter(
            func(state: Dictionary) -> bool:
                return not state["centers"].is_empty()).size() == STATES,
        "trial_30_centers_found": full_states == STATES,
        # Даже 30 геометрических мест не доказывают размеры зрелых центров.
        "maximal_map_certified": false
    }


static func report(world: RefCounted, hydro: RefCounted,
        surface: RefCounted, nature: RefCounted, radius: int) -> Dictionary:
    hydro.ensure_ready()
    surface.ensure_ready()
    var width: int = world.config.width
    var height: int = world.config.height
    var terrain: Dictionary = _terrain(world, hydro, surface)
    var connected: Dictionary = _connected(
        terrain["walkable"], width, height)
    var component_sizes: Array[int] = connected["sizes"]
    var resources: Dictionary = _resources(nature, connected["labels"],
        component_sizes.size(), width, height)
    var candidates: Array[Dictionary] = _candidates(
        terrain["buildable"], connected["labels"], resources,
        width, height, radius)
    var trial := _layout(candidates, connected, resources, radius)
    var sorted_sizes := component_sizes.duplicate()
    sorted_sizes.sort()
    sorted_sizes.reverse()
    return {
        "radius_hypothesis_cells": radius,
        "old_headquarters_footprint_cells": [FOUNDATION, FOUNDATION],
        "candidate_count": candidates.size(),
        "land": terrain["counts"],
        "walkable_components": component_sizes.size(),
        "largest_walkable_components": sorted_sizes.slice(0, 8),
        "trial": trial,
        "limits": {
            "land_connectivity": "четырёхсвязная суша без мостов",
            "candidate_spacing": "2 радиуса + 3; между государствами + 9",
            "coverage": "не менее 75% пригодных клеток внутри ромба",
            "resource_reach": "3 радиуса по координатам, путь не проверен",
            "no_approved_mature_settlement_radius": true
        }
    }
