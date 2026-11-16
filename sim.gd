extends Node3D
# Один человек (модель human.glb, 53 кости, с пальцами) на пустой площадке.
# Каждая кость - физическое тело, суставы - Generic6DOF с лимитами углов.
# Нейросеть выдаёт целевой угол для каждой оси каждого сустава, PD-регулятор крутит.
# Нулевой выход = держать исходную позу, поэтому модель сразу стоит.

const GOALS := {"stand": "СТОЯТЬ", "walk": "ИДТИ", "jump": "ПРЫГАТЬ", "fly": "ЛЕТАТЬ"}
const GROUP_NAMES := {"legs": "Ноги", "toes": "Стопы", "spine": "Корпус", "neck": "Шея", "arms": "Руки", "hands": "Кисти", "fingers": "Пальцы", "thrust": "Тяга"}
const N_HID := 16
const MUT_P := 0.05
const EP_SECONDS := 6.0
const THRUST := 700.0
const LIFT := 0.02
const SAVE := "user://skills_v2.json"
const SPEEDS := [1.0, 2.0, 4.0, 8.0, 16.0, 32.0]
const FINGERS := ["index", "middle", "ring", "pinky", "thumb"]

var sk: Skeleton3D
var human: Node3D
var cam: Camera3D
var cam_yaw := 143.0     # вращение вокруг человека (градусы)
var cam_pitch := 12.0
var cam_dist := 4.0
var free_cam := false
var free_cam_pos := Vector3(3.5, 2.2, 5.5)
var free_cam_yaw := 145.0
var free_cam_pitch := -12.0
var cam_move_speed := 5.0
var agent_clones: Array = []
var agent_skeletons: Array = []
var agent_labels: Array = []
var agent_quality := 0.0
var agent_skills: Array = []
var agent_weights: Array = []
var agent_cur_weights: Array = []
var agent_best: Array = []
var agent_eps: Array = []
var freeze_mode := false
var freeze_snapshot: Array = []
var freeze_target: Array = []
var last_quality := 0.0
var last_good_quality := -1.0
var last_good_w := PackedFloat32Array()
var reward_trace: Array = []
var action_lock := true
var reward_decay := 0.0
var touches := {}
var pinch_prev := 0.0
var menu_box: VBoxContainer
var panel_layer: CanvasLayer
var panel_text: TextEdit
var panel_title: Label
var panel_apply_btn: Button
var cam_sm := Vector3.ZERO
var cam_joy_layer: CanvasLayer
var cam_move_pad: Panel
var cam_look_pad: Panel
var cam_move_vec := Vector2.ZERO
var cam_look_vec := Vector2.ZERO
var last_ms := 0
var gain_sat := 0.15     # ошибка угла (рад), при которой момент достигает максимума
var kd_ratio := 0.1     # демпфирование относительно жёсткости
var c_max := 0.6         # предел устойчивости явного PD (меньше = устойчивее)
var b_ext: Array = []

# тело
var bodies: Array = []        # RigidBody3D на каждую физическую кость
var b_bone: Array = []        # индекс кости скелета
var b_offset: Array = []      # Transform3D: bone_world = body_world * offset
var b_init: Array = []        # стартовые мировые трансформы тел
var j_parent: Array = []      # индекс тела-родителя (или -1)
var j_p0: Array = []          # Basis родителя в покое
var j_c0: Array = []          # Basis ребёнка в покое
var j_frame: Array = []       # Basis оси сустава в покое (мировая)
var root_i := 0
var feet_i: Array = []
# степени свободы
var d_j: Array = []
var d_a: Array = []
var d_lo: Array = []
var d_hi: Array = []
var d_kp: Array = []
var d_kd: Array = []
var d_t: Array = []
var d_g: Array = []
var act: Array = []
var group_btns := {}
var groups := {"legs": true, "toes": true, "spine": true, "neck": true, "arms": true, "hands": true, "fingers": false, "thrust": true}
var root_rest_inv := Basis()
var h0 := 0.9
var n_dof := 0
var n_in := 0
var n_out := 0
var n_w := 0
var jvec: Array = []
var jaxes: Array = []
var jom: Array = []

var skills := {}
var goal := "stand"
var w := PackedFloat32Array()
var cur_w := PackedFloat32Array()
var best := -1e9
var sigma := 0.05
var stall := 0
var eps := 0
var baseline := true
var step := -1
var ep_steps := 720
var dt := 1.0 / 120.0
var bonus := 0.0
var sum_up := 0.0
var sum_h := 0.0
var max_h := 0.0
var thr := 0.0
var eff := 0.0
var start := Vector3.ZERO
var speed_i := 0
var assist := false
var hud: Label
var log_box: RichTextLabel
var input: LineEdit
var speed_btn: Button
var assist_btn: Button
var screen_btn: Button
var brain

func _ready() -> void:
    dt = 1.0 / float(Engine.physics_ticks_per_second)
    ep_steps = int(EP_SECONDS / dt)
    Engine.max_physics_steps_per_frame = 64
    _build_world()
    _build_body()
    _build_training_agents()
    var main_label := Label3D.new()
    main_label.text = "УЧЕНИК 1"
    main_label.font_size = 64
    main_label.outline_size = 10
    main_label.position = Vector3(0, 1.75, 0)
    human.add_child(main_label)
    _refresh_active()
    n_in = 17 + n_dof
    n_out = n_dof + 3
    n_w = n_in * N_HID + N_HID + N_HID * n_out + n_out
    _init_agent_learners()
    _build_ui()
    _build_extra_ui()
    _load()
    _set_goal("stand")
    brain = get_node("/root/Brain")
    brain.goal_ready.connect(_on_goal)
    brain.status.connect(_on_status)
    if brain.last_status != "":
        _log("[color=gray]%s[/color]" % brain.last_status)
    _log("Человек: %d костей-тел, %d степеней свободы. Нейросеть: %d входов, %d выходов, %d весов." % [bodies.size(), n_dof, n_in, n_out, n_w])
    _log("Пиши цель: «стой», «ходи вперёд», «прыгай», «лети». Пальцы заморожены, включи кнопкой когда устоит.")
    last_ms = Time.get_ticks_msec()

func _exit_tree() -> void:
    _store()
    Engine.time_scale = 1.0
    Engine.max_physics_steps_per_frame = 8
    get_viewport().disable_3d = false
    get_tree().paused = false

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

# ---------- описание костей ----------
# ax: оси сустава (x,y,z в мировых осях покоя) и пределы в градусах. Остальные оси заперты.
func _spec(n: String) -> Dictionary:
    var side := -1.0 if n.ends_with("_r") else 1.0
    var b := n.trim_suffix("_l").trim_suffix("_r")
    match b:
        "spine_01": return {"g": "spine", "m": 4.0, "t": 120.0, "ax": {"x": [-20, 30], "y": [-20, 20], "z": [-15, 15]}}
        "spine_02": return {"g": "spine", "m": 6.0, "t": 100.0, "ax": {"x": [-15, 20], "z": [-10, 10]}}
        "spine_03": return {"g": "spine", "m": 12.0, "t": 80.0, "ax": {"x": [-15, 20], "z": [-10, 10]}}
        "neck_01": return {"g": "neck", "m": 1.0, "t": 20.0, "ax": {"x": [-30, 40], "z": [-30, 30]}}
        "head": return {"g": "neck", "m": 5.0, "t": 12.0, "ax": {"x": [-35, 40], "y": [-60, 60], "z": [-30, 30]}}
        "clavicle": return {"g": "arms", "m": 1.0, "t": 30.0, "ax": {"y": [-15, 15], "z": [-15, 15]}}
        "upperarm":
            var zr := [-40, 130] if side > 0 else [-130, 40]
            return {"g": "arms", "m": 2.2, "t": 40.0, "ax": {"x": [-170, 60], "y": [-80, 80], "z": zr}}
        "lowerarm": return {"g": "arms", "m": 1.4, "t": 25.0, "ax": {"x": [-130, 10], "y": [-70, 70]}}
        "hand": return {"g": "hands", "m": 0.5, "t": 6.0, "ax": {"x": [-50, 50], "z": [-25, 25]}}
        "thigh":
            var zr2 := [-25, 45] if side > 0 else [-45, 25]
            return {"g": "legs", "m": 8.0, "t": 200.0, "ax": {"x": [-110, 30], "y": [-35, 35], "z": zr2}}
        "calf": return {"g": "legs", "m": 3.5, "t": 160.0, "ax": {"x": [-3, 135]}}
        "foot": return {"g": "legs", "m": 1.0, "t": 90.0, "ax": {"x": [-25, 45], "z": [-15, 15]}}
        "ball": return {"g": "toes", "m": 0.4, "t": 25.0, "ax": {"x": [-50, 10]}}
    for f in FINGERS:
        if b.begins_with(f):
            return {"g": "fingers", "m": 0.05 if f == "thumb" else 0.03, "t": 0.03, "ax": {"x": [-80, 80]}, "own_frame": true}
    return {}

func _bone_by_name(n: String) -> int:
    return sk.find_bone(n)

func _tail_of(i: int) -> Vector3:
    var n := sk.get_bone_name(i)
    var hp := _world_rest(i).origin
    var kids := sk.get_bone_children(i)
    if n == "spine_03":
        return _world_rest(_bone_by_name("neck_01")).origin
    if n.begins_with("hand"):
        var s := Vector3.ZERO
        var c := 0
        for k in kids:
            var kn := sk.get_bone_name(k)
            if kn.begins_with("thumb"):
                continue
            s += _world_rest(k).origin
            c += 1
        return s / float(max(c, 1))
    if n == "head":
        return hp + Vector3(0, 0.146, 0.03)
    if n.begins_with("ball"):
        return hp + Vector3(0, 0, 0.09)
    if kids.size() > 0:
        return _world_rest(kids[0]).origin
    var par := sk.get_bone_parent(i)
    return hp + (hp - _world_rest(par).origin) * 0.8

func _world_rest(i: int) -> Transform3D:
    return human.global_transform * sk.get_bone_global_rest(i)

func _cap(r: float, l: float) -> CapsuleShape3D:
    var c := CapsuleShape3D.new()
    c.radius = r
    c.height = maxf(l + r, 2.0 * r + 0.002)
    return c

func _box(x: float, y: float, z: float) -> BoxShape3D:
    var b := BoxShape3D.new()
    b.size = Vector3(x, y, z)
    return b

# возвращает {shape, xf, coll}
func _shape_for(n: String, hp: Vector3, tp: Vector3) -> Dictionary:
    var b := n.trim_suffix("_l").trim_suffix("_r")
    var mid := (hp + tp) * 0.5
    var dir := (tp - hp)
    var L := dir.length()
    var xf_i := Transform3D(Basis(), mid)
    match b:
        "pelvis": return {"shape": _box(0.28, 0.16, 0.19), "xf": Transform3D(Basis(), hp + Vector3(0, 0.02, 0)), "coll": true}
        "spine_01": return {"shape": _box(0.26, 0.09, 0.17), "xf": xf_i, "coll": true}
        "spine_02": return {"shape": _box(0.28, 0.08, 0.18), "xf": xf_i, "coll": true}
        "spine_03": return {"shape": _box(0.32, L, 0.2), "xf": xf_i, "coll": true}
        "head": return {"shape": _cap(0.085, 0.19), "xf": Transform3D(Basis(), Vector3(hp.x, hp.y + 0.075, hp.z + 0.02)), "coll": true}
        "foot": return {"shape": _box(0.09, 0.07, 0.2), "xf": Transform3D(Basis(), Vector3(hp.x, LIFT + 0.035, (hp.z + tp.z) * 0.5 + 0.02)), "coll": true}
        "ball": return {"shape": _box(0.09, 0.03, 0.09), "xf": Transform3D(Basis(), Vector3(hp.x, LIFT + 0.015, hp.z + 0.045)), "coll": true}
    var r := 0.04
    var coll := true
    match b:
        "neck_01": r = 0.045
        "clavicle": r = 0.035
        "upperarm": r = 0.045
        "lowerarm": r = 0.035
        "hand": r = 0.03
        "thigh": r = 0.075
        "calf": r = 0.055
    for f in FINGERS:
        if b.begins_with(f):
            r = 0.007
            coll = false
    var d := dir.normalized() if L > 1e-5 else Vector3.UP
    var q := Quaternion(Vector3.UP, d)
    return {"shape": _cap(r, L), "xf": Transform3D(Basis(q), mid), "coll": coll}

# ---------- тело человека ----------
func _init_agent_learners() -> void:
    agent_skills.resize(4)
    agent_weights.resize(4)
    agent_cur_weights.resize(4)
    agent_best.resize(4)
    agent_eps.resize(4)
    for i in 4:
        agent_skills[i] = {}
        var aw := PackedFloat32Array()
        aw.resize(n_w)
        for k in n_w:
            aw[k] = randfn(0.0, 0.03)
        agent_weights[i] = aw
        agent_cur_weights[i] = aw.duplicate()
        agent_best[i] = -1e9
        agent_eps[i] = 0

func _agent_pos(i: int) -> Vector3:
    var spots := [Vector3(-3.0, LIFT, 0.0), Vector3(0.0, LIFT, 0.0), Vector3(3.0, LIFT, 0.0), Vector3(0.0, LIFT, 3.0)]
    return spots[clampi(i, 0, 3)]

func _snapshot_freeze() -> void:
    freeze_snapshot = []
    freeze_target = []
    for k in bodies.size():
        freeze_snapshot.append((bodies[k] as RigidBody3D).global_transform)
        freeze_target.append((bodies[k] as RigidBody3D).global_transform)

func _apply_freeze_support() -> void:
    # Training scaffold: no gravity-like drifting between actions. Every physical
    # segment is softly returned to the pose reached by the learner.
    if not freeze_mode or freeze_snapshot.size() != bodies.size():
        return
    for k in bodies.size():
        var rb: RigidBody3D = bodies[k]
        var target: Transform3D = freeze_target[k]
        var dp := target.origin - rb.global_position
        rb.apply_central_force(dp * 900.0 - rb.linear_velocity * 80.0)
        var q := (target.basis * rb.global_transform.basis.inverse()).get_rotation_quaternion()
        var axis := Vector3(q.x, q.y, q.z) * (2.0 if q.w >= 0.0 else -2.0)
        rb.apply_torque(axis * 700.0 - rb.angular_velocity * 55.0)

func _toggle_freeze() -> void:
    freeze_mode = not freeze_mode
    if freeze_mode:
        _snapshot_freeze()
        _log("[color=cyan]Фиксация: ВКЛ — мягко удерживаем текущую позу.[/color]")
    else:
        for rb in bodies:
            rb.linear_velocity *= 0.35
            rb.angular_velocity *= 0.35
        _log("[color=orange]Фиксация: ВЫКЛ — обычная свободная физика.[/color]")

func _build_camera_joysticks() -> void:
    cam_joy_layer = CanvasLayer.new()
    cam_joy_layer.layer = 20
    cam_joy_layer.process_mode = Node.PROCESS_MODE_ALWAYS
    add_child(cam_joy_layer)

    cam_move_pad = _make_joy_pad("✥")
    cam_move_pad.anchor_left = 0.0
    cam_move_pad.anchor_top = 1.0
    cam_move_pad.anchor_right = 0.0
    cam_move_pad.anchor_bottom = 1.0
    cam_move_pad.offset_left = 28
    cam_move_pad.offset_top = -220
    cam_move_pad.offset_right = 218
    cam_move_pad.offset_bottom = -30
    cam_move_pad.gui_input.connect(_cam_move_pad_input)
    cam_joy_layer.add_child(cam_move_pad)

    cam_look_pad = _make_joy_pad("◉")
    cam_look_pad.anchor_left = 1.0
    cam_look_pad.anchor_top = 1.0
    cam_look_pad.anchor_right = 1.0
    cam_look_pad.anchor_bottom = 1.0
    cam_look_pad.offset_left = -218
    cam_look_pad.offset_top = -220
    cam_look_pad.offset_right = -28
    cam_look_pad.offset_bottom = -30
    cam_look_pad.gui_input.connect(_cam_look_pad_input)
    cam_joy_layer.add_child(cam_look_pad)
    _update_free_cam_ui()

func _make_joy_pad(t: String) -> Panel:
    var p := Panel.new()
    p.custom_minimum_size = Vector2(190, 190)
    p.mouse_filter = Control.MOUSE_FILTER_STOP
    var sb := StyleBoxFlat.new()
    sb.bg_color = Color(0.05, 0.05, 0.05, 0.32)
    sb.border_width_left = 3
    sb.border_width_top = 3
    sb.border_width_right = 3
    sb.border_width_bottom = 3
    sb.border_color = Color(1, 1, 1, 0.35)
    sb.corner_radius_top_left = 95
    sb.corner_radius_top_right = 95
    sb.corner_radius_bottom_left = 95
    sb.corner_radius_bottom_right = 95
    p.add_theme_stylebox_override("panel", sb)
    var l := Label.new()
    l.text = t
    l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
    l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
    l.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
    l.add_theme_font_size_override("font_size", 54)
    l.modulate = Color(1, 1, 1, 0.55)
    l.mouse_filter = Control.MOUSE_FILTER_IGNORE
    p.add_child(l)
    return p

func _update_free_cam_ui() -> void:
    if cam_joy_layer:
        cam_joy_layer.visible = free_cam
        if not free_cam:
            cam_move_vec = Vector2.ZERO
            cam_look_vec = Vector2.ZERO

func _joy_vec(pad: Control, pos: Vector2) -> Vector2:
    var center := pad.size * 0.5
    return ((pos - center) / maxf(pad.size.x * 0.42, 1.0)).limit_length(1.0)

func _cam_move_pad_input(ev: InputEvent) -> void:
    if ev is InputEventScreenTouch:
        cam_move_vec = _joy_vec(cam_move_pad, ev.position) if ev.pressed else Vector2.ZERO
    elif ev is InputEventScreenDrag:
        cam_move_vec = _joy_vec(cam_move_pad, ev.position)

func _cam_look_pad_input(ev: InputEvent) -> void:
    if ev is InputEventScreenTouch:
        cam_look_vec = _joy_vec(cam_look_pad, ev.position) if ev.pressed else Vector2.ZERO
    elif ev is InputEventScreenDrag:
        cam_look_vec = _joy_vec(cam_look_pad, ev.position)

func _toggle_free_cam() -> void:
    free_cam = not free_cam
    if free_cam:
        free_cam_pos = cam.global_position
        free_cam_yaw = cam_yaw
        free_cam_pitch = cam_pitch
    _update_free_cam_ui()
    _log("[color=cyan]Свободная камера: %s[/color]" % ("ВКЛ — левый джойстик движение, правый обзор" if free_cam else "ВЫКЛ"))

func _unhandled_input(ev: InputEvent) -> void:
    if free_cam:
        return
    if ev is InputEventScreenTouch:
        if ev.pressed:
            touches[ev.index] = ev.position
        else:
            touches.erase(ev.index)
            pinch_prev = 0.0
    elif ev is InputEventScreenDrag and touches.has(ev.index):
        touches[ev.index] = ev.position
        if touches.size() >= 2:
            var ks := touches.keys()
            var d: float = (touches[ks[0]] - touches[ks[1]]).length()
            if pinch_prev > 0.0:
                cam_dist = clampf(cam_dist * pinch_prev / maxf(d, 1.0), 1.2, 15.0)
            pinch_prev = d
        else:
            cam_yaw -= ev.relative.x * 0.35
            cam_pitch = clampf(cam_pitch + ev.relative.y * 0.25, 2.0, 85.0)
    elif ev is InputEventMouseMotion and ev.button_mask & MOUSE_BUTTON_MASK_LEFT:
        cam_yaw -= ev.relative.x * 0.35
        cam_pitch = clampf(cam_pitch + ev.relative.y * 0.25, 2.0, 85.0)
    elif ev is InputEventMouseButton and ev.pressed:
        if ev.button_index == MOUSE_BUTTON_WHEEL_UP:
            cam_dist = clampf(cam_dist * 0.9, 1.2, 15.0)
        elif ev.button_index == MOUSE_BUTTON_WHEEL_DOWN:
            cam_dist = clampf(cam_dist * 1.1, 1.2, 15.0)

# ---------- кадр: кости скелета повторяют физические тела ----------
func _process(_d: float) -> void:
    var now := Time.get_ticks_msec()
    var rd := clampf(float(now - last_ms) / 1000.0, 0.0, 0.1)
    last_ms = now
    var rb: RigidBody3D = bodies[root_i]
    var tp := rb.global_position
    if tp.is_finite():
        var tgt := Vector3(tp.x, 0.0, tp.z)
        cam_sm = cam_sm.lerp(tgt, 1.0 - exp(-rd * 3.0))
    if free_cam:
        var move := Vector3(cam_move_vec.x, 0.0, cam_move_vec.y)
        var yaw := deg_to_rad(free_cam_yaw)
        var forward := Vector3(sin(yaw), 0.0, cos(yaw))
        var right := Vector3(cos(yaw), 0.0, -sin(yaw))
        if move.length_squared() > 0.001:
            free_cam_pos += (right * move.x + forward * move.z) * cam_move_speed * rd
        if cam_look_vec.length_squared() > 0.001:
            free_cam_yaw -= cam_look_vec.x * 2.2 * rd * 60.0
            free_cam_pitch = clampf(free_cam_pitch + cam_look_vec.y * 1.5 * rd * 60.0, -85.0, 85.0)
    _cam_update()
    _mirror_training_agents()
    var inv := sk.global_transform.affine_inverse()
    for k in bodies.size():
        var bw: Transform3D = (bodies[k] as RigidBody3D).global_transform * (b_offset[k] as Transform3D)
        sk.set_bone_global_pose_override(b_bone[k], inv * bw, 1.0, true)
    hud.text = "%s | эп. %d | лучший %.1f | σ %.2f\nшаг %d/%d | бонус %+.0f | высота %.2f\nСеть тела: %d весов ✓\nНейронка-переводчик: %s" % [GOALS[goal], eps, best if best > -1e8 else 0.0, sigma, maxi(step, 0), ep_steps, bonus, tp.y, n_w, brain.mode_text()]
