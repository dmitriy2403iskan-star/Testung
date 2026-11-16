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
    _refresh_active()
    n_in = 17 + n_dof
    n_out = n_dof + 3
    n_w = n_in * N_HID + N_HID + N_HID * n_out + n_out
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
func _build_training_agents() -> void:
    # Four training slots: one active physical learner + three visual observers.
    # Observers mirror the active pose so the same movement can be judged side-by-side.
    for i in 4:
        var inst := (load("res://human.glb") as PackedScene).instantiate()
        add_child(inst)
        inst.position = Vector3((i - 1.5) * 1.25, LIFT, 1.8)
        inst.scale = Vector3.ONE * 0.92
        var ss := inst.find_child("Skeleton3D", true, false)
        agent_clones.append(inst)
        agent_skeletons.append(ss)
        var lab := Label3D.new()
        lab.text = "УЧЕНИК %d" % (i + 1)
        lab.font_size = 64
        lab.outline_size = 10
        lab.modulate = Color(1, 1, 1, 1)
        lab.position = Vector3(0, 1.75, 0)
        inst.add_child(lab)
        agent_labels.append(lab)

func _mirror_training_agents() -> void:
    if agent_skeletons.is_empty():
        return
    var inv := sk.global_transform.affine_inverse()
    for n in agent_skeletons.size():
        var ss: Skeleton3D = agent_skeletons[n]
        var inst: Node3D = agent_clones[n]
        inst.position = Vector3((n - 1.5) * 1.25, LIFT, 1.8)
        for k in bodies.size():
            ss.set_bone_global_pose_override(b_bone[k], inv * ((bodies[k] as RigidBody3D).global_transform * (b_offset[k] as Transform3D)), 1.0, true)
        agent_labels[n].text = "УЧЕНИК %d  %s" % [n + 1, _quality_mark(agent_quality)]

func _quality_mark(q: float) -> String:
    if q >= 0.82:
        return "✓ ОТЛИЧНО"
    if q >= 0.62:
        return "✓ ХОРОШО"
    if q >= 0.40:
        return "… СТАБИЛЬНО"
    return "⚠ НЕ ОЧЕНЬ"

func _build_body() -> void:
    human = (load("res://human.glb") as PackedScene).instantiate()
    add_child(human)
    human.position = Vector3(0, LIFT, 0)
    sk = human.find_child("Skeleton3D", true, false)
    var idx_of := {}   # bone -> индекс тела
    for i in sk.get_bone_count():
        var n := sk.get_bone_name(i)
        if n == "Root":
            continue
        var sp := _spec(n)
        var is_pelvis := n == "pelvis"
        if sp.is_empty() and not is_pelvis:
            continue
        var hp := _world_rest(i).origin
        var tp := _tail_of(i)
        var sh := _shape_for(n, hp, tp)
        var rb := RigidBody3D.new()
        rb.mass = 11.0 if is_pelvis else float(sp["m"])
        rb.can_sleep = false
        rb.linear_damp = 0.05
        rb.angular_damp = 1.5
        rb.collision_layer = 2 if sh["coll"] else 0
        rb.collision_mask = 1 if sh["coll"] else 0
        var cs := CollisionShape3D.new()
        cs.shape = sh["shape"]
        rb.add_child(cs)
        add_child(rb)
        var xf: Transform3D = sh["xf"]
        rb.global_transform = xf
        bodies.append(rb)
        b_ext.append(_ext_of(sh["shape"]))
        b_bone.append(i)
        idx_of[i] = bodies.size() - 1
        var bw := _world_rest(i)
        b_offset.append(xf.affine_inverse() * Transform3D(bw.basis.orthonormalized(), bw.origin))
        b_init.append(xf)
        if is_pelvis:
            root_i = bodies.size() - 1
            root_rest_inv = xf.basis.inverse()
            h0 = hp.y
        if n.begins_with("foot"):
            feet_i.append(bodies.size() - 1)
    # суставы
    for k in bodies.size():
        var i: int = b_bone[k]
        var n := sk.get_bone_name(i)
        if k == root_i:
            j_parent.append(-1)
            j_p0.append(Basis())
            j_c0.append(Basis())
            j_frame.append(Basis())
            continue
        var par := sk.get_bone_parent(i)
        while par >= 0 and not idx_of.has(par):
            par = sk.get_bone_parent(par)
        var pk: int = idx_of[par]
        j_parent.append(pk)
        var pb: RigidBody3D = bodies[pk]
        var cb: RigidBody3D = bodies[k]
        var sp := _spec(n)
        var hp := _world_rest(i).origin
        var frame := Basis()
        if sp.get("own_frame", false):
            frame = _world_rest(i).basis.orthonormalized()
        j_p0.append(pb.global_transform.basis)
        j_c0.append(cb.global_transform.basis)
        j_frame.append(frame)
        var j := Generic6DOFJoint3D.new()
        add_child(j)
        j.global_transform = Transform3D(frame, hp)
        j.node_a = j.get_path_to(pb)
        j.node_b = j.get_path_to(cb)
        pb.add_collision_exception_with(cb)
        var ax: Dictionary = sp["ax"]
        for a in ["x", "y", "z"]:
            j.set("linear_limit_%s/enabled" % a, true)
            j.set("linear_limit_%s/upper_distance" % a, 0.0)
            j.set("linear_limit_%s/lower_distance" % a, 0.0)
            j.set("angular_limit_%s/enabled" % a, true)
            var lo := 0.0
            var hi := 0.0
            if ax.has(a):
                lo = deg_to_rad(float(ax[a][0]))
                hi = deg_to_rad(float(ax[a][1]))
            j.set("angular_limit_%s/lower_angle" % a, lo)
            j.set("angular_limit_%s/upper_angle" % a, hi)
        # степени свободы
        for a in ["x", "y", "z"]:
            if not ax.has(a):
                continue
            var tm: float = sp["t"]
            d_j.append(k)
            d_a.append(["x", "y", "z"].find(a))
            d_lo.append(deg_to_rad(float(ax[a][0])))
            d_hi.append(deg_to_rad(float(ax[a][1])))
            d_kp.append(0.0)
            d_kd.append(0.0)
            d_t.append(tm)
            d_g.append(sp["g"])
    n_dof = d_j.size()
    jvec.resize(bodies.size())
    jaxes.resize(bodies.size())
    jom.resize(bodies.size())
    _compute_gains()
    # ставим модель на землю: самая нижняя точка у пола
    _reset_body()

func _ext_of(sh: Shape3D) -> Vector3:
    if sh is BoxShape3D:
        return (sh as BoxShape3D).size
    var c := sh as CapsuleShape3D
    return Vector3(2.0 * c.radius, c.height, 2.0 * c.radius)

# жёсткость/демпфирование суставов и минимальная инерция лёгких тел (иначе явный PD раскачивается)
func _compute_gains() -> void:
    var floors := PackedFloat32Array()
    floors.resize(bodies.size())
    for i in n_dof:
        var tm: float = d_t[i]
        var kp := tm / gain_sat
        var kd := kp * kd_ratio
        d_kp[i] = kp
        d_kd[i] = kd
        var need := (kd + kp * dt) * dt / c_max
        var k: int = d_j[i]
        floors[k] = maxf(floors[k], need)
        floors[j_parent[k]] = maxf(floors[j_parent[k]], need)
    for k in bodies.size():
        var rb: RigidBody3D = bodies[k]
        var e: Vector3 = b_ext[k]
        var base := rb.mass * e.length_squared() / 18.0
        var ii := maxf(base, floors[k])
        rb.inertia = Vector3(ii, ii, ii)
        rb.angular_damp = 8.0 if (k != root_i and d_g.size() > 0 and _is_finger(k)) else 1.0

func _is_finger(k: int) -> bool:
    var n := sk.get_bone_name(b_bone[k])
    for f in FINGERS:
        if n.begins_with(f):
            return true
    return false

func L_of(k: int) -> float:
    var i: int = b_bone[k]
    return maxf((_tail_of(i) - _world_rest(i).origin).length(), 0.03)

func _reset_body() -> void:
    for i in bodies.size():
        var rid: RID = bodies[i].get_rid()
        PhysicsServer3D.body_set_state(rid, PhysicsServer3D.BODY_STATE_TRANSFORM, b_init[i])
        PhysicsServer3D.body_set_state(rid, PhysicsServer3D.BODY_STATE_LINEAR_VELOCITY, Vector3.ZERO)
        PhysicsServer3D.body_set_state(rid, PhysicsServer3D.BODY_STATE_ANGULAR_VELOCITY, Vector3.ZERO)

func _refresh_active() -> void:
    act = []
    for i in n_dof:
        act.append(groups[d_g[i]])
    for k in 3:
        act.append(groups["thrust"])

# ---------- нейросеть ----------
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

# обновляет углы/скорости суставов (jvec: угол по мировым осям покоя, jom: отн. угл. скорость)
func _joint_state() -> void:
    for k in bodies.size():
        var pk: int = j_parent[k]
        if pk < 0:
            continue
        var P: Basis = bodies[pk].global_transform.basis
        var C: Basis = bodies[k].global_transform.basis
        var P0: Basis = j_p0[k]
        var C0: Basis = j_c0[k]
        var rp: Basis = P.inverse() * C
        var rp0: Basis = P0.inverse() * C0
        var q: Quaternion = (rp * rp0.inverse()).orthonormalized().get_rotation_quaternion()
        var sg := 1.0 if q.w >= 0.0 else -1.0
        var v := Vector3(q.x, q.y, q.z) * sg
        var s := v.length()
        var rv := v * 2.0
        if s > 1e-6:
            rv = v / s * (2.0 * atan2(s, absf(q.w)))
        jvec[k] = P0 * rv
        var cur: Basis = P * P0.inverse()
        var F: Basis = j_frame[k]
        jaxes[k] = [cur * F.x, cur * F.y, cur * F.z]
        jom[k] = bodies[k].angular_velocity - bodies[pk].angular_velocity

func _sense() -> PackedFloat32Array:
    var rb: RigidBody3D = bodies[root_i]
    var R: Basis = rb.global_transform.basis * root_rest_inv
    var inv := rb.global_transform.basis.inverse()
    var lv := inv * rb.linear_velocity * 0.3
    var av := inv * rb.angular_velocity * 0.2
    var x := PackedFloat32Array([R.y.x, R.y.y, R.y.z, R.z.x, R.z.y, R.z.z,
        lv.x, lv.y, lv.z, av.x, av.y, av.z, rb.global_position.y * 0.5])
    for f in feet_i:
        x.append(1.0 if bodies[f].global_position.y < 0.08 else 0.0)
    var t := float(step) * dt
    x.append(sin(t * 6.0))
    x.append(cos(t * 6.0))
    for i in n_dof:
        var k: int = d_j[i]
        var F: Basis = j_frame[k]
        var axis: Vector3 = F.x if d_a[i] == 0 else (F.y if d_a[i] == 1 else F.z)
        var ang: float = (jvec[k] as Vector3).dot(axis)
        var rng := maxf(maxf(absf(d_lo[i]), absf(d_hi[i])), 0.1)
        x.append(clampf(ang / rng, -1.5, 1.5))
    return x

func _physics_process(_d: float) -> void:
    if step < 0:
        _reset_body()
        step = 0
        sum_up = 0.0
        sum_h = 0.0
        max_h = 0.0
        thr = 0.0
        eff = 0.0
        start = (b_init[root_i] as Transform3D).origin
        return
    _joint_state()
    var out := _policy(_sense(), cur_w)
    var e := 0.0
    for i in n_dof:
        var k: int = d_j[i]
        var pk: int = j_parent[k]
        var ax: Vector3 = jaxes[k][d_a[i]]
        var target := 0.0
        if act[i]:
            target = clampf(out[i] * maxf(absf(d_lo[i]), absf(d_hi[i])), d_lo[i], d_hi[i])
            e += absf(out[i])
        var F: Basis = j_frame[k]
        var axis0: Vector3 = F.x if d_a[i] == 0 else (F.y if d_a[i] == 1 else F.z)
        var ang: float = (jvec[k] as Vector3).dot(axis0)
        var om: float = (jom[k] as Vector3).dot(ax)
        var tq: float = clampf(d_kp[i] * (target - ang) - d_kd[i] * om, -d_t[i], d_t[i])
        var tw := ax * tq
        bodies[k].apply_torque(tw)
        bodies[pk].apply_torque(-tw)
    eff += e / maxf(float(n_dof), 1.0)
    var rb: RigidBody3D = bodies[root_i]
    var f := Vector3(out[n_dof], out[n_dof + 1], out[n_dof + 2]) if act[n_dof] else Vector3.ZERO
    rb.apply_central_force(rb.global_transform.basis * (f * THRUST))
    var R: Basis = rb.global_transform.basis * root_rest_inv
    if assist:
        var up := R.y
        rb.apply_torque(up.cross(Vector3.UP) * 500.0 - rb.angular_velocity * 60.0)
        # Support mode: keeps the learner near its action checkpoint while still allowing joints to move.
        var anchor := start
        var delta := anchor - rb.global_position
        rb.apply_central_force(Vector3(delta.x, 0.0, delta.z) * 180.0 - rb.linear_velocity * 25.0)
    var h := rb.global_position.y
    var live_reward := _positive_reward()
    bonus += live_reward
    sum_up += maxf(R.y.y, 0.0)
    sum_h += h
    max_h = maxf(max_h, h)
    thr += f.length()
    step += 1
    var pos := rb.global_position
    var fell := goal != "fly" and h < 0.5 * h0 and step > 40
    if step >= ep_steps or fell or not pos.is_finite() or pos.length() > 400.0:
        _end_episode()

# ---------- награда и обучение ----------
func _quality_now() -> float:
    var rb: RigidBody3D = bodies[root_i]
    var R: Basis = rb.global_transform.basis * root_rest_inv
    var upright := clampf((R.y.y + 1.0) * 0.5, 0.0, 1.0)
    var height := clampf(rb.global_position.y / maxf(h0, 0.01), 0.0, 1.2) / 1.2
    var angular := clampf(1.0 - rb.angular_velocity.length() * 0.12, 0.0, 1.0)
    var feet := 0.0
    for f in feet_i:
        feet += 1.0 if bodies[f].global_position.y < 0.12 else 0.0
    feet = feet / maxf(float(feet_i.size()), 1.0)
    return clampf(0.45 * upright + 0.30 * height + 0.15 * angular + 0.10 * feet, 0.0, 1.0)

func _positive_reward() -> float:
    var q := _quality_now()
    var delta := q - last_quality
    last_quality = q
    agent_quality = q
    if q > last_good_quality:
        last_good_quality = q
        last_good_w = cur_w.duplicate()
    # Reward only progress / good states. A fall does not create a useful positive target.
    var r := maxf(0.0, delta) * 25.0
    reward_trace.append({"step": step, "quality": snappedf(q, 0.001), "reward": snappedf(r, 0.001)})
    if reward_trace.size() > 240:
        reward_trace.pop_front()
    return r

func _score() -> float:
    var n := float(maxi(ep_steps, 1))
    var upr := sum_up / n
    var hm := sum_h / n
    var th := thr / n
    var ef := eff / n
    var p: Vector3 = bodies[root_i].global_position
    var fwd := p.z - start.z
    var drift := Vector2(p.x - start.x, p.z - start.z).length()
    var q := _quality_now()
    if goal == "walk":
        return 4.0 * fwd + 2.0 * upr + 2.0 * q + clampf(hm / h0, 0.0, 1.1) - 0.25 * ef - 0.35 * th
    if goal == "jump":
        return 4.0 * maxf(0.0, max_h - (h0 + 0.3)) + 1.5 * upr + q - 0.25 * ef - th
    if goal == "fly":
        return clampf(hm, 0.0, 8.0) + 0.5 * upr + q - 0.2 * ef
    return 3.0 * upr + 4.0 * clampf(hm / h0, 0.0, 1.1) + 5.0 * q - 0.2 * ef - 0.4 * th - 0.3 * drift

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
    var ok: bool = bodies[root_i].global_position.is_finite()
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
            sigma = maxf(sigma * 0.9, 0.01)
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
            w[i] = randfn(0.0, 0.03)
        eps = 0
    cur_w = w.duplicate()
    baseline = true
    best = -1e9
    sigma = 0.05
    stall = 0
    bonus = 0.0
    step = -1
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
        var s := JSON.stringify(skills)
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
    box.offset_top = -560
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
    assist_btn = _btn("Опора ✗", _assist)
    r2.add_child(assist_btn)
    r2.add_child(_btn("Камера ↔", _toggle_free_cam))
    screen_btn = _btn("Экран ✓", _screen)
    r2.add_child(screen_btn)
    var r3 := HBoxContainer.new()
    box.add_child(r3)
    r3.add_child(_btn("Пауза", _pause))
    r3.add_child(_btn("Экспорт", _export))
    r3.add_child(_btn("Импорт", _import))
    r3.add_child(_btn("Сброс", _reset_skill))
    r3.add_child(_btn("Вид ⟲", _cam_reset))
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

func _reward(v: float) -> void:
    if v > 0.0:
        var q := _quality_now()
        agent_quality = q
        last_good_quality = maxf(last_good_quality, q)
        last_good_w = cur_w.duplicate()
        w = cur_w.duplicate()
        reward_trace.append({"step": step, "quality": snappedf(q, 0.001), "reward": v})
        bonus += v
        _log("[color=lime]✓ Молодец! Поза сохранена: качество %.2f[/color]" % q)
    else:
        # Negative feedback is logged, but never destroys the last positively rewarded state.
        bonus += v * 0.25
        _log("[color=orange]Отметка: неудачное действие. Последняя хорошая поза сохранена.[/color]")

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

# ---------- камера: вращение пальцем / мышью, щипок или колесо - приближение ----------
func _cam_update() -> void:
    if free_cam:
        cam.position = free_cam_pos
        var yaw := deg_to_rad(free_cam_yaw)
        var pit := deg_to_rad(free_cam_pitch)
        var dir := Vector3(sin(yaw) * cos(pit), sin(pit), cos(yaw) * cos(pit))
        cam.look_at(cam.position + dir)
        return
    var yaw := deg_to_rad(cam_yaw)
    var pit := deg_to_rad(cam_pitch)
    var tgt := cam_sm + Vector3(0, 0.9, 0)
    cam.position = tgt + Vector3(sin(yaw) * cos(pit), sin(pit), cos(yaw) * cos(pit)) * cam_dist
    cam.look_at(tgt)

func _cam_reset() -> void:
    free_cam = false
    cam_yaw = 143.0
    cam_pitch = 12.0
    cam_dist = 4.0
    free_cam_pos = Vector3(3.5, 2.2, 5.5)
    free_cam_yaw = 145.0
    free_cam_pitch = -12.0
    _cam_update()

func _toggle_free_cam() -> void:
    free_cam = not free_cam
    if free_cam:
        free_cam_pos = cam.global_position
        free_cam_yaw = cam_yaw
        free_cam_pitch = cam_pitch
    _log("[color=cyan]Свободная камера: %s[/color]" % ("ВКЛ" if free_cam else "ВЫКЛ"))

func _cam_free_area(p: Vector2) -> bool:
    if panel_layer.visible:
        return false
    return (not menu_box.visible) or p.y < get_viewport().get_visible_rect().size.y - 560.0

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
            if pinch_prev > 0.0:
                cam_dist = clampf(cam_dist * pinch_prev / maxf(d, 1.0), 1.2, 15.0)
            pinch_prev = d
        else:
            cam_yaw -= e.relative.x * 0.35
            cam_pitch = clampf(cam_pitch + e.relative.y * 0.25, 2.0, 85.0)
    elif e is InputEventMouseMotion and not DisplayServer.is_touchscreen_available():
        if e.button_mask & MOUSE_BUTTON_MASK_LEFT and _cam_free_area(e.position):
            if free_cam:
                free_cam_yaw -= e.relative.x * 0.35
                free_cam_pitch = clampf(free_cam_pitch + e.relative.y * 0.25, -85.0, 85.0)
            else:
                cam_yaw -= e.relative.x * 0.35
                cam_pitch = clampf(cam_pitch + e.relative.y * 0.25, 2.0, 85.0)
    elif e is InputEventKey and e.pressed and free_cam:
        var dir := Vector3.ZERO
        if e.keycode == KEY_W: dir.z -= 1.0
        if e.keycode == KEY_S: dir.z += 1.0
        if e.keycode == KEY_A: dir.x -= 1.0
        if e.keycode == KEY_D: dir.x += 1.0
        if e.keycode == KEY_Q: dir.y -= 1.0
        if e.keycode == KEY_E: dir.y += 1.0
        if dir != Vector3.ZERO:
            var yaw := deg_to_rad(free_cam_yaw)
            var forward := Vector3(sin(yaw), 0.0, cos(yaw))
            var right := Vector3(cos(yaw), 0.0, -sin(yaw))
            free_cam_pos += (right * dir.x + forward * dir.z + Vector3.UP * dir.y) * cam_move_speed * 0.08
    elif e is InputEventMouseButton and e.pressed:
        if e.button_index == MOUSE_BUTTON_WHEEL_UP:
            cam_dist = clampf(cam_dist * 0.9, 1.2, 15.0)
        elif e.button_index == MOUSE_BUTTON_WHEEL_DOWN:
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
    _cam_update()
    _mirror_training_agents()
    var inv := sk.global_transform.affine_inverse()
    for k in bodies.size():
        var bw: Transform3D = (bodies[k] as RigidBody3D).global_transform * (b_offset[k] as Transform3D)
        sk.set_bone_global_pose_override(b_bone[k], inv * bw, 1.0, true)
    hud.text = "%s | эп. %d | лучший %.1f | σ %.2f\nшаг %d/%d | бонус %+.0f | высота %.2f\nСеть тела: %d весов ✓\nНейронка-переводчик: %s" % [GOALS[goal], eps, best if best > -1e8 else 0.0, sigma, maxi(step, 0), ep_steps, bonus, tp.y, n_w, brain.mode_text()]
