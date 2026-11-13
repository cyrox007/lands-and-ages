extends StaticBody3D
## Трёхмерный центр поселения: готовые художественные меши glTF 2.0.
## Здесь нет процедурной сборки кубов; модель выбирается из 17
## отдельных скульптурных вариантов, импортируемых движком Godot.

const Rules = preload("res://scripts/world_headquarters_rules.gd")
const ArtPath := "res://assets/buildings/headquarters/headquarters_art.gltf"

var _architecture: Node3D
var _active_asset := ""


func rebuild(world: RefCounted, snapshot: Dictionary,
        _distant: bool = false) -> void:
    # Графический объект пересоздаётся только из физического состояния.
    # Это не изменяет уровень, стоимость, прочность и WorldSave.
    for old in get_children():
        remove_child(old)
        old.queue_free()
    _architecture = null
    _active_asset = ""
    name = "Центр поселения"
    if snapshot.is_empty():
        return

    # Центр сцены привязан к настоящему фундаменту 2×2. Коллизия
    # существует независимо от того, целое здание или перед нами руины.
    var first := Vector2i(int(snapshot["x"]), int(snapshot["y"]))
    var flat := Vector2(first) + Vector2.ONE
    position = world.config.to_scene(flat, world.height_at(flat))
    collision_layer = 1
    collision_mask = 1
    var collision := CollisionShape3D.new()
    collision.name = "CollisionShape3D"
    var shape := BoxShape3D.new()
    shape.size = Vector3(1.96, 1.55, 1.96)
    collision.shape = shape
    collision.position.y = 0.75
    add_child(collision)

    # Импортированная glTF-сцена содержит реальные меши, каждый
    # с геометрией, нормалями и материалами. Canvas и билбордов нет.
    var resource: Resource = ResourceLoader.load(ArtPath)
    if not (resource is PackedScene):
        push_error("Не импортирован художественный 3D-комплект центра")
        return
    _architecture = (resource as PackedScene).instantiate() as Node3D
    if _architecture == null:
        push_error("Не удалось создать трёхмерную модель центра")
        return
    _architecture.name = "Архитектура"
    add_child(_architecture)

    # У всех состояний общая скелетная сетка координат: разом
    # показываем ровно один корпус. Дополнительные элементы
    # ремонта или лёгкого ущерба — отдельные объёмные меши.
    for child in _architecture.get_children():
        if child is VisualInstance3D:
            child.visible = false
    var phase := str(snapshot["state"])
    var level := int(snapshot["level"])
    var stage := Rules.visual_stage(snapshot)
    if phase in ["строительство", "восстановление"]:
        match stage:
            "фундамент":
                _show("Foundation")
            "каркас":
                _show("Frame")
            "стены":
                _show("Walls")
            "крыша":
                _show("Roof")
    elif phase == "улучшение":
        _show("Level_%d" % level)
        _show("Scaffolding", true)
    elif phase == "повреждено":
        if int(snapshot["integrity"]) < 60:
            _show("Level_%d_Broken" % level)
        else:
            _show("Level_%d" % level)
            _show("Damage_Marks", true)
    elif phase == "свежие руины":
        _show("Ruins_Fresh")
    elif phase == "старые руины":
        _show("Ruins_Old")
    elif phase == "заросшие руины":
        _show("Ruins_Overgrown")
    else:
        _show("Level_%d" % level)


func _show(asset: String, extra: bool = false) -> void:
    # Различаем основной корпус и дополнительные строительные
    # детали. Отсутствие меша является ошибкой импорта, а не поводом
    # молча возвращать прежние кубы-заглушки.
    if _architecture == null:
        return
    var item: Node = _architecture.find_child(asset, true, false)
    if not (item is MeshInstance3D):
        push_error("3D-модель центра не содержит меш: " + asset)
        return
    item.visible = true
    if not extra:
        _active_asset = asset


func displayed_asset() -> String:
    # Тесты проверяют выбранный авторский меш, а не только
    # присутствие графического узла в дереве сцены.
    return _active_asset


func mesh_for(asset: String) -> MeshInstance3D:
    # Возвращаем реальную геометрию для технической проверки
    # количества поверхностей и отсутствия BoxMesh-заглушек.
    if _architecture == null:
        return null
    return _architecture.find_child(asset, true, false) as MeshInstance3D
