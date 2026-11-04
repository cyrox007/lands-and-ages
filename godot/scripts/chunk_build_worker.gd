extends RefCounted
## Рабочее задание создаёт только массивы, не GPU-ресурсы и не Node.
## Во время его выполнения физические модели доступны лишь на чтение.

const Chunk = preload("res://scripts/chunk.gd")

var coord: Vector2i
var mode: int
var world: RefCounted
var surface: RefCounted
var climate: RefCounted
var hydro: RefCounted
var arrays: Array = []
var prepare_us := 0


func _init(p_coord: Vector2i, p_mode: int, p_world: RefCounted,
		p_surface: RefCounted, p_climate: RefCounted,
		p_hydro: RefCounted) -> void:
	coord = p_coord
	mode = p_mode
	world = p_world
	surface = p_surface
	climate = p_climate
	hydro = p_hydro


func run() -> void:
	var started := Time.get_ticks_usec()
	arrays = Chunk.prepare_arrays(coord.x, coord.y, 1,
		world, surface, mode, climate, hydro)
	prepare_us = Time.get_ticks_usec() - started
