extends Node3D
# Менеджер: площадка, несколько людей (agent.gd), общая нейросеть и обучение, интерфейс, камера.
# Каждый человек пробует свой мутированный вариант весов; если результат лучше общего лучшего -
# вес становится общим. Над каждым человеком метка: стоит/падает и оценка прошлого эпизода.

const AgentS := preload("res://agent.gd")
const GOALS := {"stand": "СТОЯТЬ", "walk": "ИДТИ", "jump": "ПРЫГАТЬ", "fly": "ЛЕТАТЬ"}
const GROUP_NAMES := {"legs": "Ноги", "toes": "Стопы", "spine": "Корпус", "neck": "Шея", "arms": "Руки", "hands": "Кисти", "fingers": "Пальцы", "thrust": "Тяга"}
const N_HID := 16
const MUT_P := 0.05
const EP_SECONDS := 6.0
const SAVE := "user://skills_v2.json"
const SPEEDS := [1.0, 2.0, 4.0, 8.0, 16.0, 32.0]
const SPACING := 1.7
const SIGMA_MUL := [1.0, 0.6, 1.5, 2.2]
const SUPPORT_NAMES := ["Выкл", "Лёгкий", "Средний", "Сильный"]
const MENU_H := 720.0

var cam: Camera3D
var cam_mode := 0         # 0 - вокруг людей, 1 - свободный полёт
var cam_yaw := 143.0
var cam_pitch := 12.0
var cam_dist := 4.0
var fpos := Vector3(0, 2.2, -7.0)
var fyaw := 180.0
var fpitch := 10.0
var mv := Vector3.ZERO    # удержание кнопок движения: x вправо, y вверх, z вперёд
var pad_root: Control
var cam_btn: Button
var focus_btn: Button
var count_btn: Button
var touches := {}
var pinch_prev := 0.0
var menu_box: VBoxContainer
var panel_layer: CanvasLayer
var panel_text: TextEdit
var panel_title: Label
var panel_apply_btn: Button
var cam_sm := Vector3.ZERO
var last_ms := 0

var agents: Array = []
var n_agents := 4
var focus := -1           # -1 все, иначе номер человека
var support := 0
var labels_on := true
var act: Array = []
var group_btns := {}
var groups := {"legs": true, "toes": true, "spine": true, "neck": true, "arms": true, "hands": true, "fingers": false, "thrust": true}
var n_dof := 0
var n_in := 0
var n_out := 0
var n_w := 0

var auto_on := true       # автотренер и автоподбор подвеса
var ok_rounds := 0
var bad_rounds := 0
var auto_btn: Button
var gait_on := false
var gait_off: Array = []
var gait_amp: Array = []
var gait_ph: Array = []
var gait_period := 1.0
var gait_mix := 0.25      # сколько нейросеть добавляет поверх походки (0 = чистая походка)
var gait_name := ""
var gait_json := {}
var gait_btn: Button
const GAIT_SAVE := "user://gait.json"

var skills := {}
var goal := "stand"
var w := PackedFloat32Array()
var best := -1e9
var sigma := 0.05
var stall := 0
var eps := 0
var baseline := true
var ep_steps := 720
var speed_i := 0
var hud: Label
var log_box: RichTextLabel
var input: LineEdit
var speed_btn: Button
var support_btn: Button
var screen_btn: Button
var brain

func _ready() -> void:
    ep_steps = int(EP_SECONDS * float(Engine.physics_ticks_per_second))
    Engine.max_physics_steps_per_frame = 64
    _build_world()
    _build_ui()
    _build_extra_ui()
    _build_cam_pad()
    _spawn(n_agents)
    _load()
    if FileAccess.file_exists(GAIT_SAVE):
        var gj = JSON.parse_string(FileAccess.get_file_as_string(GAIT_SAVE))
        if gj is Dictionary:
            set_gait(gj)
    _set_goal("stand")
    brain = get_node("/root/Brain")
    brain.goal_ready.connect(_on_goal)
    brain.status.connect(_on_status)
    if brain.last_status != "":
        _log("[color=gray]%s[/color]" % brain.last_status)
    _log("Людей: %d. У каждого %d степеней свободы, сеть: %d входов, %d выходов, %d весов." % [agents.size(), n_dof, n_in, n_out, n_w])
    _log("Пиши цель: «стой», «ходи вперёд», «прыгай», «лети». Подвес держит их, пока учатся; потом выключи.")
    last_ms = Time.get_ticks_msec()

func _exit_tree() -> void:
    _store()
    Engine.time_scale = 1.0
    Engine.max_physics_steps_per_frame = 8
    get_viewport().disable_3d = false
    get_tree().paused = false

# ---------- люди ----------
func _spawn(n: int) -> void:
    for a in agents:
        a.queue_free()
    agents.clear()
    n_agents = n
    for i in n:
        var a: Node3D = AgentS.new()
        add_child(a)
        a.setup(self, i, Vector3((float(i) - float(n - 1) * 0.5) * SPACING, 0, 0))
        a.sigma_mul = SIGMA_MUL[i % SIGMA_MUL.size()]
        agents.append(a)
    n_dof = agents[0].n_dof
    n_in = agents[0].n_in
    n_out = agents[0].n_out
    n_w = n_in * N_HID + N_HID + N_HID * n_out + n_out
    _refresh_active()
    for a in agents:
        a.cur_w = w.duplicate()
    if focus >= n:
        focus = -1
    _update_labels_ui()

func _refresh_active() -> void:
    act = []
    for i in n_dof:
        act.append(groups[agents[0].d_g[i]])
    for k in 3:
        act.append(groups["thrust"])

# ---------- мир ----------
func _build_world() -> void:
    cam = Camera3D.new()
    cam.far = 500.0
    cam.fov = 60.0
    add_child(cam)
    _cam_update()
    var sun := DirectionalLight3D.new()
    sun.rotation_degrees = Vector3(-55, 25, 0)
    add_child(sun)
    var env := Environment.new()
    env.background_mode = Environment.BG_COLOR
    env.background_color = Color(0.62, 0.76, 0.9)
    env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
    env.ambient_light_color = Color(0.7, 0.7, 0.7)
    var we := WorldEnvironment.new()
    we.environment = env
    add_child(we)
    # пол: невидимая коллизия + клетчатая плита
    var fl := StaticBody3D.new()
    fl.collision_layer = 1
    fl.collision_mask = 0
    var pm := PhysicsMaterial.new()
    pm.friction = 1.0
    fl.physics_material_override = pm
    var cs := CollisionShape3D.new()
    var bs := BoxShape3D.new()
    bs.size = Vector3(1000, 1, 1000)
    cs.shape = bs
    fl.add_child(cs)
    add_child(fl)
    fl.position = Vector3(0, -0.5, 0)
    var img := Image.create(2, 2, false, Image.FORMAT_RGB8)
    img.set_pixel(0, 0, Color(0.82, 0.82, 0.84))
    img.set_pixel(1, 1, Color(0.82, 0.82, 0.84))
    img.set_pixel(1, 0, Color(0.7, 0.7, 0.73))
    img.set_pixel(0, 1, Color(0.7, 0.7, 0.73))
    var mat := StandardMaterial3D.new()
    mat.albedo_texture = ImageTexture.create_from_image(img)
    mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
    mat.uv1_scale = Vector3(500, 500, 1)
    var pl := PlaneMesh.new()
    pl.size = Vector2(1000, 1000)
    pl.material = mat
    var mi := MeshInstance3D.new()
    mi.mesh = pl
    add_child(mi)

func _physics_process(_d: float) -> void:
    var all_done := true
    for a in agents:
        if a.done:
            continue
        if a.tick():
            a.finish()
        else:
            all_done = false
    if all_done and not agents.is_empty():
        _round_end()

# ---------- награда и обучение ----------
func _mutate(mul: float) -> PackedFloat32Array:
    var c := w.duplicate()
    var o1 := n_in * N_HID
    var o2 := o1 + N_HID
    var o3 := o2 + N_HID * n_out
    var sg := sigma * mul
    for i in o2:
        if randf() < MUT_P:
            c[i] += randfn(0.0, sg)
    for k in n_out:
        if not act[k]:
            continue
        for j in N_HID:
            if randf() < MUT_P:
                c[o2 + k * N_HID + j] += randfn(0.0, sg)
        if randf() < MUT_P:
            c[o3 + k] += randfn(0.0, sg)
    return c

# раунд: все люди играли варианты одной модели. Лучший (авто-оценка + подтверждённая похвала)
# лучше прошлого эталона - становится новым эталоном, и следующие 4 играют его вариации.
func _round_end() -> void:
    var prev := best
    var top = agents[0]
    var top_sc := -1e9
    for a in agents:
        var sc: float = a.res + a.bonus
        if sc > top_sc:
            top_sc = sc
            top = a
    eps += 1
    var improved := false
    if baseline:
        best = top.res
        baseline = false
        _log("Старт: %.1f" % best)
    elif top_sc > best:
        improved = true
        best = top.res
        w = top.cur_w.duplicate()
        stall = 0
        sigma = minf(sigma * 1.1, 0.3)
        _log("Эп. %d: лучший №%d, %.1f - новый эталон" % [eps, top.idx + 1, top.res])
        _store()
    else:
        stall += 1
        if stall > 3:
            sigma = maxf(sigma * 0.9, 0.01)
            stall = 0
    if auto_on:
        _auto_curriculum()
    for a in agents:
        var sc2: float = a.res + a.bonus
        if prev < -1e8:
            a.verdict = "старт %.1f" % a.res
            a.verdict_col = Color(0.8, 0.8, 0.8)
        elif improved and a == top:
            a.verdict = "★ эталон +%.1f" % (sc2 - prev)
            a.verdict_col = Color(0.3, 1, 0.4)
        elif prev - sc2 <= 1.0:
            a.verdict = "✓ норм %.1f" % (sc2 - prev)
            a.verdict_col = Color(0.75, 1, 0.6)
        else:
            a.verdict = "✗ хуже %.1f" % (sc2 - prev)
            a.verdict_col = Color(1, 0.4, 0.35)
        if a.bonus != 0.0:
            a.verdict += " (ты %+.0f)" % a.bonus
        a.flash_t = 2.5
        a.bonus = 0.0
        a.events.clear()
        a.done = false
        a.cur_w = _mutate(a.sigma_mul)
        a.step = -1

# автоподвес: если раунд удался несколько раз подряд - ослабляем подвес, если все падают - усиливаем
func _round_success() -> bool:
    var good := 0
    var top_fwd := -9.0
    var top_h := 0.0
    for a in agents:
        if not a.fell and a.fin_up > 0.8 and a.finite():
            good += 1
        top_fwd = maxf(top_fwd, a.fin_fwd)
        top_h = maxf(top_h, a.max_h)
    if good * 4 < agents.size() * 3:
        return false
    if goal == "walk":
        return top_fwd > 1.5
    if goal == "jump":
        return top_h > agents[0].h0 + 0.15
    if goal == "fly":
        return top_h > agents[0].h0 + 0.5
    return true

func _auto_curriculum() -> void:
    if baseline:
        return
    if _round_success():
        ok_rounds += 1
        bad_rounds = 0
    else:
        bad_rounds += 1
        ok_rounds = 0
    if ok_rounds >= 3:
        ok_rounds = 0
        if support > 0:
            _log("[color=cyan]Авто: удаётся 3 раунда подряд → ослабляю подвес[/color]")
            set_support(support - 1)
        else:
            _log("[color=lime]Авто: без подвеса стабильно получается («%s» освоено). Можно ставить следующую цель.[/color]" % GOALS[goal])
    elif bad_rounds >= 6 and support < 3:
        bad_rounds = 0
        _log("[color=orange]Авто: 6 раундов неудач → усиливаю подвес[/color]")
        set_support(support + 1)

func _auto_toggle() -> void:
    auto_on = not auto_on
    auto_btn.text = "Авто ✓" if auto_on else "Авто ✗"
    _log("Автоматика (оценка действий + подвес): %s" % ("вкл" if auto_on else "выкл"))

func _restart_all() -> void:
    ok_rounds = 0
    bad_rounds = 0
    for a in agents:
        a.cur_w = w.duplicate()
        a.bonus = 0.0
        a.events.clear()
        a.done = false
        a.step = -1
        a.verdict = "старт"
        a.verdict_col = Color(0.8, 0.8, 0.8)

func _set_goal(g: String) -> void:
    _store()
    goal = g
    var ok := false
    if skills.has(g):
        var sw := PackedFloat32Array(skills[g].get("w", []))
        if sw.size() == n_w:
            w = sw
            eps = int(skills[g].get("eps", 0))
            ok = true
    if not ok:
        w = PackedFloat32Array()
        w.resize(n_w)
        for i in n_w:
            w[i] = randfn(0.0, 0.03)
        eps = 0
    baseline = true
    best = -1e9
    sigma = 0.05
    stall = 0
    _restart_all()
    _log("Цель: [b]%s[/b]" % GOALS[g])

func _on_goal(g: String, by: String) -> void:
    if not GOALS.has(g):
        return
    match by:
        "llm":
            _log("[color=cyan]🧠 Нейронка поняла приказ → %s[/color]" % GOALS[g])
        "words":
            _log("[color=orange]Нейронка не загружена, поняла по ключевым словам → %s[/color]" % GOALS[g])
        "timeout":
            _log("[color=orange]Нейронка не ответила за минуту, по ключевым словам → %s[/color]" % GOALS[g])
        _ when by.begins_with("fix:"):
            _log("[color=cyan]🧠 Нейронка предложила «%s», но в приказе однозначное слово → %s[/color]" % [by.trim_prefix("fix:"), GOALS[g]])
        _:
            _log("[color=orange]Нейронка ответила непонятно, по ключевым словам → %s[/color]" % GOALS[g])
    _set_goal(g)

# ---------- походка из файла (может быть написана любым ИИ, см. docs/) ----------
# формат: {"gait": {"name": "...", "period": 1.0, "mix": 0.25,
#          "joints": {"thigh_l.x": {"offset_deg": 0, "amp_deg": 25, "phase": 0.0}, ...}}}
func set_gait(d: Dictionary) -> String:
    var g = d.get("gait", d)
    if not (g is Dictionary) or not (g.get("joints") is Dictionary):
        return "нет раздела joints"
    var per := float(g.get("period", 1.0))
    if per < 0.2 or per > 5.0:
        return "period должен быть от 0.2 до 5 секунд"
    var names := {}
    for i in n_dof:
        names[agents[0].d_name[i]] = i
    var off: Array = []
    var amp: Array = []
    var ph: Array = []
    for i in n_dof:
        off.append(0.0)
        amp.append(0.0)
        ph.append(0.0)
    var unknown: Array = []
    var used := 0
    for k in g["joints"]:
        if not names.has(str(k)):
            unknown.append(str(k))
            continue
        var j: Dictionary = g["joints"][k]
        var i: int = names[str(k)]
        off[i] = deg_to_rad(float(j.get("offset_deg", 0.0)))
        amp[i] = deg_to_rad(float(j.get("amp_deg", 0.0)))
        ph[i] = float(j.get("phase", 0.0))
        used += 1
    if used == 0:
        return "ни одного известного сустава (примеры имён: thigh_l.x, calf_r.x). Неизвестные: %s" % ", ".join(unknown.slice(0, 5))
    gait_off = off
    gait_amp = amp
    gait_ph = ph
    gait_period = per
    gait_mix = clampf(float(g.get("mix", 0.25)), 0.0, 1.0)
    gait_name = str(g.get("name", "без имени"))
    gait_json = {"gait": g}
    var f := FileAccess.open(GAIT_SAVE, FileAccess.WRITE)
    if f:
        f.store_string(JSON.stringify(gait_json))
    _log("[color=lime]Походка «%s»: суставов %d, период %.2f с%s[/color]" % [gait_name, used, per, "" if unknown.is_empty() else ", неизвестных имён: %d (%s)" % [unknown.size(), ", ".join(unknown.slice(0, 3))]])
    return ""

func _gait_toggle() -> void:
    if gait_amp.is_empty():
        _log("[color=tomato]Походки нет. Импорт → вставьте файл походки (см. docs/GAIT_FOR_AI.md в репозитории).[/color]")
        return
    gait_on = not gait_on
    gait_btn.text = "Походка ✓" if gait_on else "Походка ✗"
    baseline = true
    best = -1e9
    _restart_all()
    if gait_on:
        _log("Походка «%s» включена. Для проверки: цель «ходи», подвес Средний/Сильный." % gait_name)
    else:
        _log("Походка выключена.")

# ---------- сохранение / экспорт умений ----------
func _store() -> void:
    if w.size() != n_w or n_w == 0:
        return
    var arr: Array = []
    for v in w:
        arr.append(snappedf(v, 0.0001))
    skills[goal] = {"w": arr, "eps": eps, "best": best}
    _save_file()

func _load() -> void:
    if FileAccess.file_exists(SAVE):
        var j = JSON.parse_string(FileAccess.get_file_as_string(SAVE))
        if j is Dictionary:
            skills = j

func _save_file() -> void:
    var f := FileAccess.open(SAVE, FileAccess.WRITE)
    if f:
        f.store_string(JSON.stringify(skills))

# разбор текста с умениями: терпим мусор вокруг, «умные» кавычки, обрезанный текст
func _parse_skills(raw: String) -> Dictionary:
    var t := raw.strip_edges()
    for q in ["\u201c", "\u201d", "\u201e", "\u201f", "\u00ab", "\u00bb"]:
        t = t.replace(q, "\"")
    var a := t.find("{")
    var b := t.rfind("}")
    if a < 0 or b <= a:
        return {"ok": false, "msg": "В тексте нет данных (не вижу { … }). Скопируйте весь текст экспорта целиком."}
    t = t.substr(a, b - a + 1)
    var js := JSON.new()
    if js.parse(t) != OK:
        return {"ok": false, "msg": "Текст повреждён (строка %d: %s). Вероятно, скопирован не целиком." % [js.get_error_line(), js.get_error_message()]}
    if not (js.data is Dictionary):
        return {"ok": false, "msg": "Это не экспорт умений."}
    var good := {}
    var info: Array = []
    for g in js.data:
        if str(g).begins_with("_"):
            continue
        var v = js.data[g]
        if not GOALS.has(str(g)) or not (v is Dictionary) or not v.has("w"):
            info.append("«%s» пропущено" % str(g))
            continue
        var n: int = (v["w"] as Array).size()
        if n != n_w:
            info.append("%s: %d весов, а нужно %d (другая версия тела)" % [GOALS[g], n, n_w])
        else:
            good[str(g)] = v
            info.append("%s ✓ (%d эп.)" % [GOALS[g], int(v.get("eps", 0))])
    return {"ok": not good.is_empty(), "msg": ", ".join(info), "skills": good}

func _open_panel(mode: String) -> void:
    _store()
    if mode == "export":
        var parts: Array = []
        for g in skills:
            var v: Dictionary = skills[g].duplicate()
            v["название"] = GOALS.get(g, g)
            parts.append("\"%s\": %s" % [g, JSON.stringify(v)])
        var s := "{\n\"_info\": \"Умения человека (Testung). Ключ = цель, eps = число эпизодов, best = лучшая оценка, w = веса сети (%d штук). Загружайте целиком через Импорт.\",\n%s\n}" % [n_w, ",\n".join(parts)]
        DisplayServer.clipboard_set(s)
        panel_text.text = s
        panel_title.text = "ЭКСПОРТ. Текст уже скопирован в буфер (%d КБ). Если не вставляется — выделите всё ниже (долгое нажатие → Выбрать всё) и скопируйте вручную." % (s.length() / 1024)
        panel_apply_btn.visible = false
    else:
        panel_text.text = DisplayServer.clipboard_get()
        panel_title.text = "ИМПОРТ. Вставьте текст умений (долгое нажатие → Вставить) и нажмите «Загрузить»."
        panel_apply_btn.visible = true
    panel_layer.visible = true

func _panel_close() -> void:
    panel_layer.visible = false

func _panel_copy() -> void:
    DisplayServer.clipboard_set(panel_text.text)
    _log("Текст скопирован в буфер.")

func _panel_paste() -> void:
    panel_text.text = DisplayServer.clipboard_get()

func _panel_apply() -> void:
    var raw := panel_text.text
    var ga := raw.find("\"gait\"")
    if ga >= 0 and raw.find("\"joints\"") >= 0:
        var jd = JSON.parse_string(raw.substr(raw.find("{")))
        if jd is Dictionary:
            var er := set_gait(jd)
            if er == "":
                panel_layer.visible = false
                gait_on = false
                _gait_toggle()
                var moving := false
                for v in gait_amp:
                    if absf(float(v)) > 0.001:
                        moving = true
                _set_goal("walk" if moving else "stand")
                if support == 0:
                    set_support(2)
            else:
                panel_title.text = "ПОХОДКА НЕ ЗАГРУЖЕНА: " + er
                _log("[color=tomato]Походка: %s[/color]" % er)
            return
    var r := _parse_skills(panel_text.text)
    if not r["ok"]:
        panel_title.text = "НЕ ЗАГРУЖЕНО: " + str(r["msg"])
        _log("[color=tomato]Импорт: %s[/color]" % r["msg"])
        return
    _store()
    var got: Dictionary = r["skills"]
    for g in got:
        skills[g] = got[g]
    _save_file()
    w = PackedFloat32Array()
    var target := goal if got.has(goal) else str(got.keys()[0])
    _log("[color=lime]Импорт: %s[/color]" % r["msg"])
    _set_goal(target)
    panel_layer.visible = false

func _export() -> void:
    _open_panel("export")

func _import() -> void:
    _open_panel("import")

func _reset_skill() -> void:
    skills.erase(goal)
    w = PackedFloat32Array()
    _set_goal(goal)

# ---------- интерфейс ----------
func _btn(text: String, cb: Callable, h := 70) -> Button:
    var b := Button.new()
    b.text = text
    b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    b.custom_minimum_size.y = h
    b.add_theme_font_size_override("font_size", 22)
    b.pressed.connect(cb)
    return b


func _build_ui() -> void:
    var cl := CanvasLayer.new()
    cl.process_mode = Node.PROCESS_MODE_ALWAYS
    add_child(cl)
    hud = Label.new()
    hud.position = Vector2(12, 10)
    hud.add_theme_font_size_override("font_size", 24)
    hud.add_theme_color_override("font_outline_color", Color.BLACK)
    hud.add_theme_constant_override("outline_size", 6)
    cl.add_child(hud)
    var box := VBoxContainer.new()
    box.anchor_left = 0.0
    box.anchor_right = 1.0
    box.anchor_top = 1.0
    box.anchor_bottom = 1.0
    box.offset_left = 10
    box.offset_right = -10
    box.offset_top = -MENU_H
    box.offset_bottom = -10
    cl.add_child(box)
    menu_box = box
    log_box = RichTextLabel.new()
    log_box.bbcode_enabled = true
    log_box.scroll_following = true
    log_box.size_flags_vertical = Control.SIZE_EXPAND_FILL
    log_box.add_theme_font_size_override("normal_font_size", 22)
    log_box.add_theme_font_size_override("bold_font_size", 22)
    var sb := StyleBoxFlat.new()
    sb.bg_color = Color(0, 0, 0, 0.6)
    log_box.add_theme_stylebox_override("normal", sb)
    box.add_child(log_box)
    var r1 := HBoxContainer.new()
    box.add_child(r1)
    input = LineEdit.new()
    input.placeholder_text = "Цель текстом (🎤 на клавиатуре)"
    input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    input.custom_minimum_size.y = 70
    input.add_theme_font_size_override("font_size", 28)
    input.text_submitted.connect(_cmd)
    r1.add_child(input)
    r1.add_child(_btn("OK", func(): _cmd(input.text)))
    var r2 := HBoxContainer.new()
    box.add_child(r2)
    r2.add_child(_btn("Молодец +", func(): _reward(5.0)))
    r2.add_child(_btn("Нет −", func(): _reward(-5.0)))
    speed_btn = _btn("x1", _speed)
    r2.add_child(speed_btn)
    support_btn = _btn("Подвес: Выкл", _support)
    r2.add_child(support_btn)
    var r4 := HBoxContainer.new()
    box.add_child(r4)
    cam_btn = _btn("Камера: вокруг", _cam_toggle)
    r4.add_child(cam_btn)
    focus_btn = _btn("Фокус: все", _focus_next)
    r4.add_child(focus_btn)
    count_btn = _btn("Людей: 4", _count_next)
    r4.add_child(count_btn)
    r4.add_child(_btn("Вид ⟲", _cam_reset))
    var r3 := HBoxContainer.new()
    box.add_child(r3)
    r3.add_child(_btn("Пауза", _pause))
    r3.add_child(_btn("Экспорт", _export))
    r3.add_child(_btn("Импорт", _import))
    r3.add_child(_btn("Сброс", _reset_skill))
    screen_btn = _btn("Экран ✓", _screen)
    r3.add_child(screen_btn)
    var r5 := HBoxContainer.new()
    box.add_child(r5)
    auto_btn = _btn("Авто ✓", _auto_toggle)
    r5.add_child(auto_btn)
    gait_btn = _btn("Походка ✗", _gait_toggle)
    r5.add_child(gait_btn)
    var rg: HBoxContainer
    var gi := 0
    for g in groups:
        if gi % 4 == 0:
            rg = HBoxContainer.new()
            box.add_child(rg)
        var gb := _btn(_gtext(g), _toggle.bind(g), 60)
        group_btns[g] = gb
        rg.add_child(gb)
        gi += 1

func _build_extra_ui() -> void:
    var cl2 := CanvasLayer.new()
    cl2.layer = 5
    cl2.process_mode = Node.PROCESS_MODE_ALWAYS
    add_child(cl2)
    var mb := Button.new()
    mb.text = "☰"
    mb.add_theme_font_size_override("font_size", 34)
    mb.anchor_left = 1.0
    mb.anchor_right = 1.0
    mb.offset_left = -90
    mb.offset_right = -10
    mb.offset_top = 10
    mb.offset_bottom = 90
    mb.pressed.connect(func(): menu_box.visible = not menu_box.visible)
    cl2.add_child(mb)
    # окно экспорта / импорта
    panel_layer = CanvasLayer.new()
    panel_layer.layer = 10
    panel_layer.process_mode = Node.PROCESS_MODE_ALWAYS
    panel_layer.visible = false
    add_child(panel_layer)
    var bg := ColorRect.new()
    bg.color = Color(0, 0, 0, 0.92)
    bg.set_anchors_preset(Control.PRESET_FULL_RECT)
    panel_layer.add_child(bg)
    var v := VBoxContainer.new()
    v.set_anchors_preset(Control.PRESET_FULL_RECT)
    v.offset_left = 14
    v.offset_right = -14
    v.offset_top = 40
    v.offset_bottom = -40
    panel_layer.add_child(v)
    panel_title = Label.new()
    panel_title.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
    panel_title.add_theme_font_size_override("font_size", 24)
    v.add_child(panel_title)
    panel_text = TextEdit.new()
    panel_text.size_flags_vertical = Control.SIZE_EXPAND_FILL
    panel_text.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
    panel_text.add_theme_font_size_override("font_size", 18)
    v.add_child(panel_text)
    var hb := HBoxContainer.new()
    v.add_child(hb)
    hb.add_child(_btn("Копировать", _panel_copy))
    hb.add_child(_btn("Из буфера", _panel_paste))
    panel_apply_btn = _btn("Загрузить", _panel_apply)
    hb.add_child(panel_apply_btn)
    hb.add_child(_btn("Закрыть", _panel_close))

func _gtext(g: String) -> String:
    return ("%s ✓" if groups[g] else "%s ✗") % GROUP_NAMES[g]

func _toggle(g: String) -> void:
    groups[g] = not groups[g]
    _refresh_active()
    group_btns[g].text = _gtext(g)
    _log("%s: %s" % [GROUP_NAMES[g], "учатся" if groups[g] else "заморожены"])

func _log(s: String) -> void:
    log_box.append_text(s + "\n")

func _on_status(t: String) -> void:
    _log("[color=gray]%s[/color]" % t)

func _cmd(text: String) -> void:
    if text.strip_edges() == "":
        return
    input.clear()
    _log("[b]Ты:[/b] " + text)
    brain.ask_goal(text)

func _focus_targets() -> Array:
    if focus >= 0 and focus < agents.size():
        return [agents[focus]]
    return agents

# ручная оценка: выбранному человеку или всем, работает и в плюс, и в минус
func _reward(v: float) -> void:
    for a in _focus_targets():
        a.give(v)
    var who := "всем" if focus < 0 else "№%d" % (focus + 1)
    _log("[color=%s]%s (%s)[/color]" % ["lime" if v > 0 else "tomato", "Молодец (засчитаю, если не упадёт за 0.8 с)" if v > 0 else "Плохо!", who])

func _speed() -> void:
    speed_i = (speed_i + 1) % SPEEDS.size()
    Engine.time_scale = SPEEDS[speed_i]
    speed_btn.text = "x%d" % int(SPEEDS[speed_i])

# подвес: 0 выкл, 1 лёгкий, 2 средний, 3 сильный (не даёт упасть, можно учить шагать без равновесия)
func _support() -> void:
    set_support((support + 1) % SUPPORT_NAMES.size())

func set_support(l: int) -> void:
    support = l
    support_btn.text = "Подвес: %s" % SUPPORT_NAMES[support]
    baseline = true
    best = -1e9
    _restart_all()
    _log("Подвес: [b]%s[/b]. Оценки начинаются заново." % SUPPORT_NAMES[support])

func _focus_next() -> void:
    focus += 1
    if focus >= agents.size():
        focus = -1
    _update_labels_ui()

func _count_next() -> void:
    var n := n_agents % 4 + 1
    _spawn(n)
    _log("Людей: %d" % n)

func _update_labels_ui() -> void:
    if focus_btn:
        focus_btn.text = "Фокус: все" if focus < 0 else "Фокус: №%d" % (focus + 1)
    if count_btn:
        count_btn.text = "Людей: %d" % n_agents

func _screen() -> void:
    var vp := get_viewport()
    vp.disable_3d = not vp.disable_3d
    screen_btn.text = "Экран ✗" if vp.disable_3d else "Экран ✓"

func _pause() -> void:
    get_tree().paused = not get_tree().paused

# ---------- камера ----------
# режим 0: вращение вокруг людей (палец / мышь), щипок или колесо - приближение
# режим 1: свободный полёт: палец - повернуть, щипок - вперёд/назад, два пальца - сдвиг,
#          кнопки на экране, на компьютере W A S D Q E
func _frame_target() -> Vector3:
    var s := Vector3.ZERO
    var c := 0
    for a in _focus_targets():
        var p: Vector3 = a.root_pos()
        if p.is_finite():
            s += Vector3(p.x, 0.0, p.z)
            c += 1
    return s / float(maxi(c, 1))

func _orbit_dist() -> float:
    if focus >= 0 or agents.size() < 2:
        return cam_dist
    var span := float(agents.size() - 1) * SPACING + 1.6
    var vs := get_viewport().get_visible_rect().size
    var asp := vs.x / maxf(vs.y, 1.0)
    var hf := tan(deg_to_rad(cam.fov * 0.5)) * minf(asp, 1.6)
    var need := span * 0.5 / hf + 1.0
    return cam_dist * maxf(1.0, need / 4.0)

func _cam_update() -> void:
    if cam_mode == 0:
        var yaw := deg_to_rad(cam_yaw)
        var pit := deg_to_rad(cam_pitch)
        var tgt := cam_sm + Vector3(0, 0.9, 0)
        cam.position = tgt + Vector3(sin(yaw) * cos(pit), sin(pit), cos(yaw) * cos(pit)) * _orbit_dist()
        cam.look_at(tgt)
    else:
        cam.position = fpos
        cam.rotation = Vector3(deg_to_rad(-fpitch), deg_to_rad(fyaw), 0.0)

func _cam_toggle() -> void:
    if cam_mode == 0:
        cam_mode = 1
        fpos = cam.position
        fyaw = rad_to_deg(cam.rotation.y)
        fpitch = -rad_to_deg(cam.rotation.x)
    else:
        cam_mode = 0
    cam_btn.text = "Камера: вокруг" if cam_mode == 0 else "Камера: свободная"
    pad_root.visible = cam_mode == 1
    mv = Vector3.ZERO
    touches.clear()
    pinch_prev = 0.0

func _cam_reset() -> void:
    cam_yaw = 143.0
    cam_pitch = 12.0
    cam_dist = 4.0
    fpos = Vector3(0, 2.2, -7.0)
    fyaw = 180.0
    fpitch = 10.0

func _hold_btn(txt: String, pos: Vector2, dirv: Vector3) -> void:
    var b := Button.new()
    b.text = txt
    b.add_theme_font_size_override("font_size", 40)
    b.custom_minimum_size = Vector2(110, 110)
    b.size = Vector2(110, 110)
    b.position = pos
    b.modulate = Color(1, 1, 1, 0.55)
    b.button_down.connect(func(): mv += dirv)
    b.button_up.connect(func(): mv -= dirv)
    pad_root.add_child(b)

func _build_cam_pad() -> void:
    var cl := CanvasLayer.new()
    cl.layer = 3
    cl.process_mode = Node.PROCESS_MODE_ALWAYS
    add_child(cl)
    pad_root = Control.new()
    pad_root.set_anchors_preset(Control.PRESET_FULL_RECT)
    pad_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
    pad_root.visible = false
    cl.add_child(pad_root)
    # левый блок: вперёд / влево, назад, вправо; правый: вверх / вниз
    var y0 := 230.0
    _hold_btn("▲", Vector2(130, y0), Vector3(0, 0, 1))
    _hold_btn("◀", Vector2(15, y0 + 115), Vector3(-1, 0, 0))
    _hold_btn("▼", Vector2(130, y0 + 115), Vector3(0, 0, -1))
    _hold_btn("▶", Vector2(245, y0 + 115), Vector3(1, 0, 0))
    var vw := float(ProjectSettings.get_setting("display/window/size/viewport_width", 1080))
    _hold_btn("⤒", Vector2(vw - 125, y0), Vector3(0, 1, 0))
    _hold_btn("⤓", Vector2(vw - 125, y0 + 115), Vector3(0, -1, 0))

func _cam_free_area(p: Vector2) -> bool:
    if panel_layer.visible:
        return false
    return (not menu_box.visible) or not menu_box.get_global_rect().has_point(p)

func _look(rel: Vector2) -> void:
    if cam_mode == 0:
        cam_yaw -= rel.x * 0.35
        cam_pitch = clampf(cam_pitch + rel.y * 0.25, 2.0, 85.0)
    else:
        fyaw += rel.x * 0.2
        fpitch = clampf(fpitch + rel.y * 0.2, -89.0, 89.0)

func _unhandled_input(e: InputEvent) -> void:
    if e is InputEventScreenTouch:
        if e.pressed:
            if _cam_free_area(e.position):
                touches[e.index] = e.position
        else:
            touches.erase(e.index)
            pinch_prev = 0.0
    elif e is InputEventScreenDrag:
        if not touches.has(e.index):
            return
        touches[e.index] = e.position
        if touches.size() >= 2:
            var ks := touches.keys()
            var d: float = (touches[ks[0]] - touches[ks[1]]).length()
            if cam_mode == 0:
                if pinch_prev > 0.0:
                    cam_dist = clampf(cam_dist * pinch_prev / maxf(d, 1.0), 1.2, 25.0)
            else:
                var bs := cam.global_transform.basis
                if pinch_prev > 0.0:
                    fpos += -bs.z * (d - pinch_prev) * 0.012
                fpos += (-bs.x * e.relative.x + bs.y * e.relative.y) * 0.004
            pinch_prev = d
        else:
            _look(e.relative)
    elif e is InputEventMouseMotion and not DisplayServer.is_touchscreen_available():
        if e.button_mask & MOUSE_BUTTON_MASK_LEFT and _cam_free_area(e.position):
            _look(e.relative)
    elif e is InputEventMouseButton and e.pressed:
        var z := 0.0
        if e.button_index == MOUSE_BUTTON_WHEEL_UP:
            z = 1.0
        elif e.button_index == MOUSE_BUTTON_WHEEL_DOWN:
            z = -1.0
        if z != 0.0:
            if cam_mode == 0:
                cam_dist = clampf(cam_dist * (0.9 if z > 0 else 1.1), 1.2, 25.0)
            else:
                fpos += -cam.global_transform.basis.z * z * 0.6

# ---------- кадр ----------
func _process(_d: float) -> void:
    var now := Time.get_ticks_msec()
    var rd := clampf(float(now - last_ms) / 1000.0, 0.0, 0.1)
    last_ms = now
    var tgt := _frame_target()
    if tgt.is_finite():
        cam_sm = cam_sm.lerp(tgt, 1.0 - exp(-rd * 3.0))
    if cam_mode == 1:
        var m := mv
        if Input.is_key_pressed(KEY_W): m.z += 1.0
        if Input.is_key_pressed(KEY_S): m.z -= 1.0
        if Input.is_key_pressed(KEY_D): m.x += 1.0
        if Input.is_key_pressed(KEY_A): m.x -= 1.0
        if Input.is_key_pressed(KEY_E): m.y += 1.0
        if Input.is_key_pressed(KEY_Q): m.y -= 1.0
        var bs := cam.global_transform.basis
        fpos += (bs.x * m.x + Vector3.UP * m.y - bs.z * m.z) * 3.5 * rd
        fpos.y = maxf(fpos.y, 0.15)
    _cam_update()
    var p0 := agents[0].root_pos() as Vector3
    hud.text = "%s | эп. %d | лучший %.1f | σ %.2f\nлюдей %d | подвес: %s | фокус: %s\nСеть тела: %d весов ✓\nНейронка-переводчик: %s" % [GOALS[goal], eps, best if best > -1e8 else 0.0, sigma, agents.size(), SUPPORT_NAMES[support], "все" if focus < 0 else "№%d" % (focus + 1), n_w, brain.mode_text()]
