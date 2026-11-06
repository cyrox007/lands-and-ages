extends RefCounted
## GPU-инстансы природных объектов с настоящими CC0 GLB и резервной геометрией.
## Вне видимых чанков узлы/анимация не создаются.

const Wind = preload("res://shaders/nature_wind.gdshader")
const FireSmoke = preload("res://shaders/fire_smoke.gdshader")
const FireFlame = preload("res://shaders/fire_flame.gdshader")
const MAX_SMOLDER_PLUMES_PER_CHUNK := 8
const Terrain = preload("res://scripts/terrain.gd")
const Models = preload("res://scripts/nature_asset_library.gd")
const Felling = preload("res://scripts/nature_felling_visual.gd")
const Geometry = preload("res://scripts/nature_geometry.gd")
const Climate = preload("res://scripts/climate.gd")
const SPARSE_GROUND_COVER_DETAIL := 0.28

static var _meshes: Dictionary = {}
static var _wind_direction := Vector2.RIGHT


static func set_wind_direction(direction: Vector2) -> void:
    # Обновляем только готовые шейдерные материалы видимого мира.
    # Климат и физика падения продолжают работать независимо от FPS.
    if direction.length_squared() < 0.000001:
        return
    _wind_direction = direction.normalized()
    Models.set_wind_direction(_wind_direction)
    for mesh in _meshes.values():
        var material: Material = mesh.material
        if material is ShaderMaterial:
            material.set_shader_parameter(
                "wind_direction", _wind_direction)


static func _mesh(kind: String) -> Mesh:
    if _meshes.has(kind):
        return _meshes[kind]
    if kind in ["дым", "пламя"]:
        var quad := QuadMesh.new()
        var plume := ShaderMaterial.new()
        plume.shader = FireSmoke if kind == "дым" else FireFlame
        plume.set_shader_parameter("wind_direction", _wind_direction)
        quad.material = plume
        _meshes[kind] = quad
        return quad
    var mesh: PrimitiveMesh
    if kind == "зарубка":
        var mark := BoxMesh.new()
        mark.size = Vector3(0.28, 0.24, 0.06)
        mesh = mark
    elif kind == "угли":
        # Все тлеющие пятна разделяют один небольшой GPU-меш.
        # Никаких отдельных сцен для каждой горячей клетки.
        var embers := SphereMesh.new()
        embers.radius = 0.18
        embers.height = 0.22
        embers.radial_segments = 6
        embers.rings = 3
        mesh = embers
    elif kind == "гарь":
        # След выгоревшего грунта — одна плоскость для всех пятен
        # видимого чанка, а не отдельные сцены и физические частицы.
        var scar := PlaneMesh.new()
        scar.size = Vector2(0.72, 0.72)
        mesh = scar
    elif kind == "трава":
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
        wind.set_shader_parameter("wind_direction", _wind_direction)
        mesh.material = wind
    else:
        var material := StandardMaterial3D.new()
        material.vertex_color_use_as_albedo = true
        material.roughness = 0.98
        if kind == "гарь":
            material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
            material.cull_mode = BaseMaterial3D.CULL_DISABLED
        if kind == "угли":
            material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
            material.emission_enabled = true
            material.emission = Color(0.83, 0.20, 0.04)
            material.emission_energy_multiplier = 0.75
        mesh.material = material
    _meshes[kind] = mesh
    return mesh


static func _color(kind: String, species: String, state: String) -> Color:
    if kind in ["ствол", "пень", "бревно"]:
        return Color(0.30, 0.22, 0.14) if state != "сухостой" else Color(0.44, 0.40, 0.32)
    if kind == "трава":
        return Color(0.22, 0.38, 0.13)
    if kind == "зарубка":
        return Color(0.45, 0.25, 0.12)
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


static func shrub_appearance(item: Dictionary) -> Dictionary:
    # Здоровье определяет масштаб и окраску реального куста,
    # а не временный эффект. После загрузки JSON вид остаётся тем же.
    var health := clampf(float(item.get("health", 1000)) / 1000.0,
        0.0, 1.0)
    if str(item.get("state", "")) == "сухостой":
        health = 0.0
    return {
        "scale": 0.55 + health * 0.45,
        "tint": Color(0.54, 0.45, 0.31).lerp(Color.WHITE, health),
        "health": health
    }


static func _push(groups: Dictionary, kind: String, transform: Transform3D,
        color: Color, phase: float, wind: float = 0.0,
        foliage: float = 0.0, health: float = 1.0) -> void:
    if not groups.has(kind):
        groups[kind] = []
    groups[kind].append({
        "transform": transform, "color": color,
        "phase": phase, "wind": wind,
        "foliage": foliage, "health": health
    })


static func _place_model(groups: Dictionary, key: String, origin: Vector3,
        scale_factor: float, color: Color, phase: float,
        wind: float = 0.0, shape: Vector3 = Vector3.ONE,
        yaw: float = 0.0, foliage: float = 0.0,
        health: float = 1.0) -> bool:
    if Models.info(key).is_empty():
        return false
    _push(groups, "glb_" + key,
        Models.placement(key, origin, scale_factor, shape, yaw),
        color, phase, wind, foliage, health)
    return true


static func create_chunk(world: RefCounted, nature: RefCounted,
        coord: Vector2i, detail: float = 1.0,
        fire: RefCounted = null) -> Node3D:
    var result := Node3D.new()
    result.name = "Природные объекты"
    if nature == null or not nature.generated:
        return result
    var groups := {}
    var season := Climate.season_name(nature.climate.day)
    var winter := season == "зима"
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
        var wind: float = smoothstep(6.0, 32.0,
            nature.climate.wind_gust_at_index(index))
        var snow: float = nature.surface.snow_at_index(index)
        if fire != null and fire.is_burning(int(item["id"])):
            # Огонь визуализируется только из реестра физических
            # очагов. При удалении камеры или загрузке не появляется
            # независимое вымышленное бедствие.
            var fire_scale := 0.8 if item["kind"] == "кустарник" else 1.35
            var fire_basis := Basis.IDENTITY.scaled(Vector3.ONE * fire_scale)
            _push(groups, "пламя",
                Transform3D(fire_basis, origin + Vector3(0.0, 0.10, 0.0)),
                Color.WHITE, phase, wind)
            _push(groups, "дым",
                Transform3D(fire_basis, origin + Vector3(0.0, 0.85, 0.0)),
                Color.WHITE, phase, wind)
        if item["kind"] == "дерево":
            if state == "пень":
                _push(groups, "пень",
                    Transform3D(Basis.IDENTITY, origin + Vector3(0, 0.11, 0)),
                    _color("пень", species, state), phase)
                if int(item["fallen_wood"]) > 0:
                    var footprint: Dictionary = Geometry.log_footprint(
                        item, world.config)
                    var angle: float = footprint["angle"]
                    var log_point: Vector2 = footprint["center"]
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
            var cut: int = int(item.get("cut_progress", 0))
            if cut > 0:
                var angle: float = Felling.angle_for(
                    int(item["id"]), world.config.world_seed)
                var radial := Vector3(cos(angle), 0.0, sin(angle))
                var mark_basis := Basis(Vector3.UP, angle).scaled(Vector3(
                    scale_factor * (0.35 + 0.65 * float(cut) / 1000.0),
                    scale_factor, scale_factor))
                _push(groups, "зарубка", Transform3D(mark_basis,
                    origin + radial * scale_factor * 0.17 +
                    Vector3(0, scale_factor * 0.45, 0)),
                    _color("зарубка", species, state), phase)
            # Разные породы используют разные модели. Даже зимой
            # лиственные деревья сохраняют ветвистый, а не цилиндрический ствол.
            var object_id: int = int(item["id"])
            var selected: String = Models.select_tree(
                age, object_id, detail, species, winter, state)
            var shape: Vector3 = Models.shape_for(species)
            var tree_color := Color.WHITE.lerp(
                Color(0.87, 0.91, 0.88), snow * 0.32)
            if species == "ель":
                tree_color = tree_color * Color(0.78, 0.89, 0.82)
            var yaw: float = Models.rotation_for(object_id)
            var seasonal: float = Models.foliage_stage(season, species)
            var health: float = clampf(
                float(item["health"]) / 1000.0, 0.0, 1.0)
            if _place_model(groups, selected, origin, scale_factor,
                    tree_color, phase, wind, shape, yaw, seasonal, health):
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
            # Повреждённый куст бледнеет, уменьшается, после гибели
            # остаётся сухим до естественного распада. Состояние
            # читается из NatureRegistry; GPU не изменяет здоровье.
            var appearance: Dictionary = shrub_appearance(item)
            var health: float = float(appearance["health"])
            var scale: float = float(appearance["scale"])
            var tint: Color = appearance["tint"]
            tint = tint.lerp(Color(0.8, 0.85, 0.8), snow * 0.45)
            var bush := Models.select_prop("кустарник", int(item["id"]))
            if _place_model(groups, bush, origin, scale, tint, phase,
                    wind, Vector3.ONE, 0.0, 0.0, health):
                continue
            var fallback_tint := _color("куст", species, state).lerp(
                Color(0.54, 0.45, 0.31), 1.0 - health)
            _push(groups, "куст",
                Transform3D(Basis.IDENTITY.scaled(Vector3.ONE * scale),
                    origin + Vector3(0, 0.36 * scale, 0)),
                fallback_tint.lerp(Color(0.78, 0.82, 0.76),
                    snow * 0.55), phase, wind, 0.0, health)
        elif item["kind"] == "валун":
            var rock := Models.select_prop("валун", int(item["id"]))
            if _place_model(groups, rock, origin, 1.0, Color.WHITE,
                    phase):
                continue
            _push(groups, "камень",
                Transform3D(Basis.IDENTITY, origin + Vector3(0, 0.26, 0)),
                _color("камень", species, state), phase)

    # Пепел берём только из сохраняемого реестра физических пожаров.
    # Один MultiMesh-слой живёт в видимом чанке и исчезает по мере
    # природного восстановления, даже если огня давно нет.
    if fire != null:
        var smolder_plumes := 0
        for ember in fire.smolder_in_chunk(coord):
            # Только действующие физические угли. Когда влажность
            # гасит тление, NatureRegistry обновляет чанк и угли исчезают.
            var ember_cell: Vector2i = ember["cell"]
            var ember_point := Vector2(ember_cell) + Vector2(0.5, 0.5)
            var ember_height: float = world.height_at(ember_point)
            if not is_finite(ember_height):
                continue
            var ember_origin: Vector3 = world.config.to_scene(
                ember_point, ember_height)
            var glow: float = clampf(float(ember["heat"]), 0.0, 1.0)
            _push(groups, "угли",
                Transform3D(Basis.IDENTITY.scaled(
                    Vector3.ONE * (0.60 + glow * 0.55)),
                    ember_origin + Vector3(0.0, 0.10, 0.0)),
                Color(0.55, 0.14, 0.045).lerp(
                    Color(1.0, 0.32, 0.07), glow), 0.0)
            if smolder_plumes < MAX_SMOLDER_PLUMES_PER_CHUNK:
                var cell_index: int = nature.hydro.cell_index(ember_cell)
                var gust: float = nature.climate.wind_gust_at_index(cell_index)
                var ember_scale := lerpf(0.18, 0.47, glow)
                _push(groups, "дым", Transform3D(
                    Basis.IDENTITY.scaled(Vector3.ONE * ember_scale), ember_origin),
                    Color.WHITE, float(posmod(cell_index, 251)) / 251.0,
                    smoothstep(6.0, 32.0, gust), 0.0, lerpf(0.26, 0.60, glow))
                smolder_plumes += 1
        for trace in fire.scorched_in_chunk(coord):
            var burned_cell: Vector2i = trace["cell"]
            var severity: float = float(trace["ash"])
            var position := Vector2(burned_cell) + Vector2(0.5, 0.5)
            var height: float = world.height_at(position)
            if not is_finite(height):
                continue
            var origin: Vector3 = world.config.to_scene(position, height)
            var scale := 0.65 + severity * 0.35
            _push(groups, "гарь",
                Transform3D(Basis.IDENTITY.scaled(Vector3.ONE * scale),
                    origin + Vector3(0.0, 0.065, 0.0)),
                Color(0.32, 0.29, 0.24).lerp(
                    Color(0.09, 0.075, 0.06), severity), 0.0)

    # Трава — дешёвый геометрический покров, а не отдельные сущности.
    # Около 64 пробных точек на чанк; результат зависит от физики мира.
    var area: Rect2i = world.config.chunk_rect(coord)
    var cover_step := 4 if detail < SPARSE_GROUND_COVER_DETAIL else 2
    for y in range(area.position.y, area.end.y, cover_step):
        for x in range(area.position.x, area.end.x, cover_step):
            var cell := Vector2i(x, y)
            # Плодородие после пожара — результат физики, а не
            # отдельная случайная маска в графическом движке.
            var cover: float = nature.ground_cover_at(cell, fire)
            if fire != null:
                # Зола временно лишает землю травяного покрова,
                # восстановление идёт суточной физикой, не FPS.
                cover *= 1.0 - fire.scorched_at(cell) * 0.95
            if cover < 0.16:
                continue
            var world_seed: int = world.config.world_seed
            var amount: float = Terrain.hash2(x, y, world_seed + 804)
            if amount > cover:
                continue
            var jx: float = Terrain.hash2(x, y, world_seed + 805) - 0.5
            var jy: float = Terrain.hash2(x, y, world_seed + 806) - 0.5
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
            var wind: float = smoothstep(6.0, 32.0,
                nature.climate.wind_gust_at_index(wind_index))
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
                Color(float(entry["phase"]), float(entry["wind"]),
                    float(entry["foliage"]), float(entry["health"])))
        var node := MultiMeshInstance3D.new()
        node.name = str(kind)
        node.multimesh = multi
        if str(kind).begins_with("glb_") and not str(kind).contains("Rock"):
            # У новых моделей ветер назначен каждой поверхности отдельно.
            # Общий override уничтожил бы текстуры коры и листьев.
            var legacy_wind := Models.wind_material(str(kind).substr(4))
            if legacy_wind != null:
                node.material_override = legacy_wind
        node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
        if kind in ["дым", "пламя"]:
            node.extra_cull_margin = 6.0 if kind == "дым" else 2.0
        result.add_child(node)
    return result
