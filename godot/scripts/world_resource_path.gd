extends RefCounted
## Общие правила пешей доставки между источником сырья и мастерской.

const DIRECTIONS := [
    Vector2i(1, 0), Vector2i(0, 1),
    Vector2i(-1, 0), Vector2i(0, -1)
]


static func walkable(world: RefCounted, hydro: RefCounted,
        surface: RefCounted, cell: Vector2i) -> bool:
    # Вода, затопление, склон и заболоченность имеют приоритет над
    # визуальным соседством клеток и планами доставки.
    if not world.config.contains_cell(cell):
        return false
    var i: int = cell.y * world.config.width + cell.x
    return not hydro.has_water(i) and not hydro.flooded_at(i) \
        and world.normal_at(cell).y >= 0.76 \
        and surface.waterlogging_at_index(i) <= 0.85


static func find(world: RefCounted, hydro: RefCounted,
        surface: RefCounted, origin: Vector2i,
        target: Vector2i) -> Array[Vector2i]:
    # Поиск в ширину гарантирует кратчайший путь по четырёхсвязной
    # суше; ни груз, ни рабочий не переходят через непроходимую реку.
    var result: Array[Vector2i] = []
    if not walkable(world, hydro, surface, origin) \
            or not walkable(world, hydro, surface, target) \
            or origin == target:
        return result
    var width: int = world.config.width
    var count: int = width * world.config.height
    var parent := PackedInt32Array()
    parent.resize(count)
    parent.fill(-1)
    var start: int = origin.y * width + origin.x
    var goal: int = target.y * width + target.x
    var queue: Array[int] = [start]
    parent[start] = start
    var cursor := 0
    while cursor < queue.size() and parent[goal] == -1:
        var i: int = queue[cursor]
        cursor += 1
        var point := Vector2i(i % width, i / width)
        for direction in DIRECTIONS:
            var next: Vector2i = point + direction
            if not walkable(world, hydro, surface, next):
                continue
            var index: int = next.y * width + next.x
            if parent[index] != -1:
                continue
            parent[index] = i
            queue.append(index)
            if index == goal:
                break
    if parent[goal] == -1:
        return result
    var reversed: Array[Vector2i] = []
    var i := goal
    while i != start:
        reversed.append(Vector2i(i % width, i / width))
        i = parent[i]
    reversed.reverse()
    return reversed
