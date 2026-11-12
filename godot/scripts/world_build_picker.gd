extends RefCounted
## Выбор клетки по экранным координатам для Godot, без Canvas-проекции.
## Пересечение вычисляем по единому физическому полю высот мира.

const Map = preload("res://scripts/world_map.gd")


static func screen_cell(world: RefCounted, camera: Camera3D,
        point: Vector2) -> Vector2i:
    # Камера сама задаёт луч в ортографическом и перспективном режимах.
    # В потоковом обзоре пользователь может смотреть не через _camera,
    # поэтому вызывающий код передаёт именно видимую камеру.
    if camera == null or not camera.is_inside_tree():
        return Vector2i(-1, -1)
    return ray_cell(world, camera.project_ray_origin(point),
        camera.project_ray_normal(point))


static func ray_cell(world: RefCounted, origin: Vector3,
        direction: Vector3) -> Vector2i:
    # Луч должен идти к земле сверху. Высотные границы берём у WorldMap,
    # а не из положения визуального меша, который может ещё загружаться.
    if world == null or direction.y >= -0.001:
        return Vector2i(-1, -1)
    var scale: float = world.config.height_scale
    var speed := -direction.y
    var near := maxf(0.0, (origin.y - Map.MAX_HEIGHT * scale) / speed)
    var far := (origin.y - Map.MIN_HEIGHT * scale) / speed
    if far < near:
        return Vector2i(-1, -1)

    # Поиск пересечения с поверхностью на 24 итерациях. При выходе
    # промежуточного луча за карту пробуем граничный рельеф, но итоговую
    # точку за границей никогда не принимаем.
    for step in range(24):
        var distance := (near + far) * 0.5
        var position := origin + direction * distance
        var flat: Vector2 = world.config.clamp_point(Vector2(position.x, position.z))
        var ground: float = world.height_at(flat) * scale
        if position.y > ground:
            near = distance
        else:
            far = distance
    var hit := origin + direction * ((near + far) * 0.5)
    return world.config.cell_at(Vector2(hit.x, hit.z))
