extends RefCounted
## Выбор подходящего seed по измерениям. Не создаёт государства и рельеф.
## Если пригодных вариантов нет, сообщает об отказе вместо фиктивного успеха.

const STATES := 6
const CENTERS := 30
const MIN_FREE_LAND_SHARE := 0.10
const TYPES := [
    "материк", "полуостров", "архипелаг",
    "внутреннее море", "смешанная", "полностью затоплена"
]


static func reasons(row: Dictionary) -> Array[String]:
    var errors: Array[String] = []
    if not bool(row.get("invariants_valid", false)):
        errors.append("нарушены инварианты расчёта")
    if not bool(row.get("six_starts", false)):
        errors.append("менее шести стартовых районов")
    if int(row.get("centers", 0)) < CENTERS:
        errors.append("менее 30 геометрических центров")
    if int(row.get("states_with_five_hypothetical_mature_sites", 0)) < STATES:
        errors.append("не все государства вмещают пять проектных поселений")
    if int(row.get("starts_with_both_routes", 0)) < STATES:
        errors.append("не все старты имеют путь к древесине и камню")
    if int(row.get("states_with_both_territory_resources", 0)) < STATES:
        errors.append("не во всех географических зонах есть оба ресурса")
    var walkable: int = row.get("walkable", 0)
    var free_land: int = row.get("walkable_land_outside_center_influence", 0)
    if walkable <= 0 or float(free_land) < \
            float(walkable) * MIN_FREE_LAND_SHARE:
        errors.append("недостаточно незанятой суши")
    return errors


static func _score(row: Dictionary) -> float:
    var bases := float(int(row.get("centers", 0))) * 15.0 \
        + float(int(row.get("hypothetical_mature_sites", 0))) * 100.0 \
        + float(int(row.get(
            "states_with_five_hypothetical_mature_sites", 0))) * 500.0
    bases += float(int(row.get("starts_with_both_routes", 0))) * 100.0
    bases += float(int(row.get("states_with_both_territory_resources", 0))) \
        * 100.0
    var land: int = row.get("walkable", 0)
    var free_land: int = row.get("walkable_land_outside_center_influence", 0)
    bases += 100.0 * clampf(float(free_land) \
        / float(maxi(land, 1)), 0.0, 1.0)
    return snappedf(bases, 0.001)


static func summarize(rows: Array[Dictionary], limit: int = 5) -> Dictionary:
    var groups := {}
    for category in TYPES:
        groups[category] = {
            "observed_seeds": 0, "eligible_seeds": 0,
            "best_candidates": []
        }
    var accepted: Array[Dictionary] = []
    var rejected := 0
    for row in rows:
        var archetype: String = str(row.get("geography_archetype", "смешанная"))
        if not groups.has(archetype):
            archetype = "смешанная"
        groups[archetype]["observed_seeds"] += 1
        var violations: Array[String] = reasons(row)
        var candidate := {
            "seed": int(row.get("seed", 0)),
            "archetype": archetype,
            "score": _score(row),
            "geometric_centers": int(row.get("centers", 0)),
            "hypothetical_mature_centers":
                int(row.get("hypothetical_mature_sites", 0)),
            "violations": violations
        }
        if not violations.is_empty():
            rejected += 1
            continue
        accepted.append(candidate)
        groups[archetype]["eligible_seeds"] += 1
    accepted.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
        if float(a["score"]) == float(b["score"]):
            return int(a["seed"]) < int(b["seed"])
        return float(a["score"]) > float(b["score"]))
    for category in TYPES:
        var chosen := []
        for candidate in accepted:
            if candidate["archetype"] == category and chosen.size() < limit:
                chosen.append(candidate)
        groups[category]["best_candidates"] = chosen
    var missing: Array[String] = []
    for category in TYPES.slice(0, 4):
        if int(groups[category]["eligible_seeds"]) == 0:
            missing.append(category)
    return {
        "samples": rows.size(),
        "eligible": accepted.size(),
        "rejected": rejected,
        "best_overall": accepted.slice(0, maxi(limit, 0)),
        "by_archetype": groups,
        "missing_eligible_archetypes": missing,
        "minimum_free_walkable_fraction": MIN_FREE_LAND_SHARE,
        "strict_acceptance_rule_is_experimental": true,
        "approved_maximum_map_size": false,
        "six_real_economies_verified": false
    }
