extends RefCounted
## Природные коллизии создаются отдельно от массовой графики MultiMesh.
## Физические препятствия включаются только около активной камеры.

const Registry = preload("res://scripts/nature_registry.gd")
const Geometry = preload("res://scripts/nature_geometry.gd")

const ACTIVE_RADIUS_CHUNKS := 1
const MAX_NEW_CHUNKS_PER_FRAME := 2
const COLLISION_LAYER := 2
const COLLISION_NAME := "Природные коллизии"


static func near_camera(chunk: Vector2i, center: Vector2i) -> bool:
    return absi(chunk.x - center.x) <= ACTIVE_RADIUS_CHUNKS \
        and absi(chunk.y - center.y) <= ACTIVE_RADIUS_CHUNKS


static func _add_shape(body: StaticBody3D, shape: Shape3D,
        transform: Transform3D, id: int, part: String) -> void:
    var collider := CollisionShape3D.new()
    collider.shape = shape
    collider.transform = transform
    collider.set_meta("nature_id", id)
    collider.set_meta("nature_part", part)
    body.add_child(collider)


static func _cylinder(radius: float, height: float) -> CylinderShape3D:
    var shape := CylinderShape3D.new()
    shape.radius = radius
    shape.height = height
    return shape


static func _add_trunk(body: StaticBody3D, position: Vector3,
        item: Dictionary) -> void:
    var scale := clampf(float(item["age_days"]) / (20.0 * 96.0),
        0.20, 1.25)
    var radius: float = Registry.footprint_radius(item)
    var height := 2.1 * scale
    _add_shape(body, _cylinder(radius, height),
        Transform3D(Basis.IDENTITY,
            position + Vector3(0.0, height * 0.5, 0.0)),
        int(item["id"]), "ствол")


static func _add_stump(body: StaticBody3D, position: Vector3,
        item: Dictionary) -> void:
    _add_shape(body, _cylinder(0.15, 0.22),
        Transform3D(Basis.IDENTITY,
            position + Vector3(0.0, 0.11, 0.0)),
        int(item["id"]), "пень")


static func _add_log(body: StaticBody3D, world: RefCounted,
        point: Vector2, item: Dictionary) -> void:
    if int(item["fallen_wood"]) <= 0:
        return
    var footprint: Dictionary = Geometry.log_footprint(item, world.config)
    if footprint.is_empty():
        return
    var angle: float = footprint["angle"]
    var log_point: Vector2 = footprint["center"]
    var height: float = world.height_at(log_point)
    if not is_finite(height):
        return
    var origin: Vector3 = world.config.to_scene(log_point, height)
    var scale := clampf(float(item["age_days"]) / (20.0 * 96.0),
        0.25, 1.0)
    var rotation := Basis(Vector3.UP, angle) * Basis(
        Vector3.FORWARD, -PI * 0.5)
    _add_shape(body, _cylinder(0.19 * scale, 2.0 * scale),
        Transform3D(rotation, origin + Vector3(0.0, 0.19, 0.0)),
        int(item["id"]), "бревно")


static func create_chunk(world: RefCounted,
        nature: RefCounted, chunk: Vector2i) -> StaticBody3D:
    var body := StaticBody3D.new()
    body.name = COLLISION_NAME
    body.collision_layer = COLLISION_LAYER
    body.collision_mask = 0
    if nature == null or not nature.generated:
        return body

    for item in nature.objects_in_chunk(chunk):
        var point := Vector2(float(item["x"]) + 0.5,
            float(item["y"]) + 0.5)
        var height: float = world.height_at(point)
        if not is_finite(height):
            continue
        var position: Vector3 = world.config.to_scene(point, height)
        if item["kind"] == "валун":
            _add_shape(body, _cylinder(0.35, 0.45),
                Transform3D(Basis.IDENTITY,
                    position + Vector3(0.0, 0.225, 0.0)),
                int(item["id"]), "камень")
        elif item["kind"] == "дерево":
            if item["state"] == "пень":
                _add_stump(body, position, item)
                _add_log(body, world, point, item)
            else:
                _add_trunk(body, position, item)
        # Кроны, кусты и трава не перекрывают движение.

    return body


static func object_from_shape(body: CollisionObject3D,
        shape_index: int) -> Dictionary:
    # PhysicsRayQueryParameters3D возвращает collider + индекс формы.
    if body == null or shape_index < 0:
        return {}
    var owner_id: int = body.shape_find_owner(shape_index)
    if owner_id == 0:
        return {}
    var shape_node: Object = body.shape_owner_get_owner(owner_id)
    if shape_node == null or not shape_node.has_meta("nature_id"):
        return {}
    return {
        "id": int(shape_node.get_meta("nature_id")),
        "part": str(shape_node.get_meta("nature_part"))
    }
