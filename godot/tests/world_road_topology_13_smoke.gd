extends SceneTree
## Регрессия дорожных масок и портов из старого JS, уже для Godot.

const Roads = preload("res://scripts/world_road_topology.gd")


func _initialize() -> void:
    # Для CI важен код завершения, а не только диагностический вывод.
    var ok := _verify()
    print("STAGE13-ROAD-TOPOLOGY: успешно" if ok else
        "STAGE13-ROAD-TOPOLOGY: ошибка")
    quit(0 if ok else 1)


func _verify() -> bool:
    # Обходим все 16 форм дорог и проверяем, что ещё не построенный
    # участок не соединяет соседние готовые дороги.
    for mask in range(16):
        var point := Vector2i(3, 3)
        var roads := {}
        roads[point] = true
        for index in range(4):
            if (mask & (1 << index)) != 0:
                roads[point + Roads.SIDES[index]] = true
        if Roads.road_mask(roads, point) != mask:
            push_error("Нарушена дорожная связность: " + str(mask))
            return false
        roads.erase(point)
        if Roads.road_mask(roads, point) != 0:
            push_error("Непостроенная дорога соединила участки")
            return false

    # Нужны и прямые, и повороты, и Т-узлы, и перекрёстки.
    var shapes := {}
    shapes[0] = "isolated"
    shapes[Roads.NORTH] = "end"
    shapes[Roads.NORTH | Roads.SOUTH] = "straight"
    shapes[Roads.NORTH | Roads.EAST] = "corner"
    shapes[Roads.NORTH | Roads.EAST | Roads.SOUTH] = "junction"
    shapes[15] = "crossroads"
    for mask in shapes:
        if Roads.road_kind(int(mask)) != str(shapes[mask]):
            push_error("Неверный тип дорожного соединения")
            return false

    # К фундаменту 2×2 есть восемь внешних клеток, у края —
    # только две; внутрь здания путь прокладывать нельзя.
    var rect := Rect2i(2, 2, 2, 2)
    var world := Rect2i(0, 0, 6, 6)
    var ports: Array[Vector2i] = Roads.perimeter(rect, world)
    if ports.size() != 8:
        push_error("Неверное число клеток подхода к постройке")
        return false
    for point in ports:
        if rect.has_point(point) or not world.has_point(point):
            push_error("Клетка подхода попала внутрь стены или за мир")
            return false
    if Roads.perimeter(Rect2i(0, 0, 1, 1), world).size() != 2:
        push_error("Граничное здание получило лишние точки подхода")
        return false
    return true
