extends RefCounted
## Загрузчик настоящих CC0 GLB. Один меш используется всеми экземплярами вида.
## Позиция и размер нормализуются в единицах Godot независимо от исходного файла.

const ROOT := "res://assets/nature/cc0_gobkit/"
const WIND := preload("res://shaders/nature_gltf_wind.gdshader")

const HEIGHT := {
    "TreeHigh001": 3.15, "TreeHigh002": 3.15,
    "TreeMed001": 3.15, "TreeMed002": 3.15,
    "TreeLow001": 3.15, "TreeLow002": 3.15,
    "Bush001": 0.75, "Bush002": 0.75,
    "Grass001": 0.40, "Grass002": 0.40,
    "Rock001": 0.50, "Rock002": 0.50
}

static var _models: Dictionary = {}
static var _materials: Dictionary = {}


static func _find_mesh(node: Node) -> MeshInstance3D:
    if node is MeshInstance3D and node.mesh != null:
        return node as MeshInstance3D
    for child in node.get_children():
        var found := _find_mesh(child)
        if found != null:
            return found
    return null


static func info(key: String) -> Dictionary:
    if _models.has(key):
        return _models[key]
    if not HEIGHT.has(key):
        return {}
    var resource := ResourceLoader.load(ROOT + key + ".glb") as PackedScene
    if resource == null:
        return {}
    var instance: Node = resource.instantiate()
    var visual := _find_mesh(instance)
    if visual == null:
        instance.free()
        return {}
    var mesh: Mesh = visual.mesh
    var bounds: AABB = mesh.get_aabb()
    if bounds.size.y < 0.001 or mesh.get_surface_count() == 0:
        instance.free()
        return {}
    var model := {
        "mesh": mesh,
        "base_scale": float(HEIGHT[key]) / bounds.size.y,
        "base_point": Vector3(bounds.position.x + bounds.size.x * 0.5,
            bounds.position.y,
            bounds.position.z + bounds.size.z * 0.5),
        "height": bounds.size.y,
        "vertices": 0,
        "triangles": 0
    }
    for index in range(mesh.get_surface_count()):
        var surface := mesh.surface_get_arrays(index)
        var positions: PackedVector3Array = surface[Mesh.ARRAY_VERTEX]
        var indices: PackedInt32Array = surface[Mesh.ARRAY_INDEX]
        model["vertices"] += positions.size()
        model["triangles"] += int(float(indices.size() if not indices.is_empty()
            else positions.size()) / 3.0)
    _models[key] = model
    instance.free()
    return model


static func placement(key: String, position: Vector3,
        growth: float = 1.0) -> Transform3D:
    var model: Dictionary = info(key)
    if model.is_empty():
        return Transform3D(Basis.IDENTITY, position)
    var scale: float = float(model["base_scale"]) * growth
    var pivot: Vector3 = model["base_point"]
    return Transform3D(Basis.IDENTITY.scaled(Vector3.ONE * scale),
        position - pivot * scale)


static func select_tree(age_days: int, id: int, detail: float) -> String:
    var variant := posmod(id, 2) + 1
    if detail < 0.28 or age_days < 7 * 96:
        return "TreeLow%03d" % variant
    if age_days < 18 * 96:
        return "TreeMed%03d" % variant
    return "TreeHigh%03d" % variant


static func select_prop(kind: String, id: int) -> String:
    var variant := posmod(id, 2) + 1
    match kind:
        "кустарник":
            return "Bush%03d" % variant
        "валун":
            return "Rock%03d" % variant
        "трава":
            return "Grass%03d" % variant
    return ""


static func wind_material(key: String) -> ShaderMaterial:
    if _materials.has(key):
        return _materials[key]
    var model: Dictionary = info(key)
    if model.is_empty():
        return null
    var source: Material = model["mesh"].surface_get_material(0)
    var shader := ShaderMaterial.new()
    shader.shader = WIND
    shader.set_shader_parameter("source_height", float(model["height"]))
    shader.set_shader_parameter("source_base", (model["base_point"] as Vector3).y)
    if source is BaseMaterial3D:
        var material := source as BaseMaterial3D
        shader.set_shader_parameter("source_tint", material.albedo_color)
        if material.albedo_texture != null:
            shader.set_shader_parameter("source_texture", material.albedo_texture)
            shader.set_shader_parameter("has_texture", true)
    _materials[key] = shader
    return shader


static func available_models() -> Array[String]:
    var result: Array[String] = []
    for key in HEIGHT.keys():
        if not info(key).is_empty():
            result.append(key)
    result.sort()
    return result
