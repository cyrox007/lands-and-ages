extends RefCounted
## Числовые производственные контракты: сырьё, продукты и потребители.
## Технология определяет допуск, а не создаёт материалы или работников.

const RECIPES := {
    "обжиг кирпича": {
        "tier": 0, "inputs": {"глина": 3, "древесина": 3},
        "outputs": {"обожжённый кирпич": 3}
    },
    "тесать камень": {
        "tier": 0, "inputs": {"камень": 2},
        "outputs": {"каменные блоки": 2}
    },
    "дорожная подсыпка": {
        "tier": 0, "inputs": {"щебень": 2, "песок": 1},
        "outputs": {"дорожное покрытие": 3}
    },
    "связующий раствор": {
        "tier": 0, "inputs": {"глина": 1, "песок": 2},
        "outputs": {"строительный раствор": 2}
    },
    "обжиг кирпича на каменном угле": {
        "tier": 1, "inputs": {"глина": 3, "каменный уголь": 2},
        "outputs": {"обожжённый кирпич": 3}
    },
    "коксование угля": {
        "tier": 2, "inputs": {"каменный уголь": 3},
        "outputs": {"кокс": 2}
    },
    "выплавка железа на коксе": {
        "tier": 2, "inputs": {"железная руда": 3, "кокс": 2},
        "outputs": {"железо": 2}
    },
    "выжиг древесного угля": {
        "tier": 1, "inputs": {"древесина": 3},
        "outputs": {"древесный уголь": 2}
    },
    "плавка железа": {
        "tier": 1, "inputs": {"железная руда": 3, "древесный уголь": 2},
        "outputs": {"железо": 2}
    },
    "плавка меди": {
        "tier": 1, "inputs": {"медная руда": 3, "древесный уголь": 2},
        "outputs": {"медь": 2}
    },
    "плавка олова": {
        "tier": 1, "inputs": {"оловянная руда": 3, "древесный уголь": 2},
        "outputs": {"олово": 2}
    },
    "бронзовый сплав": {
        "tier": 2, "inputs": {"медь": 2, "олово": 1},
        "outputs": {"бронза": 3}
    },
    "железные инструменты": {
        "tier": 2, "inputs": {"железо": 2, "древесина": 1},
        "outputs": {"железные инструменты": 1}
    },
    "медные изделия": {
        "tier": 1, "inputs": {"медь": 2},
        "outputs": {"медные изделия": 2}
    },
    "бронзовые инструменты": {
        "tier": 2, "inputs": {"бронза": 2, "древесина": 1},
        "outputs": {"бронзовые инструменты": 1}
    }
}

const CONSUMERS := {
    "кирпичная мастерская": {
        "tier": 0, "inputs": {"обожжённый кирпич": 3}
    },
    "каменный фундамент": {
        "tier": 0, "inputs": {"каменные блоки": 2, "строительный раствор": 2}
    },
    "участок дороги": {
        "tier": 0, "inputs": {"дорожное покрытие": 3}
    },
    "кузница инструментов": {
        "tier": 2, "inputs": {"каменные блоки": 2, "железные инструменты": 1}
    },
    "медная мастерская": {
        "tier": 1, "inputs": {"медные изделия": 2}
    },
    "бронзовая мастерская": {
        "tier": 2, "inputs": {"бронзовые инструменты": 1}
    }
}

const RAW_MATERIALS := [
    "древесина", "камень", "щебень", "песок", "глина",
    "железная руда", "медная руда", "оловянная руда", "каменный уголь"
]


static func materials() -> Dictionary:
    # Допустимые складские товары выводятся только из источников и
    # рецептов, чтобы ошибки в названиях обнаруживались тестами.
    var known := {}
    for kind in RAW_MATERIALS:
        known[kind] = true
    for recipe in RECIPES.values():
        for material in recipe["outputs"]:
            known[material] = true
    return known


static func validate() -> bool:
    # В прямом проходе выводим реально производимые товары из
    # природного сырья и доступных предшествующих рецептов.
    var available := {}
    for raw in RAW_MATERIALS:
        available[raw] = true
    for recipe in RECIPES.values():
        if recipe["inputs"].is_empty() or recipe["outputs"].is_empty():
            return false
        if int(recipe["tier"]) < 0 or int(recipe["tier"]) > 2:
            return false
        for inputs in [recipe["inputs"], recipe["outputs"]]:
            for amount in inputs.values():
                if not (amount is int) or int(amount) <= 0:
                    return false
    for iteration in range(RECIPES.size()):
        var changed := false
        for recipe in RECIPES.values():
            var possible := true
            for ingredient in recipe["inputs"]:
                if not available.has(ingredient):
                    possible = false
            if not possible:
                continue
            for product in recipe["outputs"]:
                if not available.has(product):
                    available[product] = true
                    changed = true
        if not changed:
            break
    # В обратном проходе оставляем только товары, ведущие к
    # конкретной стройке; бесконечное производство без спроса запрещено.
    var demanded := {}
    for consumer in CONSUMERS.values():
        if consumer["inputs"].is_empty():
            return false
        for kind in consumer["inputs"]:
            if not available.has(kind) or int(consumer["inputs"][kind]) <= 0:
                return false
            demanded[kind] = true
    for iteration in range(RECIPES.size()):
        var changed := false
        for recipe in RECIPES.values():
            var useful := false
            for product in recipe["outputs"]:
                if demanded.has(product):
                    useful = true
            if not useful:
                continue
            for ingredient in recipe["inputs"]:
                if not demanded.has(ingredient):
                    demanded[ingredient] = true
                    changed = true
        if not changed:
            break
    for raw in RAW_MATERIALS:
        if not demanded.has(raw):
            return false
    for recipe in RECIPES.values():
        for product in recipe["outputs"]:
            if not available.has(product) or not demanded.has(product):
                return false
    return true

static func required_technology(recipe_id: String) -> int:
    # Один реестр определяет допуски для UI и физических списаний.
    var rule: Dictionary = RECIPES.get(recipe_id, {})
    return int(rule.get("tier", -1))
