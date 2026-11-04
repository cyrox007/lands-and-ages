extends RefCounted
## GPU-инстансы природных объектов с настоящими CC0 GLB и резервной геометрией.
## Вне видимых чанков узлы/анимация не создаются.

const Wind = preload("res://shaders/nature_wind.gdshader")
const Terrain = preload("res://scripts/terrain.gd")
const Models = preload("res://scripts/nature_asset_library.gd")
const Felling = preload("res://scripts/nature_felling_visual.gd")

static var _meshes: Dictionary = {}
static var _materials: Dictionary = {}


static func _mesh(kind: String) -> Mesh:
    if _meshes.has(kind):
        return _meshes[kind]
    var mesh: PrimitiveMesh
    if kind == "трава":
        var blade := CylinderMesh.new()
        blade.top_radius = 0.0
        blade.bottom_radius = 0.035
        blade.height = 0.36
        blade.radial_segments = 3
        mesh = blade
    elif kind in ["ствол", "пень", "бревно"]:
        var cylinder := CylinderMesh.new()
        cylinder.top_radius = 0.10 if kind == "ствол" else 0.16
        cylinder.bottom_radius = 0.17 if kind == "ствол" else 0.19
        cylinder.height = 0.22 if kind == "пень" else 2.0
        cylinder.radial_segments = 8
        mesh = cylinder
    elif kind == "хвоя":
        var cone := CylinderMesh.new()
        cone.top_radius = 0.0
        cone.bottom_radius = 0.83
        cone.height = 2.3
        cone.radial_segments = 9
        mesh = cone
    else:
        var sphere := SphereMesh.new()
        sphere.radius = 0.90 if kind == "листва" else (
            0.43 if kind == "куст" else 0.40)
        sphere.height = 1.8 if kind == "листва" else (
            0.86 if kind == "куст" else 0.60)
        sphere.radial_segments = 10
        sphere.rings = 5
        mesh = sphere
    if kind in ["хвоя", "листва", "куст", "трава"]:
        var wind := ShaderMaterial.new()
        wind.shader = Wind
        mesh.material = wind
    else:
        var material := StandardMaterial3D.new()
        material.vertex_color_use_as_albedo = true
        material.roughness = 0.98
        mesh.material = material
    _meshes[kind] = mesh
    return mesh


static func _color(kind: String, species: String, state: String) -> Color:
    if kind in ["ствол", "пень", "бревно"]:
        return Color(0.30, 0.22, 0.14) if state != "сухостой" else Color(0.44, 0.40, 0.32)
    if kind == "трава":
        return Color(0.22, 0.38, 0.13)
    if kind == "камень":
        return Color(0.46, 0.48, 0.43)
    if kind == "куст":
        return Color(0.17, 0.34, 0.12)
    match species:
        "сосна":
            return Color(0.16, 0.31, 0.16)
        "ель":
            return Color(0.10, 0.25, 0.15)
        "берёза":
            return Color(0.29, 0.42, 0.18)
        "дуб":
            return Color(0.25, 0.36, 0.14)
    return Color(0.20, 0.34, 0.16)


static func _push(groups: Dictionary, kind: String, transform: Transform3D,
        color: Color, phase: float, wind: float = 0.0) -> void:
    if not groups.has(kind):
        groups[kind] = []
    groups[kind].append({
        "transform": transform, "color": color,
        "phase": phase, "wind": wind
    })


static func _place_model(groups: Dictionary, key: String, origin: Vector3,
        scale_factor: float, color: Color, phase: float,
        wind: float = 0.0) -> bool:
    if Models.info(key).is_empty():
        return false
    _push(groups, "glb_" + key, Models.placement(key, origin, scale_factor),
        color, phase, wind)
    return true


static func create_chunk(world: RefCounted, nature: RefCounted,
        coord: Vector2i, detail: float = 1.0) -> Node3D:
    var result := Node3D.new()
    result.name = "Природные объекты"
    if nature == null or not nature.generated:
        return result
    var groups := {}
    for item in nature.objects_in_chunk(coord):
        var position := Vector2(float(item["x"]) + 0.5,
            float(item["y"]) + 0.5)
        var ground: float = world.height_at(position)
        if not is_finite(ground):
            continue
        var origin: Vector3 = world.config.to_scene(position, ground)
        var species: String = item["species"]
        var state: String = item["state"]
        var age: int = item["age_days"]
        var scale_factor := clampf(float(age) / (20.0 * 96.0), 0.20, 1.25)
        var phase := float(posmod(int(item["id"]), 251)) / 251.0
        var cell := Vector2i(int(item["x"]), int(item["y"]))
        var index: int = nature.hydro.cell_index(cell)
        var wind: float = clampf(nature.climate.wind_at_index(index) / 2.4, 0.0, 1.0)
        var snow: float = nature.surface.snow_at_index(index)
        var winter: bool = nature.climate.weather_at(cell).get("season") == "зима"
        if item["kind"] == "дерево":
            if state == "пень":
                _push(groups, "пень",
                    Transform3D(Basis.IDENTITY, origin + Vector3(0, 0.11, 0)),
                    _color("пень", species, state), phase)
                if int(item["fallen_wood"]) > 0:
                    var angle: float = Felling.angle_for(
                        int(item["id"]), world.config.seed)
                    var offset := Vector2(cos(angle), sin(angle)) * 0.70
                    var log_point: Vector2 = world.config.clamp_point(
                        position + offset)
                    var log_height: float = world.height_at(log_point)
                    var log_origin: Vector3 = world.config.to_scene(
                        log_point, log_height) + Vector3(0, 0.19, 0)
                    var basis := Basis(Vector3.UP, angle) * Basis(
                        Vector3.FORWARD, -PI * 0.5)
                    var log_scale := clampf(scale_factor, 0.25, 1.0)
                    _push(groups, "бревно",
                        Transform3D(basis.scaled(Vector3.ONE * log_scale),
                            log_origin),
                        _color("бревно", species, state), phase)
                continue
            # Взрослые деревья используют настоящую модель. Зимой
            # у лиственных временно остаётся только голый ствол.
            var foliage_visible := state == "целое" and (
                not winter or species in ["сосна", "ель"])
            if foliage_visible:
                var selected := Models.select_tree(age, int(item["id"]), detail)
                var snowy := Color.WHITE.lerp(
                    Color(0.78, 0.84, 0.78), snow * 0.45)
                if _place_model(groups, selected, origin, scale_factor,
                        snowy, phase, wind):
                    continue
            var trunk_base := Basis.IDENTITY.scaled(
                Vector3(scale_factor, scale_factor, scale_factor))
            _push(groups, "ствол",
                Transform3D(trunk_base, origin +
                    Vector3(0, scale_factor, 0)),
                _color("ствол", species, state), phase)
            if state == "целое" and (not winter or species in ["сосна", "ель"]):
                var foliage: String = "хвоя" if species in ["сосна", "ель"] else "листва"
                var tint := _color(foliage, species, state).lerp(
                    Color(0.78, 0.82, 0.76), snow * 0.55)
                _push(groups, foliage,
                    Transform3D(trunk_base, origin +
                        Vector3(0, 2.15 * scale_factor, 0)),
                    tint, phase, wind)
        elif item["kind"] == "кустарник":
            var bush := Models.select_prop("кустарник", int(item["id"]))
            if _place_model(groups, bush, origin, 1.0, Color.WHITE.lerp(
                    Color(0.8, 0.85, 0.8), snow * 0.45), phase, wind):
                continue
            _push(groups, "куст",
                Transform3D(Basis.IDENTITY,
                    origin + Vector3(0, 0.36, 0)),
                _color("куст", species, state).lerp(
                    Color(0.78, 0.82, 0.76), snow * 0.55), phase, wind)
        elif item["kind"] == "валун":
            var rock := Models.select_prop("валун", int(item["id"]))
            if _place_model(groups, rock, origin, 1.0, Color.WHITE,
                    phase):
                continue
            _push(groups, "камень",
                Transform3D(Basis.IDENTITY, origin + Vector3(0, 0.26, 0)),
                _color("камень", species, state), phase)

    # Трава — дешёвый геометрический покров, а не отдельные сущности.
    # Около 64 пробных точек на чанк; результат зависит от физики мира.
    var area: Rect2i = world.config.chunk_rect(coord)
    for y in range(area.position.y, area.end.y, 2):
        for x in range(area.position.x, area.end.x, 2):
            var cell := Vector2i(x, y)
            var cover: float = nature.ground_cover_at(cell)
            if cover < 0.16:
                continue
            var seed: int = world.config.seed
            var amount: float = Terrain.hash2(x, y, seed + 804)
            if amount > cover:
                continue
            var jx: float = Terrain.hash2(x, y, seed + 805) - 0.5
            var jy: float = Terrain.hash2(x, y, seed + 806) - 0.5
            var position := Vector2(float(x) + 0.5 + jx,
                float(y) + 0.5 + jy)
            var terrain_height: float = world.height_at(position)
            if not is_finite(terrain_height):
                continue
            var origin: Vector3 = world.config.to_scene(position, terrain_height)
            var height_scale := 0.60 + cover
            var basis := Basis.IDENTITY.scaled(
                Vector3(1.0, height_scale, 1.0))
            var wind_index: int = nature.hydro.cell_index(cell)
            var wind: float = clampf(
                nature.climate.wind_at_index(wind_index) / 2.4, 0.0, 1.0)
            var phase: float = amount
            var grass := Models.select_prop("трава", x + y * world.config.width)
            if _place_model(groups, grass, origin, height_scale,
                    Color.WHITE, phase, wind):
                continue
            _push(groups, "трава",
                Transform3D(basis, origin +
                    Vector3(0.0, 0.18 * height_scale, 0.0)),
                _color("трава", "", "").lerp(
                    Color(0.34, 0.42, 0.15), 0.40 * amount), phase, wind)

    for kind in groups.keys():
        var instances: Array = groups[kind]
        var multi := MultiMesh.new()
        multi.transform_format = MultiMesh.TRANSFORM_3D
        multi.use_colors = true
        multi.use_custom_data = true
        if str(kind).begins_with("glb_"):
            var model: Dictionary = Models.info(str(kind).substr(4))
            if model.is_empty():
                continue
            multi.mesh = model["mesh"]
        else:
            multi.mesh = _mesh(kind)
        multi.instance_count = instances.size()
        for i in range(instances.size()):
            var entry: Dictionary = instances[i]
            multi.set_instance_transform(i, entry["transform"])
            multi.set_instance_color(i, entry["color"])
            multi.set_instance_custom_data(i,
                Color(float(entry["phase"]), float(entry["wind"]), 0, 0))
        var node := MultiMeshInstance3D.new()
        node.name = str(kind)
        node.multimesh = multi
        if str(kind).begins_with("glb_") and not str(kind).contains("Rock"):
            node.material_override = Models.wind_material(str(kind).substr(4))
        node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
        result.add_child(node)
    return result
