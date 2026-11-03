extends Node3D
## Самостоятельный GPU-полигон: мир виден через чанки, экономика не подключена.

const Terrain = preload("res://scripts/terrain.gd")
const Climate = preload("res://scripts/climate.gd")
const Chunk = preload("res://scripts/chunk.gd")

const VIEW_RADIUS := 4
const BUILD_PER_FRAME := 2
const CAMERA_SPEED := 32.0
const MIN_ZOOM := 16.0
const MAX_ZOOM := 105.0

var _seed := Terrain.SEED
var _day := 1
var _center := Vector2(128.0, 96.0)
var _camera: Camera3D
var _terrain_holder: Node3D
var _ground_material: StandardMaterial3D
var _trunk_mesh: Mesh
var _crown_mesh: Mesh
var _active: Dictionary = {}
var _pending: Array[Vector2i] = []
var _chunk_center := Vector2i(-1, -1)
var _status: Label
var _hud_timer := 0.0


func _ready() -> void:
	_setup_environment()
	_setup_materials()
	_terrain_holder = Node3D.new()
	_terrain_holder.name = "Чанки"
	add_child(_terrain_holder)
	_camera = Camera3D.new()
	_camera.name = "Изометрическая камера"
	_camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	_camera.size = 66.0
	_camera.current = true
	add_child(_camera)
	_update_camera()
	_setup_interface()
	_refresh_visible(true)


func _setup_environment() -> void:
	var world_light := DirectionalLight3D.new()
	world_light.rotation_degrees = Vector3(-48, -40, 0)
	world_light.light_energy = 1.15
	world_light.shadow_enabled = false
	add_child(world_light)
	var sky := WorldEnvironment.new()
	var options := Environment.new()
	options.background_mode = Environment.BG_COLOR
	options.background_color = Color(0.47, 0.62, 0.72)
	options.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	options.ambient_light_color = Color(0.80, 0.85, 0.92)
	options.ambient_light_energy = 0.8
	sky.environment = options
	add_child(sky)


func _setup_materials() -> void:
	_ground_material = StandardMaterial3D.new()
	_ground_material.vertex_color_use_as_albedo = true
	_ground_material.roughness = 1.0
	_ground_material.cull_mode = BaseMaterial3D.CULL_DISABLED
	var wood := StandardMaterial3D.new()
	wood.albedo_color = Color(0.30, 0.21, 0.14)
	var needles := StandardMaterial3D.new()
	needles.albedo_color = Color(0.18, 0.38, 0.28)
	var cylinder := CylinderMesh.new()
	cylinder.height = 1.65
	cylinder.top_radius = 0.12
	cylinder.bottom_radius = 0.21
	cylinder.radial_segments = 6
	cylinder.material = wood
	_trunk_mesh = cylinder
	var sphere := SphereMesh.new()
	sphere.radius = 1.0
	sphere.height = 2.2
	sphere.radial_segments = 6
	sphere.rings = 4
	sphere.material = needles
	_crown_mesh = sphere


func _setup_interface() -> void:
	var canvas_layer := CanvasLayer.new()
	add_child(canvas_layer)
	var panel := PanelContainer.new()
	panel.position = Vector2(14, 14)
	panel.custom_minimum_size = Vector2(300, 112)
	canvas_layer.add_child(panel)
	var column := VBoxContainer.new()
	panel.add_child(column)
	_status = Label.new()
	column.add_child(_status)
	var next_button := Button.new()
	next_button.text = "Следующее время года"
	next_button.pressed.connect(_next_season)
	column.add_child(next_button)
	var hint := Label.new()
	hint.text = "WASD / стрелки — перемещение · колесо — масштаб · пальцем — сдвиг"
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	column.add_child(hint)
	_update_hud()


func _update_camera() -> void:
	var offset := Vector3(45.0, 63.0, 45.0)
	_camera.position = Vector3(_center.x, 0.0, _center.y) + offset
	_camera.look_at(Vector3(_center.x, 0.0, _center.y), Vector3.UP)


func _process(delta: float) -> void:
	var movement := Vector2.ZERO
	if Input.is_key_pressed(KEY_A) or Input.is_key_pressed(KEY_LEFT):
		movement.x -= 1.0
	if Input.is_key_pressed(KEY_D) or Input.is_key_pressed(KEY_RIGHT):
		movement.x += 1.0
	if Input.is_key_pressed(KEY_W) or Input.is_key_pressed(KEY_UP):
		movement.y -= 1.0
	if Input.is_key_pressed(KEY_S) or Input.is_key_pressed(KEY_DOWN):
		movement.y += 1.0
	if movement.length_squared() > 0.0:
		_move_center(movement.normalized() * CAMERA_SPEED * delta * _camera.size / 66.0)
	for i in range(mini(BUILD_PER_FRAME, _pending.size())):
		_create_chunk(_pending.pop_front())
	_hud_timer += delta
	if _hud_timer > 0.3:
		_update_hud()
		_hud_timer = 0.0


func _input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP:
			_change_zoom(0.88)
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_change_zoom(1.12)
	elif event is InputEventScreenDrag:
		var scale_factor := _camera.size / 720.0
		_move_center(Vector2(-event.relative.x, -event.relative.y) * scale_factor)
	elif event is InputEventMouseMotion and event.button_mask & MOUSE_BUTTON_MASK_MIDDLE:
		var scale_factor := _camera.size / 720.0
		_move_center(Vector2(-event.relative.x, -event.relative.y) * scale_factor)


func _change_zoom(multiplier: float) -> void:
	_camera.size = clampf(_camera.size * multiplier, MIN_ZOOM, MAX_ZOOM)
	_refresh_visible(false)


func _move_center(amount: Vector2) -> void:
	_center = Vector2(
		clampf(_center.x + amount.x, 0.0, float(Terrain.WIDTH)),
		clampf(_center.y + amount.y, 0.0, float(Terrain.HEIGHT)))
	_update_camera()
	var next_chunk := Vector2i(floori(_center.x / float(Chunk.SIZE)),
		floori(_center.y / float(Chunk.SIZE)))
	if next_chunk != _chunk_center:
		_refresh_visible(false)


func _refresh_visible(force: bool) -> void:
	var center_chunk := Vector2i(floori(_center.x / float(Chunk.SIZE)),
		floori(_center.y / float(Chunk.SIZE)))
	_chunk_center = center_chunk
	var desired := {}
	for cy in range(center_chunk.y - VIEW_RADIUS, center_chunk.y + VIEW_RADIUS + 1):
		for cx in range(center_chunk.x - VIEW_RADIUS, center_chunk.x + VIEW_RADIUS + 1):
			if cx < 0 or cy < 0 or cx * Chunk.SIZE >= Terrain.WIDTH or cy * Chunk.SIZE >= Terrain.HEIGHT:
				continue
			desired[Vector2i(cx, cy)] = true
	for coord in _active.keys():
		if force or not desired.has(coord):
			_active[coord].queue_free()
			_active.erase(coord)
	_pending.clear()
	for coord in desired.keys():
		if not _active.has(coord):
			_pending.append(coord)
	_pending.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
		return (a - center_chunk).length_squared() < (b - center_chunk).length_squared())


func _create_chunk(coord: Vector2i) -> void:
	if _active.has(coord):
		return
	var node := Node3D.new()
	node.name = "Чанк_%d_%d" % [coord.x, coord.y]
	var ground := MeshInstance3D.new()
	ground.mesh = Chunk.create_mesh(coord.x, coord.y, _day, _seed)
	ground.material_override = _ground_material
	ground.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	node.add_child(ground)
	node.add_child(Chunk.create_trees(coord.x, coord.y, _day, _trunk_mesh, _crown_mesh, _seed))
	_terrain_holder.add_child(node)
	_active[coord] = node


func _next_season() -> void:
	_day += Climate.SEASON_DAYS
	_refresh_visible(true)
	_update_hud()


func _update_hud() -> void:
	if _status == null:
		return
	_status.text = "ЗЕМЛИ И ЭПОХИ · GPU-полигон\n"
	_status.text += "Карта %d×%d · регионы 12 · seed %d\n" % [
		Terrain.WIDTH, Terrain.HEIGHT, _seed]
	_status.text += "%s · день %d · FPS %d · чанки %d/%d" % [
		Climate.season_name(_day), _day, Engine.get_frames_per_second(),
		_active.size(), _active.size() + _pending.size()]
