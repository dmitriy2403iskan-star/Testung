extends Node
# Локальная нейронка (godot-llm + Qwen): превращает текст приказа в цель обучения.
# Без нейронки работают простые правила по ключевым словам.
signal status(text)
signal goal_ready(goal)
var last_status := ""

const MODEL_URL := "https://huggingface.co/Qwen/Qwen2.5-0.5B-Instruct-GGUF/resolve/main/qwen2.5-0.5b-instruct-q4_k_m.gguf"
const MODEL := "user://model.gguf"
const PART := "user://model.part"
const GOAL_SCHEMA := '{"type":"object","properties":{"goal":{"type":"string","enum":["walk","jump","fly","stand"]}},"required":["goal"]}'

var llm = null
var llm_ready := false
var busy := false
var cur_text := ""
var t0 := 0
var http: HTTPRequest
var last_report := 0

func _ready() -> void:
    var ext := "res://addons/godot_llm/godot_llm.gdextension"
    var has_file := FileAccess.file_exists(ext) or ResourceLoader.exists(ext)
    var loaded := PackedStringArray()
    if Engine.has_singleton("GDExtensionManager") or ClassDB.class_exists("GDExtensionManager"):
        loaded = GDExtensionManager.get_loaded_extensions()
    if not ClassDB.class_exists("GDLlama"):
        var why := "Нейронка не загрузилась. Файл аддона в приложении: %s. Загружено расширений: %d." % ["есть" if has_file else "НЕТ", loaded.size()]
        if has_file and GDExtensionManager.has_method("load_extension"):
            var r = GDExtensionManager.load_extension(ext)
            why += " Попытка загрузки: код %s." % str(r)
            if ClassDB.class_exists("GDLlama"):
                _start_llm()
                return
        _st(why + " Цели понимаю по ключевым словам.")
        return
    _start_llm()

func _start_llm() -> void:
    if FileAccess.file_exists(MODEL):
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
    _st("Качаю модель нейронки (~400 МБ). Пока цели понимаю по ключевым словам.")

func _on_dl(_r, code: int, _h, _b) -> void:
    if code == 200:
        DirAccess.rename_absolute(ProjectSettings.globalize_path(PART), ProjectSettings.globalize_path(MODEL))
        _load()
    else:
        _st("Модель не скачалась (код %d). Работаю на ключевых словах." % code)

func _load() -> void:
    llm = ClassDB.instantiate("GDLlama")
    llm.model_path = ProjectSettings.globalize_path(MODEL)
    llm.n_predict = 40
    if "should_output_prompt" in llm:
        llm.should_output_prompt = false
    add_child(llm)
    llm.generate_text_finished.connect(_on_done)
    llm_ready = true
    _st("Нейронка загружена: понимаю приказы своими словами.")

func _process(_d: float) -> void:
    var now := Time.get_ticks_msec()
    if http and not llm_ready and now - last_report > 8000 and http.get_body_size() > 0:
        last_report = now
        _st("Модель: %d%%" % (100 * http.get_downloaded_bytes() / http.get_body_size()))
    if busy and now - t0 > 60000:
        busy = false
        goal_ready.emit(goal_rules(cur_text))

func ask_goal(text: String) -> void:
    if llm_ready and not busy:
        busy = true
        cur_text = text
        t0 = Time.get_ticks_msec()
        llm.run_generate_text(_goal_prompt(text), "", GOAL_SCHEMA)
    else:
        goal_ready.emit(goal_rules(text))

func _on_done(text: String) -> void:
    if not busy:
        return
    busy = false
    var j = JSON.parse_string(text)
    if j is Dictionary and j.has("goal"):
        goal_ready.emit(str(j["goal"]))
    else:
        goal_ready.emit(goal_rules(cur_text))

func _goal_prompt(text: String) -> String:
    var sys := "Определи цель тренировки человека по приказу. walk — ходить, jump — прыгать, fly — летать, stand — стоять."
    return "<|im_start|>system\n%s<|im_end|>\n<|im_start|>user\n%s<|im_end|>\n<|im_start|>assistant\n" % [sys, text]

func goal_rules(text: String) -> String:
    var t := text.to_lower()
    if "прыг" in t or "скач" in t:
        return "jump"
    if "лет" in t or "взлет" in t or "взлёт" in t or "пари" in t:
        return "fly"
    if "стой" in t or "замри" in t or "стоя" in t or "устой" in t:
        return "stand"
    return "walk"

func _st(t: String) -> void:
    last_status = t
    status.emit(t)
