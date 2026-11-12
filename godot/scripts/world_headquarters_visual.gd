extends StaticBody3D
## Процедурная 3D-архитектура главного здания поселения.
## Источник состояния — WorldSettlement; старые WebP используются только
## как художественные референсы, не как плоский рендер на карте.

const Rules = preload("res://scripts/world_headquarters_rules.gd")

const FOUNDATION := Color(0.39, 0.36, 0.32)
const STONE := Color(0.63, 0.61, 0.54)
const PLASTER := Color(0.77, 0.70, 0.55)
const TIMBER := Color(0.38, 0.25, 0.16)
const ROOF := Color(0.37, 0.23, 0.20)
const IRON := Color(0.28, 0.31, 0.34)
const MOSS := Color(0.25, 0.38, 0.24)


func rebuild(world: RefCounted, snapshot: Dictionary,
        distant: bool = false) -> void:
    # По ID и состоянию строим корпус заново. При обновлении камеры
    # удаляется только графика; оплаченная физика остаётся в реестре.
    for old in get_children():
        remove_child(old)
        old.queue_free()
    name = "Центр поселения"
    if snapshot.is_empty():
        return
    var top_left := Vector2i(int(snapshot["x"]), int(snapshot["y"]))
    var base := Vector2(top_left) + Vector2.ONE
    position = world.config.to_scene(base, world.height_at(base))
    collision_layer = 1
    collision_mask = 1
    var body := CollisionShape3D.new()
    body.name = "CollisionShape3D"
    var boundary := BoxShape3D.new()
    boundary.size = Vector3(1.96, 1.55, 1.96)
    body.shape = boundary
    body.position.y = 0.75
    add_child(body)

    # Несущий фундамент существует даже в разрушенном состоянии:
    # занятый участок не должен автоматически становиться проходимым.
    _box("Каменный фундамент", Vector3(1.94, 0.20, 1.94),
        Vector3(0, 0.08, 0), FOUNDATION)
    var phase := str(snapshot["state"])
    var stage := Rules.visual_stage(snapshot)
    var level := int(snapshot["level"])
    var broken := phase in Rules.RUINS
    var heavy := phase == "повреждено" \
        and int(snapshot["integrity"]) < 60
    if broken:
        _rubble(phase)
        return

    # На первом уровне возводим фахверк, далее усложняем каменную
    # архитектуру, а на третьем/четвёртом появляются башни и донжон.
    var building_level := level
    if phase == "строительство":
        building_level = 1
    var walls := stage not in ["фундамент", "каркас"]
    var frame := stage != "фундамент"
    var roof := stage not in ["фундамент", "каркас", "стены"]
    if frame:
        _frame()
    if walls:
        _walls(building_level, heavy)
    if roof and not heavy:
        _roof(building_level, false)
    if level >= 2 and walls:
        _side_wings(level, roof and not heavy)
    if level >= 3 and walls:
        _towers(level, roof and not heavy, distant)
    if level >= 4 and walls:
        _keep(roof and not heavy)
    if phase == "повреждено":
        _damage(int(snapshot["integrity"]))
    if phase in Rules.CONSTRUCTING:
        _scaffolding(int(snapshot["progress"]), distant)
        # При улучшении старая архитектура остаётся работоспособной
        # снаружи до завершения новых пристроек.
        if phase == "улучшение":
            _box("Старое крыло", Vector3(1.2, 0.64, 0.7),
                Vector3(0, 0.42, 0.45), PLASTER)


func _box(part: String, size: Vector3, at: Vector3,
        color: Color, rotation_z: float = 0.0) -> void:
    # Каждый архитектурный модуль — настоящий 3D MeshInstance3D,
    # со своим материалом и объёмом, не плоская камера-зависимая картинка.
    var element := MeshInstance3D.new()
    element.name = part
    var mesh := BoxMesh.new()
    mesh.size = size
    element.mesh = mesh
    element.position = at
    element.rotation.z = rotation_z
    var surface := StandardMaterial3D.new()
    surface.albedo_color = color
    surface.roughness = 0.94
    element.material_override = surface
    add_child(element)


func _cone(part: String, radius: float, height: float,
        at: Vector3, color: Color) -> void:
    # Конические крыши башен помогают различить укреплённый центр
    # на среднем приближении, не требуя внешнего ассета.
    var element := MeshInstance3D.new()
    element.name = part
    var mesh := CylinderMesh.new()
    mesh.top_radius = 0.02
    mesh.bottom_radius = radius
    mesh.height = height
    mesh.radial_segments = 8
    element.mesh = mesh
    element.position = at
    var material := StandardMaterial3D.new()
    material.albedo_color = color
    material.roughness = 0.93
    element.material_override = material
    add_child(element)


func _frame() -> void:
    # Четыре деревянных столба появляются после фундамента и
    # дают отдельную читаемую стадию ещё без стен и крыши.
    for x in [-0.67, 0.67]:
        for z in [-0.57, 0.57]:
            _box("Несущий столб", Vector3(0.09, 0.83, 0.09),
                Vector3(x, 0.55, z), TIMBER)
    for z in [-0.57, 0.57]:
        _box("Верхняя балка", Vector3(1.45, 0.10, 0.09),
            Vector3(0, 1.0, z), TIMBER)


func _walls(level: int, heavy: bool) -> void:
    # Первый корпус собирается из каменного цоколя, светлых стен,
    # выступающих деревянных рёбер и тёмного дверного проёма.
    var height := 0.72 if level < 3 else 0.92
    _box("Каменный цоколь", Vector3(1.49, 0.18, 1.28),
        Vector3(0, 0.22, 0), FOUNDATION)
    _box("Главный зал", Vector3(1.37, height, 1.17),
        Vector3(0, 0.27 + height / 2, 0), STONE if level >= 2 else PLASTER)
    _box("Дверной проём", Vector3(0.26, 0.44, 0.04),
        Vector3(0, 0.43, 0.61), TIMBER)
    for x in [-0.59, 0.59]:
        _box("Фахверковый угол", Vector3(0.08, height, 0.08),
            Vector3(x, 0.27 + height / 2, 0.59), TIMBER)
    if not heavy:
        for x in [-0.32, 0.32]:
            _box("Окно", Vector3(0.20, 0.23, 0.035),
                Vector3(x, 0.68, 0.60), IRON)


func _roof(level: int, wing: bool) -> void:
    # Два объёмных ската формируют настоящий двускатный силуэт.
    # При крупных разрушениях крыша отсутствует физически и визуально.
    var top := 1.13 if level < 3 else 1.34
    if wing:
        top = 0.78
    _box("Левый скат крыши", Vector3(0.92, 0.10, 1.43),
        Vector3(-0.36, top, 0), ROOF, -0.43)
    _box("Правый скат крыши", Vector3(0.92, 0.10, 1.43),
        Vector3(0.36, top, 0), ROOF, 0.43)
    if level >= 2 and not wing:
        _box("Каменная дымовая труба", Vector3(0.16, 0.43, 0.19),
            Vector3(-0.42, top + 0.28, -0.26), FOUNDATION)


func _side_wings(level: int, roof: bool) -> void:
    # Второй уровень расширяется боковыми пристройками. Третий
    # получает больше камня, не подменяя уже оплаченный центр.
    var color: Color = STONE if level >= 3 else PLASTER
    for side in [-1, 1]:
        _box("Боковое крыло", Vector3(0.38, 0.55, 0.83),
            Vector3(side * 0.76, 0.40, 0.10), color)
        if roof:
            _box("Кровля крыла", Vector3(0.44, 0.10, 0.93),
                Vector3(side * 0.76, 0.75, 0.10), ROOF)


func _towers(level: int, roof: bool, distant: bool) -> void:
    # Крепостные башни отдельно выступают над главным корпусом.
    # На дальнем плане оставляем два силуэта вместо четырёх.
    var corners := [Vector2(-0.78, -0.76), Vector2(0.78, -0.76)]
    if not distant:
        corners.append_array([Vector2(-0.78, 0.76), Vector2(0.78, 0.76)])
    for place in corners:
        _box("Башня", Vector3(0.35, 1.27, 0.35),
            Vector3(place.x, 0.72, place.y), STONE)
        if roof:
            _cone("Шатёр башни", 0.26, 0.44,
                Vector3(place.x, 1.58, place.y), ROOF)
    if level >= 4:
        _box("Укреплённая стена", Vector3(1.50, 0.26, 0.15),
            Vector3(0, 0.84, -0.8), FOUNDATION)


func _keep(roof: bool) -> void:
    # Четвёртый уровень узнаётся по возвышенному центральному
    # донжону и флагу, а не только по изменённому цвету стен.
    _box("Донжон", Vector3(0.64, 0.68, 0.64),
        Vector3(0, 1.38, -0.12), STONE)
    if roof:
        _cone("Шпиль цитадели", 0.47, 0.57,
            Vector3(0, 2.02, -0.12), ROOF)
        _box("Флагшток", Vector3(0.035, 0.56, 0.035),
            Vector3(0, 2.56, -0.12), TIMBER)
        _box("Флаг", Vector3(0.33, 0.15, 0.035),
            Vector3(0.18, 2.72, -0.12), Color(0.72, 0.28, 0.20))


func _scaffolding(progress: int, distant: bool) -> void:
    # При нехватке игрового времени строительные леса показывают
    # незавершённую работу, но не ускоряют её и не создают людей.
    for side in [-1, 1]:
        _box("Строительные леса", Vector3(0.07, 1.25, 0.08),
            Vector3(side * 0.93, 0.69, 0), TIMBER)
        if not distant:
            _box("Леса — поперечина", Vector3(0.07, 0.07, 1.8),
                Vector3(side * 0.93, 0.55, 0), TIMBER)
    if progress >= 4:
        _box("Доски на лесах", Vector3(1.85, 0.08, 0.18),
            Vector3(0, 1.03, 0.89), TIMBER)


func _damage(integrity: int) -> void:
    # Ущерб не исцеляется при перестройке сцены: повреждённые
    # камни и обломки выводятся из постоянной прочности реестра.
    var color: Color = FOUNDATION if integrity >= 60 else Color(0.42, 0.39, 0.35)
    _box("Сколотый камень", Vector3(0.35, 0.18, 0.26),
        Vector3(0.50, 0.19, 0.84), color)
    if integrity < 60:
        _box("Обвалившаяся кладка", Vector3(0.48, 0.21, 0.31),
            Vector3(-0.54, 0.13, 0.75), FOUNDATION)


func _rubble(phase: String) -> void:
    # Даже старые руины занимают все четыре клетки и сохраняют
    # коллизию, однако вместо крыши показываются сломанные камни.
    for index in range(7):
        var x := float(index % 3 - 1) * 0.57
        var z := float(index / 3 - 1) * 0.54
        _box("Обломки", Vector3(0.43, 0.15 + 0.06 * (index % 2), 0.36),
            Vector3(x, 0.18, z), FOUNDATION)
    if phase == "заросшие руины":
        for index in range(4):
            _box("Мох и трава", Vector3(0.24, 0.05, 0.27),
                Vector3(float(index % 2) * 1.0 - 0.5, 0.29,
                    float(index / 2) * 1.0 - 0.5), MOSS)
