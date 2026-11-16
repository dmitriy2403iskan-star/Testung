extends Node
# Проверка нейронки: тот же brain.gd, настоящая модель. Падает, если хоть одна фраза понята не так.
const CASES := [["Стоять", "stand"], ["Стой на месте", "stand"], ["Замри", "stand"], ["Прыгай", "jump"], ["Подпрыгни", "jump"], ["Иди вперёд", "walk"], ["Побежали", "walk"], ["Взлетай", "fly"], ["Лети", "fly"]]
var i := -1
var waited := 0.0
var failed := false
var started := false

func _ready() -> void:
    Brain.goal_ready.connect(_on_goal)

func _process(d: float) -> void:
    waited += d
    if not started:
        if Brain.llm_ready:
            started = true
            print("TEST: нейронка загружена за %.1f c" % waited)
            _next()
        elif waited > 120.0:
            print("TEST FAIL: нейронка не загрузилась. Статус: ", Brain.last_status)
            get_tree().quit(1)

func _next() -> void:
    i += 1
    if i >= CASES.size():
        print("TEST RESULT: ", "FAIL" if failed else "OK")
        get_tree().quit(1 if failed else 0)
        return
    print("TEST: спрашиваю «%s»" % CASES[i][0])
    Brain.ask_goal(CASES[i][0])

func _on_goal(g: String, by: String) -> void:
    var want: String = CASES[i][1]
    var ok := (g == want and by == "llm")
    print("TEST: «%s» -> %s (кто понял: %s), ожидалось %s: %s" % [CASES[i][0], g, by, want, "OK" if ok else "НЕ СОВПАЛО"])
    if not ok:
        failed = true
    _next()
