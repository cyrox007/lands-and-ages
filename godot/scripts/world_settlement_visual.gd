extends Node3D
## Вид мастерской всегда восстанавливается из физического реестра.

const WORKSHOP_SIZE := Vector3(0.90, 0.95, 0.90)


func rebuild(settlement: RefCounted, map: RefCounted) -> void:
    # Графический узел — не источник истины, поэтому его можно пересоздать.
    for previous in get_children():
        previous.queue_free()
    if settlement == null or not settlement.has_workshop():
        return
    var flat := Vector2(settlement.center) + Vector2(0.5, 0.5)
    var body := StaticBody3D.new()
    body.name = "Кирпичная мастерская"
    body.collision_layer = 1
    body.collision_mask = 1
    body.position = map.config.to_scene(flat, map.height_at(flat) \
        + WORKSHOP_SIZE.y * 0.5)

    # Статическая коллизия действительно закрывает фундамент.
    var collision := CollisionShape3D.new()
    var shape := BoxShape3D.new()
    shape.size = WORKSHOP_SIZE
    collision.shape = shape
    body.add_child(collision)

    # Временный корпус пока без финального арт-пакета. В отличие
    # от прежнего маркера размер совпадает с физическим телом.
    var model := MeshInstance3D.new()
    var mesh := BoxMesh.new()
    mesh.size = WORKSHOP_SIZE
    model.mesh = mesh
    var material := StandardMaterial3D.new()
    material.albedo_color = Color(0.64, 0.33, 0.22)
    model.material_override = material
    body.add_child(model)
    add_child(body)
