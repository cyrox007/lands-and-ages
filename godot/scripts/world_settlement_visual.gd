extends Node3D
## Вид мастерской всегда восстанавливается из физического реестра.

const WORKSHOP_SIZE := Vector3(0.90, 0.95, 0.90)
const STORAGE_SIZE := Vector3(0.85, 0.62, 0.85)


func rebuild(settlement: RefCounted, map: RefCounted) -> void:
    # Графический узел — не источник истины, поэтому его можно пересоздать.
    for previous in get_children():
        previous.queue_free()
    if settlement == null or not settlement.has_workshop():
        return
    # Строения создаются по физическому реестру, не по кнопке UI.
    for item in settlement.buildings():
        var size := STORAGE_SIZE if str(item["kind"]) == "малый склад" \
            else WORKSHOP_SIZE
        var color := Color(0.48, 0.42, 0.30) if str(item["kind"]) \
            == settlement.STORAGE else Color(0.64, 0.33, 0.22)
        _add_building(map, Vector2i(int(item["x"]), int(item["y"])),
            str(item["kind"]), size, color)


func _add_building(map: RefCounted, cell: Vector2i,
        kind: String, size: Vector3, color: Color) -> void:
    # Фундамент, меш и коллизия имеют один центр и размер.
    # Рендер можно пересоздать без расхода материалов.
    var flat := Vector2(cell) + Vector2(0.5, 0.5)
    var body := StaticBody3D.new()
    body.name = kind
    body.collision_layer = 1
    body.collision_mask = 1
    body.position = map.config.to_scene(flat, map.height_at(flat) \
        + size.y * 0.5)

    # Статическая коллизия действительно закрывает фундамент.
    var collision := CollisionShape3D.new()
    collision.name = "CollisionShape3D"
    var shape := BoxShape3D.new()
    shape.size = size
    collision.shape = shape
    body.add_child(collision)

    # Временный корпус пока без финального арт-пакета. В отличие
    # от прежнего маркера размер совпадает с физическим телом.
    var model := MeshInstance3D.new()
    model.name = "MeshInstance3D"
    var mesh := BoxMesh.new()
    mesh.size = size
    model.mesh = mesh
    var material := StandardMaterial3D.new()
    material.albedo_color = color
    model.material_override = material
    body.add_child(model)
    add_child(body)
