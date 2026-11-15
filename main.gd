extends Node3D

const Soldier = preload("res://soldier.gd")
const NAMES := {"rpg": "РПГ", "ammo": "Патроны", "medkit": "Аптечка"}
const ORD := {"перв": 1, "втор": 2, "трет": 3, "четв": 4, "пят": 5, "шест": 6, "седьм": 7, "восьм": 8,
    "один": 1, "два": 2, "три": 3, "четыр": 4, "пять": 5, "шесть": 6, "семь": 7, "восем": 8}

var soldiers: Array = []
var items: Array = []
var brain
var log_box: RichTextLabel
var input: LineEdit

func _ready() -> void:
    _build_world()
    _build_ui()
    brain = get_node("/root/Brain")
    brain.result.connect(_on_result)
    brain.status.connect(_on_status)
    if brain.last_status != "":
        _on_status(brain.last_status)
    var tm := Timer.new()
    tm.wait_time = 7.0
    tm.autostart = true
    tm.timeout.connect(_idle_tick)
    add_child(tm)
    _log("Отдавай приказы: «Седьмой, огонь по пятому из РПГ», «Все, смирно», «Третий, драй толчки», «Второй, возьми аптечку».")

func _box(size: Vector3, col: Color, pos: Vector3) -> MeshInstance3D:
    var b := BoxMesh.new()
    b.size = size
    var m := StandardMaterial3D.new()
    m.albedo_color = col
    b.material = m
    var mi := MeshInstance3D.new()
    mi.mesh = b
    add_child(mi)
    mi.position = pos
    return mi

func _build_world() -> void:
    var cam := Camera3D.new()
    cam.keep_aspect = Camera3D.KEEP_WIDTH
    cam.position = Vector3(0, 13, 12)
    add_child(cam)
    cam.look_at(Vector3(0, 0, 1))
    var sun := DirectionalLight3D.new()
    sun.rotation_degrees = Vector3(-60, 30, 0)
    add_child(sun)
    var env := Environment.new()
    env.background_mode = Environment.BG_COLOR
    env.background_color = Color(0.55, 0.7, 0.85)
    env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
    env.ambient_light_color = Color(0.6, 0.6, 0.6)
    var we := WorldEnvironment.new()
    we.environment = env
    add_child(we)
    _box(Vector3(26, 0.1, 26), Color(0.4, 0.38, 0.25), Vector3(0, -0.05, 0))
    for i in 8:
        var s: Soldier = Soldier.new()
        add_child(s)
        s.world = self
        s.setup(i + 1, Vector3(-4.5 + 3.0 * (i % 4), 0, -4.0 + 4.0 * floorf(i / 4.0)))
        s.said.connect(_on_said)
        soldiers.append(s)
    var defs := [["rpg", Vector3(1.4, 0.3, 0.3), Color(0.4, 0.25, 0.1), -4.5],
        ["ammo", Vector3(0.7, 0.5, 0.7), Color(0.2, 0.2, 0.2), 0.0],
        ["medkit", Vector3(0.7, 0.5, 0.7), Color(0.9, 0.9, 0.9), 4.5]]
    for d in defs:
        var m := _box(d[1], d[2], Vector3(d[3], d[1].y / 2.0, 6.0))
        m.set_meta("kind", d[0])
        m.set_meta("title", NAMES[d[0]])
        var l := Label3D.new()
        l.text = NAMES[d[0]]
        l.font_size = 56
        l.position.y = 1.0
        l.billboard = BaseMaterial3D.BILLBOARD_ENABLED
        l.no_depth_test = true
        m.add_child(l)
        items.append(m)

func _build_ui() -> void:
    var cl := CanvasLayer.new()
    add_child(cl)
    var box := VBoxContainer.new()
    box.anchor_left = 0.0
    box.anchor_right = 1.0
    box.anchor_top = 1.0
    box.anchor_bottom = 1.0
    box.offset_left = 10
    box.offset_right = -10
    box.offset_top = -480
    box.offset_bottom = -10
    cl.add_child(box)
    log_box = RichTextLabel.new()
    log_box.bbcode_enabled = true
    log_box.scroll_following = true
    log_box.size_flags_vertical = Control.SIZE_EXPAND_FILL
    log_box.add_theme_font_size_override("normal_font_size", 26)
    log_box.add_theme_font_size_override("bold_font_size", 26)
    var sb := StyleBoxFlat.new()
    sb.bg_color = Color(0, 0, 0, 0.6)
    log_box.add_theme_stylebox_override("normal", sb)
    box.add_child(log_box)
    var row := HBoxContainer.new()
    box.add_child(row)
    input = LineEdit.new()
    input.placeholder_text = "Приказ (диктуй 🎤 на клавиатуре)"
    input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    input.custom_minimum_size.y = 90
    input.add_theme_font_size_override("font_size", 30)
    input.text_submitted.connect(_submit)
    row.add_child(input)
    var btn := Button.new()
    btn.text = "Приказ"
    btn.add_theme_font_size_override("font_size", 30)
    btn.pressed.connect(func(): _submit(input.text))
    row.add_child(btn)
    var tb := Button.new()
    tb.text = "Дрессировка"
    tb.add_theme_font_size_override("font_size", 24)
    tb.pressed.connect(func(): get_tree().change_scene_to_file("res://train.tscn"))
    row.add_child(tb)

func _log(s: String) -> void:
    log_box.append_text(s + "\n")

func _on_said(who, text: String) -> void:
    _log("[b]№%d:[/b] %s" % [who.id, text])
    if DisplayServer.has_feature(DisplayServer.FEATURE_TEXT_TO_SPEECH):
        var v := DisplayServer.tts_get_voices_for_language("ru")
        if v.size() > 0:
            DisplayServer.tts_speak(text, v[0], 50, 0.8 + 0.08 * who.id)

func _num(w: String) -> int:
    if w.is_valid_int():
        return int(w)
    for k in ORD:
        if w.begins_with(k):
            return ORD[k]
    return 0

func parse(text: String) -> Dictionary:
    var r := RegEx.new()
    r.compile("[а-яёa-z0-9]+")
    var toks: Array = []
    for m in r.search_all(text.to_lower()):
        var w: String = m.get_string()
        if w in ["номер", "солдат", "боец", "рядовой"]:
            continue
        toks.append(_num(w))
    var ns := toks.filter(func(x): return x > 0)
    var addr := 0
    var tgt := 0
    if ns.size() > 0 and toks[0] > 0:
        addr = ns[0]
        ns = ns.slice(1)
    if ns.size() > 0:
        tgt = ns[0]
    return {"addr": addr, "tgt": tgt}

func _submit(text: String) -> void:
    if text.strip_edges() == "":
        return
    input.clear()
    _log("[b]Командир:[/b] " + text)
    var p := parse(text)
    var alive := soldiers.filter(func(s): return s.hp > 0)
    var targets := alive
    if p.addr > 0:
        targets = alive.filter(func(s): return s.id == p.addr)
    if targets.is_empty():
        _log("[color=gray]Такого солдата нет в строю.[/color]")
        return
    for s in targets:
        brain.think(s, "Приказ командира: «%s»" % text, p.tgt, targets.size() <= 2)

func _idle_tick() -> void:
    var cand := soldiers.filter(func(s): return s.hp > 0 and s.goal.is_empty() and s.has_item_near())
    if cand.is_empty():
        return
    brain.think(cand.pick_random(), "Событие: приказов нет, рядом лежит снаряжение.", 0, true)

func _on_result(s, a) -> void:
    s.do(a)

func _on_status(t: String) -> void:
    _log("[color=gray]%s[/color]" % t)