extends Node
signal result(soldier, action)
signal status(text)
signal goal_ready(goal)
var last_status := ""

# Модель качается при первом запуске. Если 0.5B тупит — замени на 1.5B:
# .../Qwen2.5-1.5B-Instruct-GGUF/resolve/main/qwen2.5-1.5b-instruct-q4_k_m.gguf
const MODEL_URL := "https://huggingface.co/Qwen/Qwen2.5-0.5B-Instruct-GGUF/resolve/main/qwen2.5-0.5b-instruct-q4_k_m.gguf"
const MODEL := "user://model.gguf"
const PART := "user://model.part"
const SCHEMA := '{"type":"object","properties":{"action":{"type":"string","enum":["idle","move_to","pick_up","shoot","attention","clean"]},"target":{"type":"string"},"say":{"type":"string"}},"required":["action","target","say"]}'
const GOAL_SCHEMA := '{"type":"object","properties":{"goal":{"type":"string","enum":["walk","jump","fly","stand"]}},"required":["goal"]}'
const ITEMS := {"рпг": "rpg", "гранатомет": "rpg", "патрон": "ammo", "аптеч": "medkit"}

var llm = null
var llm_ready := false
var busy := false
var queue: Array = []
var cur = null
var t0 := 0
var http: HTTPRequest
var last_report := 0

func _ready() -> void:
    if not ClassDB.class_exists("GDLlama"):
        _st("Нейронки нет (аддон не найден) — солдаты работают на правилах.")
    elif FileAccess.file_exists(MODEL):
        _load()
    else:
        _download()

func _download() -> void:
    http = HTTPRequest.new()
    http.use_threads = true
    http.download_file = PART
    http.request_completed.connect(_on_dl)
    add_child(http)
    http.request(MODEL_URL)
    _st("Качаю модель (~400 МБ). Пока играем на правилах.")

func _on_dl(_r, code: int, _h, _b) -> void:
    if code == 200:
        DirAccess.rename_absolute(ProjectSettings.globalize_path(PART), ProjectSettings.globalize_path(MODEL))
        _load()
    else:
        _st("Модель не скачалась (код %d). Работаем на правилах." % code)

func _load() -> void:
    llm = ClassDB.instantiate("GDLlama")
    llm.model_path = ProjectSettings.globalize_path(MODEL)
    llm.n_predict = 80
    if "should_output_prompt" in llm:
        llm.should_output_prompt = false  # иначе в ответ попадает весь промпт и JSON не парсится
    add_child(llm)
    llm.generate_text_finished.connect(_on_done)
    llm_ready = true
    _st("Нейронка загружена.")

func _process(_d: float) -> void:
    var now := Time.get_ticks_msec()
    if http and not llm_ready and now - last_report > 8000 and http.get_body_size() > 0:
        last_report = now
        _st("Модель: %d%%" % (100 * http.get_downloaded_bytes() / http.get_body_size()))
    if busy and now - t0 > 60000:
        var c = cur
        busy = false
        cur = null
        if c.get("kind", "") == "goal":
            goal_ready.emit(goal_rules(c.t))
        else:
            result.emit(c.s, rules(c.s, c.t, c.g))
        _next()

func think(sol, text: String, tgt: int, use_llm: bool) -> void:
    if llm_ready and use_llm:
        queue.append({"s": sol, "t": text, "g": tgt})
        _next()
    else:
        result.emit(sol, rules(sol, text, tgt))

func _next() -> void:
    if busy or queue.is_empty():
        return
    busy = true
    t0 = Time.get_ticks_msec()
    cur = queue.pop_front()
    if cur.get("kind", "") == "goal":
        llm.run_generate_text(_goal_prompt(cur.t), "", GOAL_SCHEMA)
    else:
        llm.run_generate_text(_prompt(cur.s, cur.t, cur.g), "", SCHEMA)

func _on_done(text: String) -> void:
    if cur == null:
        return
    var c = cur
    cur = null
    busy = false
    var j = JSON.parse_string(text)
    if c.get("kind", "") == "goal":
        goal_ready.emit(str(j["goal"]) if j is Dictionary and j.has("goal") else goal_rules(c.t))
    elif j is Dictionary and j.has("action"):
        result.emit(c.s, j)
    else:
        result.emit(c.s, rules(c.s, c.t, c.g))
    _next()

func _prompt(sol, text: String, tgt: int) -> String:
    var sys: String = "Ты — солдат №%d украинской армии, живой человек, а не робот. Говори коротко, по-солдатски, по-русски. " % sol.id
    sys += "Выбери одно действие: idle, move_to, pick_up, shoot, attention, clean. "
    sys += "target: rpg, ammo, medkit или номер солдата цифрой, иначе пусто. say: одна короткая реплика. "
    sys += "Если приказа нет, а рядом полезное снаряжение — можешь взять его (pick_up)."
    var user := text
    if tgt > 0:
        user += " Цель приказа: солдат №%d." % tgt
    user += "\nТвоя обстановка: " + sol.observe()
    return "<|im_start|>system\n%s<|im_end|>\n<|im_start|>user\n%s<|im_end|>\n<|im_start|>assistant\n" % [sys, user]

func rules(sol, text: String, tgt: int) -> Dictionary:
    var t := text.to_lower()
    var item := ""
    for k in ITEMS:
        if k in t:
            item = ITEMS[k]
    var a := {"action": "idle", "target": "", "say": ["Есть, командир!", "Не понял, повторите!"].pick_random()}
    if "событие" in t:
        a = {"action": "pick_up", "target": "nearest", "say": ["Вижу снаряжение, беру!", "Лишним не будет."].pick_random()}
    elif "смирно" in t:
        a = {"action": "attention", "target": "", "say": ["Так точно!", "Смирно!", "Есть смирно!"].pick_random()}
    elif "стрел" in t or "огонь" in t or "выстрел" in t:
        a = {"action": "shoot", "target": str(tgt), "say": ["Выстрел пошёл!", "Цель накрыта!", "Получайте!"].pick_random()}
    elif "драй" in t or "чист" in t:
        a = {"action": "clean", "target": "", "say": ["А чем чистить, командир?", "Щётка есть? Без щётки никак!", "Есть драить! Хлорка кончилась."].pick_random()}
    elif "возьми" in t or "подбери" in t or "подними" in t or "взять" in t:
        a = {"action": "pick_up", "target": item if item != "" else "nearest", "say": "Беру!"}
    elif "иди" in t or "вперед" in t or "вперёд" in t or "подойди" in t or "беги" in t:
        a = {"action": "move_to", "target": item if item != "" else (str(tgt) if tgt > 0 else ""), "say": "Выдвигаюсь!"}
    return a

func _st(t: String) -> void:
    last_status = t
    status.emit(t)

func ask_goal(text: String) -> void:
    if llm_ready:
        queue.append({"s": null, "t": text, "g": 0, "kind": "goal"})
        _next()
    else:
        goal_ready.emit(goal_rules(text))

func _goal_prompt(text: String) -> String:
    var sys := "Определи цель тренировки человека-солдата по приказу. walk — ходить, jump — прыгать, fly — летать, stand — стоять."
    return "<|im_start|>system\n%s<|im_end|>\n<|im_start|>user\n%s<|im_end|>\n<|im_start|>assistant\n" % [sys, text]

func goal_rules(text: String) -> String:
    var t := text.to_lower()
    if "прыг" in t or "скач" in t:
        return "jump"
    if "лет" in t or "взлет" in t or "взлёт" in t or "пари" in t:
        return "fly"
    if "стой" in t or "замри" in t or "стоя" in t:
        return "stand"
    return "walk"
