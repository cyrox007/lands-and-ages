extends RefCounted
## Анализ ёмкости карты без размещения государств и изменения рельефа.

const DIRECTIONS := [
    Vector2i(1, 0), Vector2i(-1, 0),
    Vector2i(0, 1), Vector2i(0, -1)
]


static func report(world: RefCounted, hydro: RefCounted,
        surface: RefCounted, nature: RefCounted = null,
        radius: int = 9) -> Dictionary:
    hydro.ensure_ready()
    surface.ensure_ready()
    var width: int = world.config.width
    var height: int = world.config.height
    var count := width * height
    var suitable := PackedByteArray()
    suitable.resize(count)
    var ocean := 0
    var lake := 0
    var river := 0
    var flooded := 0
    var dry := 0
    var developable := 0

    for y in range(height):
        for x in range(width):
            var index := y * width + x
            if hydro.ocean_at(index):
                ocean += 1
            elif hydro.lake_at(index):
                lake += 1
            elif hydro.river_at(index):
                river += 1
            if hydro.flooded_at(index):
                flooded += 1
            if hydro.has_water(index):
                continue
            dry += 1
            var normal: Vector3 = world.normal_at(Vector2i(x, y))
            if normal.y < 0.88:
                continue
            if surface.soil_depth_at_index(index) < 0.12:
                continue
            if surface.waterlogging_at_index(index) > 0.70:
                continue
            suitable[index] = 1
            developable += 1

    # Четырёхсвязные части пригодной суши помогают обнаружить острова,
    # на которых не поместится даже одно развитое поселение.
    var visited := PackedByteArray()
    visited.resize(count)
    var areas: Array[int] = []
    for index in range(count):
        if suitable[index] == 0 or visited[index] != 0:
            continue
        var pending: Array[int] = [index]
        visited[index] = 1
        var cursor := 0
        while cursor < pending.size():
            var current: int = pending[cursor]
            cursor += 1
            var cx := current % width
            var cy := current / width
            for offset in DIRECTIONS:
                var nx: int = cx + offset.x
                var ny: int = cy + offset.y
                if nx < 0 or ny < 0 or nx >= width or ny >= height:
                    continue
                var next: int = ny * width + nx
                if suitable[next] != 0 and visited[next] == 0:
                    visited[next] = 1
                    pending.append(next)
        areas.append(pending.size())
    areas.sort()
    areas.reverse()

    # Жадная оценка, не алгоритм генерации поселений: показывает
    # геометрическую верхнюю границу кандидатов при выбранном радиусе.
    var placements: Array[Vector2i] = []
    var step := maxi(2, radius)
    var valid := 0
    for y in range(radius, height - radius, step):
        for x in range(radius, width - radius, step):
            var possible := 0
            var total := 0
            for dy in range(-radius, radius + 1):
                for dx in range(-radius, radius + 1):
                    if absi(dx) + absi(dy) > radius:
                        continue
                    total += 1
                    if suitable[(y + dy) * width + x + dx] != 0:
                        possible += 1
            if total == 0 or float(possible) / float(total) < 0.75:
                continue
            valid += 1
            var far_enough := true
            for used in placements:
                if Vector2(used - Vector2i(x, y)).length() < float(2 * radius + 3):
                    far_enough = false
                    break
            if far_enough:
                placements.append(Vector2i(x, y))

    return {
        "size": [width, height],
        "cells": count, "ocean": ocean, "lakes": lake,
        "rivers": river, "flooded": flooded, "dry": dry,
        "developable": developable,
        "largest_developable_areas": areas.slice(0, 12),
        "settlement_radius": radius,
        "possible_centers_checked": valid,
        "greedy_nonoverlapping_centers": placements.size(),
        "goal_30_met": placements.size() >= 30,
        "natural_objects": nature.count() if nature != null else 0,
        "wood_units": nature.wood_total() if nature != null else 0,
        "approximate": true
    }
