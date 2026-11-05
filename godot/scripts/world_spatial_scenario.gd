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
        "wood_cells": wood, "stone_cells": stones,
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


# Оцениваем доступность природного сырья по реальным шагам по суше.
# Река, заболоченное препятствие и горный обрыв не считаются проходом.
# Радиус маршрута — гипотеза аудита, а не будущая навигация работников.
static func route_stock(walkable: PackedByteArray,
        wood: PackedInt32Array, stones: PackedInt32Array,
        width: int, height: int, start: Vector2i,
        max_steps: int) -> Dictionary:
    var result := {
        "walkable_cells": 0, "wood_units": 0,
        "boulders": 0, "max_steps": maxi(max_steps, 0)
    }
    if width <= 0 or height <= 0 or max_steps < 0:
        return result
    var size := width * height
    if walkable.size() != size or wood.size() != size \
            or stones.size() != size:
        return result
    if start.x < 0 or start.y < 0 or start.x >= width \
            or start.y >= height:
        return result
    var first := start.y * width + start.x
    if walkable[first] == 0:
        return result
    var visited := PackedByteArray()
    visited.resize(size)
    var queue: Array[int] = [first]
    var depths: Array[int] = [0]
    visited[first] = 1
    var cursor := 0
    while cursor < queue.size():
        var index: int = queue[cursor]
        var depth: int = depths[cursor]
        cursor += 1
        result["walkable_cells"] += 1
        result["wood_units"] += int(wood[index])
        result["boulders"] += int(stones[index])
        if depth == max_steps:
            continue
        var x := index % width
        var y := floori(float(index) / float(width))
        for direction in DIRECTIONS:
            var nx: int = x + direction.x
            var ny: int = y + direction.y
            if nx < 0 or ny < 0 or nx >= width or ny >= height:
                continue
            var neighbor: int = ny * width + nx
            if visited[neighbor] != 0 or walkable[neighbor] == 0:
                continue
            visited[neighbor] = 1
            queue.append(neighbor)
            depths.append(depth + 1)
    return result


# Расстояния только по проходимой суше, без мостов и переходов через воду.
# Единый предел маршрута для выбора и итоговой проверки поселений.
static func walking_distances(walkable: PackedByteArray, width: int,
        height: int, start: Vector2i, max_steps: int) -> PackedInt32Array:
    var distance := PackedInt32Array()
    distance.resize(walkable.size())
    distance.fill(-1)
    if width <= 0 or height <= 0 or walkable.size() != width * height \
            or start.x < 0 or start.y < 0 or start.x >= width \
            or start.y >= height or max_steps < 0:
        return distance
    var start_index := start.y * width + start.x
    if walkable[start_index] == 0:
        return distance
    var queue: Array[int] = [start_index]
    distance[start_index] = 0
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
            var next_index := ny * width + nx
            if distance[next_index] >= 0 or walkable[next_index] == 0:
                continue
            distance[next_index] = steps + 1
            queue.append(next_index)
    return distance


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


# Единый строгий фильтр применяем ДО подбора государств и маршрутов.
# Полученная функция выполняет ту же проверку, что финальный аудит.
static func _viable_candidates(candidates: Array[Dictionary],
        buildable: PackedByteArray, walkable: PackedByteArray,
        width: int, height: int,
        site_validator: Callable) -> Array[Dictionary]:
    if not site_validator.is_valid():
        return candidates
    var viable: Array[Dictionary] = []
    for candidate in candidates:
        if bool(site_validator.call(buildable, walkable, width, height,
                candidate["cell"])):
            viable.append(candidate)
    return viable


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
        component_counts: Dictionary, excluded: Dictionary = {}) -> Dictionary:
    var best: Dictionary = {}
    var best_score := -INF
    for candidate in candidates:
        var point: Vector2i = candidate["cell"]
        if excluded.has(point):
            continue
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
        radius: int, state: int, path_distances: PackedInt32Array,
        width: int) -> Dictionary:
    var best: Dictionary = {}
    var best_score := INF
    var center: Vector2i = anchor["cell"]
    for candidate in candidates:
        if int(candidate["component"]) != int(anchor["component"]):
            continue
        if not _fits(candidate, occupied, radius, state):
            continue
        var point: Vector2i = candidate["cell"]
        var index := point.y * width + point.x
        # Близость на карте не заменяет реальный пеший маршрут.
        if path_distances[index] < 0:
            continue
        var distance: float = Vector2(point).distance_to(Vector2(center))
        if distance > float(radius * 12):
            continue
        var score: float = distance - float(candidate["coverage"]) * 2.0
        if score < best_score:
            best = candidate
            best_score = score
    return best

static func _layout(candidates: Array[Dictionary],
        components: Dictionary, resources: Dictionary,
        walkable: PackedByteArray, width: int, height: int,
        radius: int) -> Dictionary:
    var counts := {}
    for candidate in candidates:
        var component: int = candidate["component"]
        counts[component] = int(counts.get(component, 0)) + 1
    var occupied: Array[Dictionary] = []
    var states: Array[Dictionary] = []
    var starts_with_reachable_wood := 0
    var starts_with_reachable_boulders := 0
    var starts_with_both := 0
    var evaluated_anchors := 0

    for state in range(STATES):
        var excluded := {}
        var choice: Dictionary = {}
        var best_score := -1
        # Первый подходящий по геометрии центр не обязательно имеет
        # сухопутные дороги и доступные ресурсы. Проверяем альтернативы.
        for attempt in range(12):
            var anchor: Dictionary = _anchor(
                candidates, occupied, radius, state, counts, excluded)
            if anchor.is_empty():
                break
            excluded[anchor["cell"]] = true
            evaluated_anchors += 1
            var center: Vector2i = anchor["cell"]
            var path_distances := walking_distances(walkable, width,
                height, center, radius * 24)
            var trial_occupied: Array[Dictionary] = occupied.duplicate()
            trial_occupied.append({
                "cell": center, "state": state, "slot": 0})
            var group: Array[Vector2i] = [center]
            for slot in range(1, CENTERS_PER_STATE):
                var next: Dictionary = _next_center(
                    candidates, anchor, trial_occupied, radius,
                    state, path_distances, width)
                if next.is_empty():
                    break
                var next_center: Vector2i = next["cell"]
                group.append(next_center)
                trial_occupied.append({
                    "cell": next_center, "state": state, "slot": slot})
            var origin_stock: Dictionary = route_stock(
                walkable, resources["wood_cells"],
                resources["stone_cells"], width, height, center,
                radius * 3)
            var both_resources: bool = int(origin_stock["wood_units"]) > 0 \
                and int(origin_stock["boulders"]) > 0
            var score := group.size() * 100 + int(both_resources) * 10 \
                + int(int(origin_stock["wood_units"]) > 0) \
                + int(int(origin_stock["boulders"]) > 0)
            if score > best_score:
                best_score = score
                choice = {
                    "anchor": anchor, "group": group,
                    "start_route": origin_stock}
            if group.size() == CENTERS_PER_STATE and both_resources:
                break

        if choice.is_empty():
            states.append({"state": state + 1, "centers": [],
                "connected_component": -1, "component_wood_units": 0,
                "component_boulders": 0, "nearby_wood_units": 0,
                "nearby_boulders": 0, "resource_routes": [],
                "anchor_attempts": excluded.size(),
                "center_routes_validated": false})
            continue

        var selected: Dictionary = choice["anchor"]
        var group: Array[Vector2i] = choice["group"]
        var positions: Array = []
        var resource_routes: Array[Dictionary] = []
        for slot in range(group.size()):
            var cell: Vector2i = group[slot]
            positions.append([cell.x, cell.y])
            occupied.append({"cell": cell, "state": state, "slot": slot})
            if slot == 0:
                resource_routes.append(choice["start_route"])
            else:
                resource_routes.append(route_stock(
                    walkable, resources["wood_cells"],
                    resources["stone_cells"], width, height,
                    cell, radius * 3))
        if int(resource_routes[0]["wood_units"]) > 0:
            starts_with_reachable_wood += 1
        if int(resource_routes[0]["boulders"]) > 0:
            starts_with_reachable_boulders += 1
        if int(resource_routes[0]["wood_units"]) > 0 \
                and int(resource_routes[0]["boulders"]) > 0:
            starts_with_both += 1
        var component: int = selected["component"]
        states.append({
            "state": state + 1, "centers": positions,
            "connected_component": component,
            "component_walkable_cells": components["sizes"][component],
            "component_wood_units": resources["connected_wood"][component],
            "component_boulders": resources["connected_stones"][component],
            "nearby_wood_units": selected["nearby_wood"],
            "nearby_boulders": selected["nearby_boulders"],
            "resource_routes": resource_routes,
            "anchor_attempts": excluded.size(),
            "center_routes_validated": true
        })
    var full_states := 0
    for state in states:
        if state["centers"].size() == CENTERS_PER_STATE:
            full_states += 1
    return {
        "states": states, "assigned_centers": occupied.size(),
        "full_states": full_states,
        "evaluated_anchors": evaluated_anchors,
        "route_aware_layout": true,
        "resource_route_checked": true,
        "starts_with_reachable_wood": starts_with_reachable_wood,
        "starts_with_reachable_boulders": starts_with_reachable_boulders,
        "starts_with_both_resources": starts_with_both,
        "six_starts_found": states.filter(
            func(item: Dictionary) -> bool:
                return not item["centers"].is_empty()).size() == STATES,
        "trial_30_centers_found": full_states == STATES,
        "maximal_map_certified": false
    }

static func report(world: RefCounted, hydro: RefCounted,
        surface: RefCounted, nature: RefCounted, radius: int,
        site_validator: Callable = Callable()) -> Dictionary:
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
    var viable: Array[Dictionary] = _viable_candidates(
        candidates, terrain["buildable"], terrain["walkable"],
        width, height, site_validator)
    var trial := _layout(viable, connected, resources,
        terrain["walkable"], width, height, radius)
    var sorted_sizes := component_sizes.duplicate()
    sorted_sizes.sort()
    sorted_sizes.reverse()
    return {
        "radius_hypothesis_cells": radius,
        "old_headquarters_footprint_cells": [FOUNDATION, FOUNDATION],
        "candidate_count": candidates.size(),
        "mature_candidate_count": viable.size(),
        "rejected_immature_candidates": candidates.size() - viable.size(),
        "mature_preselection_checked": site_validator.is_valid(),
        "land": terrain["counts"],
        "walkable_components": component_sizes.size(),
        "largest_walkable_components": sorted_sizes.slice(0, 8),
        "trial": trial,
        "limits": {
            "land_connectivity": "четырёхсвязная суша без мостов",
            "candidate_spacing": "2 радиуса + 3; между государствами + 9",
            "coverage": "не менее 75% пригодных клеток внутри ромба",
            "resource_reach": "3 радиуса по координатам (предварительный фильтр)",
            "route_reach": "3 радиуса реального обхода по четырёхсвязной суше",
            "route_limits": "переходы/порты добычи и будущие мосты не моделируются",
            "no_approved_mature_settlement_radius": true
        }
    }
