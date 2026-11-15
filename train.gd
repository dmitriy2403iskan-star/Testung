extends Node3D

const GOALS := {"walk": "ХОДЬБА", "jump": "ПРЫЖОК", "fly": "ПОЛЁТ", "stand": "СТОЙКА"}
const GROUP_NAMES := {"legs": "Ноги", "toes": "Стопы", "spine": "Корпус", "neck": "Шея", "arms": "Руки", "hands": "Кисти", "fingers": "Пальцы", "thrust": "Тяга"}
const N_HID := 16
const MUT_P := 0.08
const EP_STEPS := 360
const THRUST := 900.0
const LIFT := 0.03
const SAVE := "user://skills.json"
const SPEEDS := [1.0, 2.0, 4.0, 8.0, 16.0, 32.0]

var parts: Array = []
var init: Array = []
var joints: Array = []
var jgroup: Array = []
var jaxis: Array = []
var jba: Array = []
var jbb: Array = []
var feet: Array = []
var deco: Array = []
var act: Array = []
var group_btns := {}
var groups := {"legs": true, "toes": true, "spine": true, "neck": true, "arms": true, "hands": true, "fingers": false, "thrust": true}
var root: RigidBody3D
var cam: Camera3D
var n_j := 0
var n_in := 0
var n_out := 0
var n_w := 0
var skills := {}
var goal := "walk"
var w := PackedFloat32Array()
var cur_w := PackedFloat32Array()
var best := -1e9
var sigma := 0.1
var stall := 0
var eps := 0
var baseline := true
var step := -1
var bonus := 0.0
var sum_up := 0.0
var sum_h := 0.0
var max_h := 0.0
var thr := 0.0
var start := Vector3.ZERO
var speed_i := 0
var assist := true
var hud: Label
var log_box: RichTextLabel
var input: LineEdit
var speed_btn: Button
var assist_btn: Button
var screen_btn: Button
var brain

func _ready() -> void:
    Engine.max_physics_steps_per_frame = 64
    _build_world()
    _build_body()
    n_j = joints.size()
    n_in = 17 + n_j
    n_out = n_j + 3
    n_w = n_in * N_HID + N_HID + N_HID * n_out + n_out
    _refresh_active()
    _build_ui()
    _load()
    _set_goal("walk")
    brain = get_node("/root/Brain")
    brain.goal_ready.connect(_on_goal)
    if brain.last_status != "":
        _log("[color=gray]%s[/color]" % brain.last_status)
    _log("Тело: %d суставов (включая каждый палец). Нейросеть: %d входов → %d выходов, %d весов." % [n_j, n_in, n_out, n_w])
    _log("Пиши цель: «ходи вперёд», «прыгай», «лети», «стой». Пальцы пока заморожены — включи, когда пойдёт ходьба.")

func _exit_tree() -> void:
    _store()
    Engine.time_scale = 1.0
    Engine.max_physics_steps_per_frame = 8
    get_viewport().disable_3d = false
    get_tree().paused = false

# ---------- мир ----------
func _mesh(size: Vector3, col: Color, pos: Vector3) -> MeshInstance3D:
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
    cam = Camera3D.new()
    cam.far = 500.0
    add_child(cam)
    cam.position = Vector3(0, 3, 6)
    var sun := DirectionalLight3D.new()
    sun.rotation_degrees = Vector3(-55, 25, 0)
    add_child(sun)
    var env := Environment.new()
    env.background_mode = Environment.BG_COLOR
    env.background_color = Color(0.6, 0.75, 0.9)
    env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
    env.ambient_light_color = Color(0.65, 0.65, 0.65)
    var we := WorldEnvironment.new()
    we.environment = env
    add_child(we)
    var fl := StaticBody3D.new()
    var pm := PhysicsMaterial.new()
    pm.friction = 1.0
    fl.physics_material_override = pm
    var cs := CollisionShape3D.new()
    var bs := BoxShape3D.new()
    bs.size = Vector3(400, 1, 400)
    cs.shape = bs
    fl.add_child(cs)
    add_child(fl)
    fl.position = Vector3(0, -0.5, 0)
    _mesh(Vector3(400, 0.05, 400), Color(0.78, 0.78, 0.8), Vector3(0, -0.02, 0))
    for k in range(1, 13):
        _mesh(Vector3(0.3, 1.0, 0.3), Color(0.9, 0.3, 0.2), Vector3(-4, 0.5, -4.0 * k))
        _mesh(Vector3(0.3, 1.0, 0.3), Color(0.2, 0.4, 0.9), Vector3(4, 0.5, -4.0 * k))
    for p in [Vector3(-3, 0.6, -3), Vector3(3, 0.6, -6), Vector3(-4.5, 0.6, 2), Vector3(4.5, 0.6, -1)]:
        deco.append(_mesh(Vector3(0.8, 0.8, 0.8), Color(0.95, 0.8, 0.2), p))

# ---------- тело человека ----------
func _add_box(rb: RigidBody3D, size: Vector3, off: Vector3, col: Color) -> void:
    var cs := CollisionShape3D.new()
    var bs := BoxShape3D.new()
    bs.size = size
    cs.shape = bs
    cs.position = off
    rb.add_child(cs)
    var mi := MeshInstance3D.new()
    var bm := BoxMesh.new()
    bm.size = size
    var m := StandardMaterial3D.new()
    m.albedo_color = col
    bm.material = m
    mi.mesh = bm
    mi.position = off
    rb.add_child(mi)

func _part(size: Vector3, pos: Vector3, mass: float, col: Color, light := false) -> RigidBody3D:
    var rb := RigidBody3D.new()
    rb.mass = mass
    rb.can_sleep = false
    if light:
        rb.inertia = Vector3(0.0003, 0.0003, 0.0003)
    _add_box(rb, size, Vector3.ZERO, col)
    add_child(rb)
    rb.position = pos + Vector3(0, LIFT, 0)
    parts.append(rb)
    return rb

func _link(pos: Vector3) -> RigidBody3D:
    var rb := RigidBody3D.new()
    rb.mass = 0.5
    rb.can_sleep = false
    rb.collision_layer = 0
    rb.collision_mask = 0
    rb.inertia = Vector3(0.02, 0.02, 0.02)
    var cs := CollisionShape3D.new()
    var sp := SphereShape3D.new()
    sp.radius = 0.03
    cs.shape = sp
    rb.add_child(cs)
    add_child(rb)
    rb.position = pos + Vector3(0, LIFT, 0)
    parts.append(rb)
    return rb

func _hinge(a: RigidBody3D, b: RigidBody3D, pos: Vector3, axis: String, lo: float, hi: float, group: String, imp: float) -> void:
    var j := HingeJoint3D.new()
    add_child(j)
    j.position = pos + Vector3(0, LIFT, 0)
    if axis == "x":
        j.rotation_degrees = Vector3(0, 90, 0)
    elif axis == "y":
        j.rotation_degrees = Vector3(90, 0, 0)
    j.node_a = j.get_path_to(a)
    j.node_b = j.get_path_to(b)
    j.set_flag(HingeJoint3D.FLAG_USE_LIMIT, true)
    j.set_param(HingeJoint3D.PARAM_LIMIT_LOWER, deg_to_rad(lo))
    j.set_param(HingeJoint3D.PARAM_LIMIT_UPPER, deg_to_rad(hi))
    j.set_flag(HingeJoint3D.FLAG_ENABLE_MOTOR, true)
    j.set_param(HingeJoint3D.PARAM_MOTOR_MAX_IMPULSE, imp)
    joints.append(j)
    jgroup.append(group)
    jba.append(a)
    jbb.append(b)
    jaxis.append(a.global_transform.basis.inverse() * j.global_transform.basis.z)

# сустав с несколькими осями = цепочка шарниров через лёгкие «связки»
func _chain(a: RigidBody3D, b: RigidBody3D, pos: Vector3, axes: Array, group: String, imp: float) -> void:
    a.add_collision_exception_with(b)
    var prev := a
    for i in axes.size():
        var nxt := b
        if i < axes.size() - 1:
            nxt = _link(pos)
        var sp: Array = axes[i]
        _hinge(prev, nxt, pos, sp[0], sp[1], sp[2], group, imp)
        prev = nxt

func _build_body() -> void:
    var skin := Color(0.85, 0.7, 0.55)
    var uni := Color(0.3, 0.38, 0.25)
    var boot := Color(0.15, 0.15, 0.15)
    root = _part(Vector3(0.30, 0.16, 0.20), Vector3(0, 1.0, 0), 8.0, uni)
    var torso := _part(Vector3(0.34, 0.46, 0.22), Vector3(0, 1.31, 0), 14.0, uni)
    var head := _part(Vector3(0.2, 0.22, 0.22), Vector3(0, 1.65, 0), 4.0, skin)
    _chain(root, torso, Vector3(0, 1.08, 0), [["x", -30, 40], ["z", -25, 25], ["y", -35, 35]], "spine", 3.0)
    _chain(torso, head, Vector3(0, 1.54, 0), [["x", -40, 40], ["z", -30, 30], ["y", -70, 70]], "neck", 0.6)
    for s in [-1.0, 1.0]:
        var thigh := _part(Vector3(0.12, 0.44, 0.12), Vector3(s * 0.09, 0.70, 0), 6.0, uni)
        var shin := _part(Vector3(0.09, 0.40, 0.09), Vector3(s * 0.09, 0.28, 0), 3.5, uni)
        var foot := _part(Vector3(0.10, 0.08, 0.22), Vector3(s * 0.09, 0.04, -0.04), 1.2, boot)
        var toes := _part(Vector3(0.10, 0.04, 0.08), Vector3(s * 0.09, 0.02, -0.19), 0.3, boot)
        _chain(root, thigh, Vector3(s * 0.09, 0.92, 0), [["x", -30, 120], ["z", -45, 45], ["y", -40, 40]], "legs", 4.0)
        _chain(thigh, shin, Vector3(s * 0.09, 0.48, 0), [["x", -140, 5]], "legs", 4.0)
        _chain(shin, foot, Vector3(s * 0.09, 0.08, 0), [["x", -40, 25], ["z", -25, 25]], "legs", 2.0)
        _chain(foot, toes, Vector3(s * 0.09, 0.04, -0.15), [["x", -10, 60]], "toes", 0.3)
        feet.append(foot)
        var ua := _part(Vector3(0.09, 0.28, 0.09), Vector3(s * 0.23, 1.32, 0), 2.0, uni)
        var fa := _part(Vector3(0.08, 0.26, 0.08), Vector3(s * 0.23, 1.05, 0), 1.5, skin)
        var hand := _part(Vector3(0.09, 0.10, 0.04), Vector3(s * 0.23, 0.87, 0), 0.4, skin)
        _chain(torso, ua, Vector3(s * 0.23, 1.46, 0), [["x", -60, 170], ["z", -100, 100], ["y", -70, 70]], "arms", 1.2)
        _chain(ua, fa, Vector3(s * 0.23, 1.18, 0), [["x", -5, 140]], "arms", 1.0)
        _chain(fa, hand, Vector3(s * 0.23, 0.92, 0), [["x", -70, 70], ["z", -30, 30]], "hands", 0.3)
        for fi in 5:
            var fx: float = s * 0.23 + (fi - 2) * 0.018
            var prev := hand
            for seg in 3:
                var ph := _part(Vector3(0.014, 0.03, 0.014), Vector3(fx, 0.805 - 0.03 * seg, 0), 0.05, skin, true)
                _chain(prev, ph, Vector3(fx, 0.82 - 0.03 * seg, 0), [["x", -10, 100]], "fingers", 0.03)
                prev = ph
    for p in parts:
        init.append(p.global_transform)

func _reset_body() -> void:
    for i in parts.size():
        var rid: RID = parts[i].get_rid()
        PhysicsServer3D.body_set_state(rid, PhysicsServer3D.BODY_STATE_TRANSFORM, init[i])
        PhysicsServer3D.body_set_state(rid, PhysicsServer3D.BODY_STATE_LINEAR_VELOCITY, Vector3.ZERO)
        PhysicsServer3D.body_set_state(rid, PhysicsServer3D.BODY_STATE_ANGULAR_VELOCITY, Vector3.ZERO)

func _refresh_active() -> void:
    act = []
    for i in n_j:
        act.append(groups[jgroup[i]])
    for k in 3:
        act.append(groups["thrust"])

# ---------- нейросеть: видит угол каждого сустава, двигает мотор каждого ----------
func _policy(x: PackedFloat32Array, wt: PackedFloat32Array) -> PackedFloat32Array:
    var o1 := n_in * N_HID
    var o2 := o1 + N_HID
    var o3 := o2 + N_HID * n_out
    var h := PackedFloat32Array()
    h.resize(N_HID)
    for j in N_HID:
        var s: float = wt[o1 + j]
        var base := j * n_in
        for i in n_in:
            s += wt[base + i] * x[i]
        h[j] = tanh(s)
    var out := PackedFloat32Array()
    out.resize(n_out)
    for k in n_out:
        var s2: float = wt[o3 + k]
        var base2 := o2 + k * N_HID
        for j in N_HID:
            s2 += wt[base2 + j] * h[j]
        out[k] = tanh(s2)
    return out

func _sense() -> PackedFloat32Array:
    var b := root.global_transform.basis
    var inv := b.inverse()
    var lv := inv * root.linear_velocity * 0.3
    var av := inv * root.angular_velocity * 0.2
    var x := PackedFloat32Array([b.y.x, b.y.y, b.y.z, b.z.x, b.z.y, b.z.z,
        lv.x, lv.y, lv.z, av.x, av.y, av.z, root.global_position.y * 0.5])
    for f in feet:
        x.append(1.0 if f.global_position.y < 0.12 else 0.0)
    var t := step / 60.0
    x.append(sin(t * 6.0))
    x.append(cos(t * 6.0))
    for i in n_j:
        var rel: Basis = (jba[i].global_transform.basis.inverse() * jbb[i].global_transform.basis).orthonormalized()
        var q := Quaternion(rel)
        var u: Vector3 = jaxis[i]
        var d := q.x * u.x + q.y * u.y + q.z * u.z
        var sg := 1.0 if q.w >= 0.0 else -1.0
        x.append(2.0 * atan2(sg * d, absf(q.w)))
    return x

func _physics_process(_d: float) -> void:
    if step < 0:
        _reset_body()
        step = 0
        sum_up = 0.0
        sum_h = 0.0
        max_h = 0.0
        thr = 0.0
        start = init[0].origin
        return
    var out := _policy(_sense(), cur_w)
    for i in n_j:
        var v := out[i] * 6.0 if act[i] else 0.0
        joints[i].set_param(HingeJoint3D.PARAM_MOTOR_TARGET_VELOCITY, v)
    var f := Vector3(out[n_j], out[n_j + 1], out[n_j + 2]) if act[n_j] else Vector3.ZERO
    root.apply_central_force(root.global_transform.basis * (f * THRUST))
    if assist:
        var up := root.global_transform.basis.y
        root.apply_torque(up.cross(Vector3.UP) * 800.0 - root.angular_velocity * 120.0)
    var h := root.global_position.y
    sum_up += maxf(root.global_transform.basis.y.y, 0.0)
    sum_h += h
    max_h = maxf(max_h, h)
    thr += f.length()
    step += 1
    var pos := root.global_position
    var fell := goal != "fly" and h < 0.4 and step > 40
    if step >= EP_STEPS or fell or not pos.is_finite() or pos.length() > 400.0:
        _end_episode()

# ---------- награда и обучение ----------
func _score() -> float:
    var n := float(EP_STEPS)
    var upr := sum_up / n
    var hm := sum_h / n
    var th := thr / n
    var p := root.global_position
    var fwd := start.z - p.z
    var drift := Vector2(p.x - start.x, p.z - start.z).length()
    if goal == "walk":
        return 3.0 * fwd + 1.5 * upr - 0.5 * th
    if goal == "jump":
        return 4.0 * maxf(0.0, max_h - 1.2) + upr - th
    if goal == "fly":
        return clampf(hm, 0.0, 8.0) + 0.5 * upr
    return 2.0 * upr + clampf(hm, 0.0, 1.0) - th - 0.5 * drift

func _mutate() -> PackedFloat32Array:
    var c := w.duplicate()
    var o1 := n_in * N_HID
    var o2 := o1 + N_HID
    var o3 := o2 + N_HID * n_out
    for i in o2:
        if randf() < MUT_P:
            c[i] += randfn(0.0, sigma)
    for k in n_out:
        if not act[k]:
            continue
        for j in N_HID:
            if randf() < MUT_P:
                c[o2 + k * N_HID + j] += randfn(0.0, sigma)
        if randf() < MUT_P:
            c[o3 + k] += randfn(0.0, sigma)
    return c

func _end_episode() -> void:
    var ok := root.global_position.is_finite()
    var auto_sc := _score() if ok else -100.0
    var sc := auto_sc + bonus
    eps += 1
    if baseline:
        best = auto_sc
        baseline = false
        _log("Старт: %.1f" % auto_sc)
    elif sc > best:
        best = auto_sc
        w = cur_w.duplicate()
        stall = 0
        sigma = minf(sigma * 1.1, 0.3)
        _log("Эп. %d: лучше! %.1f" % [eps, auto_sc])
        _store()
    else:
        stall += 1
        if stall > 12:
            sigma = maxf(sigma * 0.9, 0.02)
            stall = 0
    bonus = 0.0
    cur_w = _mutate()
    step = -1

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
            w[i] = randfn(0.0, 0.1)
        eps = 0
    cur_w = w.duplicate()
    baseline = true
    best = -1e9
    sigma = 0.1
    stall = 0
    bonus = 0.0
    step = -1
    _log("Цель: [b]%s[/b]" % GOALS[g])

func _on_goal(g: String) -> void:
    _set_goal(g)

# ---------- сохранение / экспорт умений ----------
func _store() -> void:
    if w.size() != n_w or n_w == 0:
        return
    var arr: Array = []
    for v in w:
        arr.append(snappedf(v, 0.0001))
    skills[goal] = {"w": arr, "eps": eps, "best": best}
    var f := FileAccess.open(SAVE, FileAccess.WRITE)
    if f:
        f.store_string(JSON.stringify(skills))

func _load() -> void:
    if FileAccess.file_exists(SAVE):
        var j = JSON.parse_string(FileAccess.get_file_as_string(SAVE))
        if j is Dictionary:
            skills = j

func _export() -> void:
    _store()
    var s := JSON.stringify(skills)
    DisplayServer.clipboard_set(s)
    _log("Умения скопированы в буфер (%d КБ). Вставь в заметки или отправь себе." % (s.length() / 1024))

func _import() -> void:
    var j = JSON.parse_string(DisplayServer.clipboard_get())
    if j is Dictionary and not j.is_empty():
        w = PackedFloat32Array()
        skills = j
        _set_goal(goal)
        _log("Умения загружены из буфера.")
    else:
        _log("В буфере нет умений.")

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
    box.offset_top = -660
    box.offset_bottom = -10
    cl.add_child(box)
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
    assist_btn = _btn("Опора ✓", _assist)
    r2.add_child(assist_btn)
    screen_btn = _btn("Экран ✓", _screen)
    r2.add_child(screen_btn)
    var r3 := HBoxContainer.new()
    box.add_child(r3)
    r3.add_child(_btn("Пауза", _pause))
    r3.add_child(_btn("Экспорт", _export))
    r3.add_child(_btn("Импорт", _import))
    r3.add_child(_btn("Сброс", _reset_skill))
    r3.add_child(_btn("Назад", _back))
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

func _gtext(g: String) -> String:
    return ("%s ✓" if groups[g] else "%s ✗") % GROUP_NAMES[g]

func _toggle(g: String) -> void:
    groups[g] = not groups[g]
    _refresh_active()
    group_btns[g].text = _gtext(g)
    _log("%s: %s" % [GROUP_NAMES[g], "учатся" if groups[g] else "заморожены"])

func _log(s: String) -> void:
    log_box.append_text(s + "\n")

func _cmd(text: String) -> void:
    if text.strip_edges() == "":
        return
    input.clear()
    _log("[b]Ты:[/b] " + text)
    brain.ask_goal(text)

func _reward(v: float) -> void:
    bonus += v
    _log("[color=%s]%s[/color]" % ["lime" if v > 0 else "tomato", "Молодец!" if v > 0 else "Плохо!"])

func _speed() -> void:
    speed_i = (speed_i + 1) % SPEEDS.size()
    Engine.time_scale = SPEEDS[speed_i]
    speed_btn.text = "x%d" % int(SPEEDS[speed_i])

func _assist() -> void:
    assist = not assist
    assist_btn.text = "Опора ✓" if assist else "Опора ✗"

func _screen() -> void:
    var vp := get_viewport()
    vp.disable_3d = not vp.disable_3d
    screen_btn.text = "Экран ✗" if vp.disable_3d else "Экран ✓"

func _pause() -> void:
    get_tree().paused = not get_tree().paused

func _back() -> void:
    get_tree().change_scene_to_file("res://main.tscn")

func _process(d: float) -> void:
    for i in deco.size():
        deco[i].rotation.y += d * (0.5 + i * 0.3)
        deco[i].position.y = 0.6 + 0.3 * sin(Time.get_ticks_msec() / 500.0 + i)
    var tp := root.global_position
    if tp.is_finite():
        cam.global_position = cam.global_position.lerp(tp + Vector3(0, 2.5, 5.5), 0.1)
        cam.look_at(tp + Vector3(0, 0.3, 0))
    hud.text = "%s | эп. %d | лучший %.1f | σ %.2f\nшаг %d/%d | бонус %+.0f | высота %.1f" % [GOALS[goal], eps, best if best > -1e8 else 0.0, sigma, maxi(step, 0), EP_STEPS, bonus, tp.y]