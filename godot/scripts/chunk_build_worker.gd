extends RefCounted
## Рабочее задание создаёт только массивы, не GPU-ресурсы и не Node.
## Во время его выполнения физические модели доступны лишь на чтение.

const Chunk = preload("res://scripts/chunk.gd")
const Water = preload("res://scripts/water_mesh.gd")

var coord: Vector2i
var mode: int
var world: RefCounted
var surface: RefCounted
var climate: RefCounted
var hydro: RefCounted
var fire: RefCounted
var cached_near_water := true
var arrays: Array = []
var prepare_us := 0
var water_arrays: Array = []
var water_prepare_us := 0
var _cancel_mutex := Mutex.new()
var _cancelled := false


func _init(p_coord: Vector2i, p_mode: int, p_world: RefCounted,
		p_surface: RefCounted, p_climate: RefCounted,
		p_hydro: RefCounted, p_fire: RefCounted = null,
		p_cached_near_water: bool = true) -> void:
	coord = p_coord
	mode = p_mode
	world = p_world
	surface = p_surface
	climate = p_climate
	hydro = p_hydro
	fire = p_fire
	cached_near_water = p_cached_near_water


func cancel() -> void:
	_cancel_mutex.lock()
	_cancelled = true
	_cancel_mutex.unlock()


func is_cancelled() -> bool:
	_cancel_mutex.lock()
	var cancelled := _cancelled
	_cancel_mutex.unlock()
	return cancelled


func run() -> void:
	if is_cancelled():
		return
	var started := Time.get_ticks_usec()
	arrays = Chunk.prepare_arrays(coord.x, coord.y, 1,
		world, surface, mode, climate, hydro, cached_near_water,
		Callable(self, "is_cancelled"))
	prepare_us = Time.get_ticks_usec() - started
	if is_cancelled():
		arrays = []
		return
	started = Time.get_ticks_usec()
	water_arrays = Water.prepare_arrays(world, hydro, coord, surface, fire,
		Callable(self, "is_cancelled"))
	# Отменённые массивы нельзя отдавать главному потоку, даже
	# если отмена пришла непосредственно после последней строки.
	if is_cancelled():
		arrays = []
		water_arrays = []
	water_prepare_us = Time.get_ticks_usec() - started
