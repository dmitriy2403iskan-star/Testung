extends Node3D
# Один человек (модель human.glb, 53 кости, с пальцами): каждая кость - физическое тело,
# суставы - Generic6DOF с лимитами. Нейросеть (общие веса от менеджера sim.gd) выдаёт целевые углы,
# PD-регулятор крутит суставы. Над головой метка: что с ним сейчас и как прошёл прошлый эпизод.

const LIFT := 0.02
const THRUST := 700.0
const FINGERS := ["index", "middle", "ring", "pinky", "thumb"]
# подвес: жёсткость выравнивания корпуса и максимум подъёмной силы (в весах тела)
const SUP_KT := [0.0, 150.0, 400.0, 900.0]
const SUP_F := [0.0, 0.3, 0.8, 1.5]
const N_HID := 16

var sim
var mix_override := -1.0   # >=0: своя доля нейросети поверх походки (для островов CMA)
var idx := 0
var home := Vector3.ZERO
var sk: Skeleton3D
var human: Node3D
var gain_sat := 0.15
var kd_ratio := 0.1
var c_max := 0.6
var b_ext: Array = []
var bodies: Array = []
var b_bone: Array = []
var b_offset: Array = []
var b_init: Array = []
var j_parent: Array = []
var j_p0: Array = []
var j_c0: Array = []
var j_frame: Array = []
var root_i := 0
var feet_i: Array = []
var d_j: Array = []
var d_a: Array = []
var d_lo: Array = []
var d_hi: Array = []
var d_kp: Array = []
var d_kd: Array = []
var d_t: Array = []
var d_g: Array = []
var d_name: Array = []
var root_rest_inv := Basis()
var h0 := 0.9
var n_dof := 0
var n_in := 0
var n_out := 0
var jvec: Array = []
var jaxes: Array = []
var jom: Array = []
var total_mass := 0.0
var dt := 1.0 / 120.0

# обучение (у каждого человека свой кандидат весов)
var cur_w := PackedFloat32Array()
var sigma_mul := 1.0
var step := -1
var bonus := 0.0
var sum_up := 0.0
var sum_h := 0.0
var max_h := 0.0
var thr := 0.0
var sum_im := 0.0
var eff := 0.0
var start := Vector3.ZERO
var verdict := "старт"
var verdict_col := Color(0.8, 0.8, 0.8)
var flash_t := 0.0
var q_last := 0
var q_good := 0
var q_bad := 0
var done := false      # закончил эпизод, ждёт остальных
var fell := false
var fin_up := 0.0
var fin_fwd := 0.0
var res := 0.0         # авто-оценка эпизода
var events: Array = [] # ручные похвалы, ждут подтверждения [шаг, значение]
const PRAISE_WIN := 0.8 # сек: похвала засчитывается, только если он ещё в порядке через это время
var label: Label3D
# --- коробка (задача "box"): у каждого человека своя; "хват" - мягкая притяжка к кисти, пока сеть "сжимает" (выход n_dof > 0)
const BOX_SIZE := 0.3
const EXTRA_IN := 6   # командные входы в конце вектора: [цель x, цель z, команда высоты, резерв, настроение A, настроение B]
var box: RigidBody3D
var box_on := false
var box_init := Transform3D.IDENTITY
var hand_i: Array = []
var held_n := 0
var near_sum := 0.0
var held_fin := false
var box_y_fin := 0.0
# --- проверка на устойчивость: разовый толчок корпуса на шаге push_step
var push_step := -1
var push_imp := Vector3.ZERO
# --- торс (верхний позвонок): следим за наклоном, изгибом относительно таза и раскачкой
var torso_i := -1
var torso_rest_inv := Basis()
var sum_ttilt := 0.0
var sum_bend := 0.0
var sum_tw := 0.0
var tup_last := 1.0
# --- прыжок: сколько времени обе ступни в воздухе и на какую высоту поднимались (меньшая из двух)
var air_steps := 0
# --- команды и сцена новых задач (цель на земле, лежачий старт, планка, приседание)
var tgt_on := false
var tgt_rel := Vector2.ZERO      # цель относительно точки старта (x вбок, y вперёд)
var tgt_world := Vector3.ZERO
var tgt_marker: MeshInstance3D
var bar: StaticBody3D
var lie_mode := 0                # 0 стоит, 1 лежит на спине, 2 на животе
var mood := Vector2.ZERO         # резерв под настроение (входы A и B)
var tdist_last := 0.0
var d0 := 1.0
var tsum := 0.0
var h_last := 0.0
var up_last := 0.0
var cerr_sum := 0.0
var min_crouch := 9.0
var crossed := false
var peak_clear := 0.0

func setup(s, i: int, pos: Vector3) -> void:
    sim = s
    idx = i
    home = pos
    dt = 1.0 / float(Engine.physics_ticks_per_second)
    _build_body()
    for k in bodies.size():
        var bn := sk.get_bone_name(b_bone[k])
        if bn.begins_with("hand"):
            hand_i.append(k)
        if bn.begins_with("spine"):
            torso_i = k   # последний позвонок = верхняя часть торса
    if torso_i >= 0:
        torso_rest_inv = (b_init[torso_i] as Transform3D).basis.inverse()
    # кожа не должна исчезать из кадра: габариты меша считаются по позе покоя, а люди уходят от неё далеко
    for mi in human.find_children("*", "MeshInstance3D", true, false):
        (mi as MeshInstance3D).extra_cull_margin = 5000.0
    n_in = 17 + n_dof + EXTRA_IN
    n_out = n_dof + 3
    label = Label3D.new()
    label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
    label.no_depth_test = true
    label.pixel_size = 0.0035
    label.font_size = 56
    label.outline_size = 14
    add_child(label)

# ---------- описание костей ----------
# ax: оси сустава (x,y,z в мировых осях покоя) и пределы в градусах. Остальные оси заперты.
func _spec(n: String) -> Dictionary:
    var side := -1.0 if n.ends_with("_r") else 1.0
    var b := n.trim_suffix("_l").trim_suffix("_r")
    match b:
        "spine_01": return {"g": "spine", "m": 4.0, "t": 180.0, "ax": {"x": [-20, 30], "y": [-20, 20], "z": [-15, 15]}}
        "spine_02": return {"g": "spine", "m": 6.0, "t": 150.0, "ax": {"x": [-15, 20], "z": [-10, 10]}}
        "spine_03": return {"g": "spine", "m": 12.0, "t": 120.0, "ax": {"x": [-15, 20], "z": [-10, 10]}}
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
func _build_body() -> void:
    human = (load("res://human.glb") as PackedScene).instantiate()
    add_child(human)
    human.position = home + Vector3(0, LIFT, 0)
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
            d_name.append(n + "." + a)
    n_dof = d_j.size()
    for rbm in bodies:
        total_mass += (rbm as RigidBody3D).mass
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

func _cmd_h() -> float:   # приседание: 0-3 с стоим, 3-6.5 с присели до 60% роста, дальше встаём
    var t := float(step) * dt
    return 0.6 if (t > 3.0 and t < 6.5) else 1.0

func set_scene(goal: String) -> void:
    tgt_on = goal == "goto" or goal == "carry"
    if tgt_on and tgt_marker == null:
        tgt_marker = MeshInstance3D.new()
        var cm := CylinderMesh.new()
        cm.top_radius = 0.35
        cm.bottom_radius = 0.35
        cm.height = 0.03
        var mt := StandardMaterial3D.new()
        mt.albedo_color = Color(0.9, 0.15, 0.15)
        cm.material = mt
        tgt_marker.mesh = cm
        add_child(tgt_marker)
        tgt_marker.top_level = true
    if tgt_marker != null:
        tgt_marker.visible = tgt_on
    if goal == "leap" and bar == null:
        bar = StaticBody3D.new()
        var cs := CollisionShape3D.new()
        var bs := BoxShape3D.new()
        bs.size = Vector3(1.2, 0.14, 0.1)
        cs.shape = bs
        bar.add_child(cs)
        var mi := MeshInstance3D.new()
        var bm := BoxMesh.new()
        bm.size = bs.size
        var mt2 := StandardMaterial3D.new()
        mt2.albedo_color = Color(0.2, 0.4, 0.9)
        bm.material = mt2
        mi.mesh = bm
        bar.add_child(mi)
        bar.collision_layer = 1
        bar.collision_mask = 0
        add_child(bar)
        bar.global_position = home + Vector3(0, 0.07, 1.2)
    if bar != null:
        bar.visible = goal == "leap"
        bar.collision_layer = 1 if goal == "leap" else 0
    _place_tgt()

func _place_tgt() -> void:
    var st: Vector3 = (b_init[root_i] as Transform3D).origin
    tgt_world = Vector3(st.x + tgt_rel.x, 0.02, st.z + tgt_rel.y)
    if tgt_marker != null:
        tgt_marker.global_position = tgt_world

func set_box(on: bool) -> void:
    if on and box == null:
        box = RigidBody3D.new()
        box.mass = 2.5
        box.can_sleep = false
        var cs := CollisionShape3D.new()
        var bs := BoxShape3D.new()
        bs.size = Vector3(BOX_SIZE, BOX_SIZE, BOX_SIZE)
        cs.shape = bs
        box.add_child(cs)
        var mi := MeshInstance3D.new()
        var bm := BoxMesh.new()
        bm.size = Vector3(BOX_SIZE, BOX_SIZE, BOX_SIZE)
        var mat := StandardMaterial3D.new()
        mat.albedo_color = Color(0.95, 0.55, 0.1)
        bm.material = mat
        mi.mesh = bm
        box.add_child(mi)
        add_child(box)
        box_init = Transform3D(Basis(), home + Vector3(0, BOX_SIZE * 0.5, 0.9))
        box.global_transform = box_init
    box_on = on
    if box != null:
        box.visible = on
        box.collision_layer = 1 if on else 0
        box.collision_mask = 3 if on else 0
        box.freeze = not on
        _reset_box()

func _reset_box() -> void:
    if box == null:
        return
    var rid: RID = box.get_rid()
    PhysicsServer3D.body_set_state(rid, PhysicsServer3D.BODY_STATE_TRANSFORM, box_init)
    PhysicsServer3D.body_set_state(rid, PhysicsServer3D.BODY_STATE_LINEAR_VELOCITY, Vector3.ZERO)
    PhysicsServer3D.body_set_state(rid, PhysicsServer3D.BODY_STATE_ANGULAR_VELOCITY, Vector3.ZERO)

func _reset_body() -> void:
    _reset_box()
    var lift := Transform3D.IDENTITY
    if lie_mode != 0:   # лежачий старт: поворачиваем всё тело вокруг таза на спину/живот и кладём на землю
        var pel: Vector3 = (b_init[root_i] as Transform3D).origin
        var ang := -PI * 0.5 if lie_mode == 1 else PI * 0.5
        lift = Transform3D(Basis(Vector3.RIGHT, ang), pel + Vector3(0, 0.16 - pel.y, 0)) * Transform3D(Basis(), -pel)
    for i in bodies.size():
        (bodies[i] as RigidBody3D).freeze = false
        var rid: RID = bodies[i].get_rid()
        PhysicsServer3D.body_set_state(rid, PhysicsServer3D.BODY_STATE_TRANSFORM, lift * (b_init[i] as Transform3D))
        PhysicsServer3D.body_set_state(rid, PhysicsServer3D.BODY_STATE_LINEAR_VELOCITY, Vector3.ZERO)
        PhysicsServer3D.body_set_state(rid, PhysicsServer3D.BODY_STATE_ANGULAR_VELOCITY, Vector3.ZERO)


# ---------- нейросеть ----------
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
    if box_on and box != null:   # в задаче "box" два канала часов заняты положением коробки (в осях тела)
        var rel: Vector3 = R.inverse() * (box.global_position - rb.global_position)
        x.append(clampf(rel.x * 0.6, -1.5, 1.5))
        x.append(clampf(rel.z * 0.6, -1.5, 1.5))
    elif torso_i >= 0:   # вместо часов (походка задаётся эталоном, часы сети не нужны): наклон торса вперёд/вбок
        var Rt: Basis = (bodies[torso_i] as RigidBody3D).global_transform.basis * torso_rest_inv
        x.append(clampf(Rt.y.z * 3.0, -1.5, 1.5))
        x.append(clampf(Rt.y.x * 3.0, -1.5, 1.5))
    else:
        x.append(sin(t * 6.0))
        x.append(cos(t * 6.0))
    for i in n_dof:
        var k: int = d_j[i]
        var F: Basis = j_frame[k]
        var axis: Vector3 = F.x if d_a[i] == 0 else (F.y if d_a[i] == 1 else F.z)
        var ang: float = (jvec[k] as Vector3).dot(axis)
        var rng := maxf(maxf(absf(d_lo[i]), absf(d_hi[i])), 0.1)
        x.append(clampf(ang / rng, -1.5, 1.5))
    # командные входы (нули, если команды нет)
    if tgt_on:
        var tr: Vector3 = R.inverse() * (tgt_world - rb.global_position)
        x.append(clampf(tr.x * 0.25, -1.5, 1.5))
        x.append(clampf(tr.z * 0.25, -1.5, 1.5))
    else:
        x.append(0.0)
        x.append(0.0)
    x.append(_cmd_h() if sim.goal == "crouch" else 0.0)
    # канал «ругани»: 1, когда тело упало (наклон > ~53° или таз ниже 0.6 роста). Сеть может научиться на него реагировать
    x.append(1.0 if (R.y.y < 0.6 or rb.global_position.y < 0.6 * h0) else 0.0)
    x.append(mood.x)
    x.append(mood.y)
    return x

# один физический шаг; true - эпизод закончился
func tick() -> bool:
    if step < 0:
        _reset_body()
        step = 0
        sum_up = 0.0
        sum_h = 0.0
        max_h = 0.0
        thr = 0.0
        sum_im = 0.0
        eff = 0.0
        held_n = 0
        near_sum = 0.0
        sum_ttilt = 0.0
        sum_bend = 0.0
        sum_tw = 0.0
        tup_last = 1.0
        air_steps = 0
        peak_clear = 0.0
        tsum = 0.0
        h_last = 0.0
        up_last = 0.0
        cerr_sum = 0.0
        min_crouch = 9.0
        crossed = false
        held_fin = false
        box_y_fin = 0.0
        start = (b_init[root_i] as Transform3D).origin
        _place_tgt()
        d0 = maxf(Vector2(tgt_world.x - start.x, tgt_world.z - start.z).length(), 0.1)
        tdist_last = d0
        return false
    var act: Array = sim.act
    var goal: String = sim.goal
    _joint_state()
    var out := _policy(_sense(), cur_w)
    var e := 0.0
    var g_on: bool = sim.gait_on
    var gmix: float = sim.gait_mix if mix_override < 0.0 else mix_override
    var gt := float(step) * dt
    var imit_err := 0.0
    for i in n_dof:
        var k: int = d_j[i]
        var pk: int = j_parent[k]
        var ax: Vector3 = jaxes[k][d_a[i]]
        var target := 0.0
        var rng := maxf(absf(d_lo[i]), absf(d_hi[i]))
        if act[i]:
            target = out[i] * rng
            e += absf(out[i])
        if g_on:
            target = target * gmix + sim.gait_off[i] + sim.gait_amp[i] * sin(TAU * (gt / sim.gait_period + sim.gait_ph[i]))
        if g_on and sim.gait_used[i]:
            var gtar: float = clampf(sim.gait_off[i] + sim.gait_amp[i] * sin(TAU * (gt / sim.gait_period + sim.gait_ph[i])), d_lo[i], d_hi[i])
            var F2: Basis = j_frame[k]
            var ax0: Vector3 = F2.x if d_a[i] == 0 else (F2.y if d_a[i] == 1 else F2.z)
            var er: float = gtar - (jvec[k] as Vector3).dot(ax0)
            imit_err += er * er
        target = clampf(target, d_lo[i], d_hi[i])
        var F: Basis = j_frame[k]
        var axis0: Vector3 = F.x if d_a[i] == 0 else (F.y if d_a[i] == 1 else F.z)
        var ang: float = (jvec[k] as Vector3).dot(axis0)
        var om: float = (jom[k] as Vector3).dot(ax)
        var tq: float = clampf(d_kp[i] * (target - ang) - d_kd[i] * om, -d_t[i], d_t[i])
        var tw := ax * tq
        bodies[k].apply_torque(tw)
        bodies[pk].apply_torque(-tw)
    eff += e / maxf(float(n_dof), 1.0)
    if g_on and sim.gait_n > 0:
        sum_im += exp(-imit_err / float(sim.gait_n) / 0.04)
    var rb: RigidBody3D = bodies[root_i]
    var f := Vector3(out[n_dof], out[n_dof + 1], out[n_dof + 2]) if act[n_dof] else Vector3.ZERO
    rb.apply_central_force(rb.global_transform.basis * (f * THRUST))
    if box_on and box != null:
        var bp: Vector3 = box.global_position
        var gripping: bool = out[n_dof] > 0.0
        var dmin := 9.0
        var any := false
        for hk in hand_i:
            var hb: RigidBody3D = bodies[hk]
            var dd: float = hb.global_position.distance_to(bp)
            dmin = minf(dmin, dd)
            if gripping and dd < 0.28:
                var fv: Vector3 = ((hb.global_position - bp) * 400.0 - (box.linear_velocity - hb.linear_velocity) * 25.0).limit_length(600.0)
                box.apply_central_force(fv)
                hb.apply_central_force(-fv * 0.3)
                any = true
        near_sum += exp(-dmin / 0.35)
        if any:
            held_n += 1
        held_fin = any
        box_y_fin = box.global_position.y
    if push_step >= 0 and step == push_step:
        rb.apply_central_impulse(push_imp)
    var R: Basis = rb.global_transform.basis * root_rest_inv
    var h := rb.global_position.y
    var lvl: int = sim.support
    if lvl > 0:
        # подвес: выравнивает корпус, подхватывает при проседании, держит курс
        var kt: float = SUP_KT[lvl]
        rb.apply_torque(R.y.cross(Vector3.UP) * kt - rb.angular_velocity * (kt * 0.12))
        var fmax: float = SUP_F[lvl] * total_mass * 9.8
        var fy := clampf(fmax / 0.12 * (h0 - h) - rb.linear_velocity.y * fmax * 0.12, 0.0, fmax)
        if goal == "jump" and not (h < 0.75 * h0 and rb.linear_velocity.y < 0.2):
            fy = 0.0   # прыжок: подвес только подхватывает при провале ниже 75% роста и никогда не тянет вниз и не держит при взлёте
        rb.apply_central_force(Vector3(0, fy, 0))
        if lvl >= 2 and goal != "goto" and goal != "carry":
            var yaw := atan2(R.z.x, R.z.z)
            rb.apply_torque(Vector3(0, -yaw * kt * 0.5 - rb.angular_velocity.y * kt * 0.06, 0))
    if sim.auto_on and step % 60 == 0:
        _coach(R, h, rb)
    if torso_i >= 0:
        var Rt2: Basis = (bodies[torso_i] as RigidBody3D).global_transform.basis * torso_rest_inv
        tup_last = Rt2.y.y
        sum_ttilt += 1.0 - Rt2.y.y
        sum_bend += (Rt2.y - R.y).length()
        sum_tw += (bodies[torso_i] as RigidBody3D).angular_velocity.length()
    var clr := 9.0
    for ff in feet_i:
        clr = minf(clr, (bodies[ff] as RigidBody3D).global_position.y)
    if step > 20:
        peak_clear = maxf(peak_clear, clr)
        if clr > 0.10:
            air_steps += 1
    h_last = h
    up_last = R.y.y
    if tgt_on:
        tdist_last = Vector2(rb.global_position.x - tgt_world.x, rb.global_position.z - tgt_world.z).length()
        tsum += exp(-tdist_last)
    if goal == "crouch":
        var ch := _cmd_h()
        cerr_sum += absf(h / h0 - ch)
        var tt := float(step) * dt
        if tt > 4.5 and tt < 6.5:
            min_crouch = minf(min_crouch, h / h0)
    if goal == "leap" and rb.global_position.z > start.z + 1.5 and peak_clear > 0.1:
        crossed = true
    sum_up += maxf(R.y.y, 0.0)
    sum_h += h
    max_h = maxf(max_h, h)
    thr += f.length()
    step += 1
    var pos := rb.global_position
    fell = goal != "fly" and goal != "getup" and lvl < 3 and h < 0.5 * h0 and step > 40
    if not events.is_empty():
        _resolve_events(false)
    return step >= sim.ep_steps or fell or not pos.is_finite() or pos.length() > 400.0

# автотренер: каждые 0.5 с оценивает действие по цели и даёт плюс/минус (оценка привязана к моменту)
func _coach(R: Basis, h: float, rb: RigidBody3D) -> void:
    var g: String = sim.goal
    var up := R.y.y
    var q := 0
    var vz := rb.linear_velocity.z
    var vh := Vector2(rb.linear_velocity.x, rb.linear_velocity.z).length()
    if up < 0.6 or h < 0.6 * h0:
        q = -1
    elif g == "walk":
        q = 1 if (up > 0.85 and vz > 0.4) else (-1 if vz < -0.2 else 0)
    elif g == "jump":
        q = 1 if h > h0 + 0.1 else 0
    elif g == "fly":
        q = 1 if h > h0 + 0.5 else (-1 if h < h0 else 0)
    else:
        q = 1 if (up > 0.9 and h > 0.85 * h0 and vh < 0.3) else 0
    q_last = q
    if q > 0:
        q_good += 1
    elif q < 0:
        q_bad += 1
    bonus += 0.3 * q

func _ok_now() -> bool:
    var rb: RigidBody3D = bodies[root_i]
    if not rb.global_position.is_finite():
        return false
    var R: Basis = rb.global_transform.basis * root_rest_inv
    return rb.global_position.y >= 0.5 * h0 and R.y.y >= 0.3

# похвала относится к действию в момент нажатия: засчитывается, если через PRAISE_WIN он всё ещё в порядке
func _resolve_events(final: bool) -> void:
    var keep: Array = []
    var win := int(PRAISE_WIN / dt)
    for ev in events:
        if final or step - int(ev[0]) >= win:
            if _ok_now():
                bonus += float(ev[1])
            else:
                flash("похвала не засчитана: упал", Color(1, 0.6, 0.3))
        else:
            keep.append(ev)
    events = keep

func give(v: float) -> void:
    if v < 0.0:
        bonus += v
        flash("Плохо!", Color(1, 0.35, 0.3))
        return
    if not _ok_now():
        flash("не засчитано: упал", Color(1, 0.6, 0.3))
    elif done:
        bonus += v
        flash("Молодец!", Color(0.3, 1, 0.4))
    else:
        events.append([step, v])
        flash("Молодец? (проверю)", Color(0.6, 1, 0.6))

func finish() -> void:
    var rbf: RigidBody3D = bodies[root_i]
    fin_up = (rbf.global_transform.basis * root_rest_inv).y.y
    fin_fwd = rbf.global_position.z - start.z
    res = score() if finite() else -100.0
    if not events.is_empty():
        _resolve_events(true)
    for rbz in bodies:   # закончивший эпизод человек замораживается: физика не тратит на него время
        (rbz as RigidBody3D).freeze = true
    done = true

func finite() -> bool:
    return (bodies[root_i] as RigidBody3D).global_position.is_finite()

func score() -> float:
    var goal: String = sim.goal
    var imit := 0.0
    if sim.gait_on and sim.gait_n > 0:
        imit = 3.0 * sum_im / float(sim.ep_steps)   # награда за повторение эталонной походки/позы
    # чёткий штраф за падение: чем раньше упал, тем больнее (раньше это терялось внутри средних значений)
    var pen := 0.0
    if fell and goal != "fly":
        pen = 3.0 * (1.0 - float(step) / float(sim.ep_steps))
    var n := float(sim.ep_steps)
    var kt := 0.0
    var kb := 0.0
    var kw := 0.0
    match goal:
        "stand":
            kt = 6.0; kb = 3.0; kw = 0.3
        "walk":
            kt = 4.0; kb = 2.0; kw = 0.2
        "run", "goto", "carry":
            kt = 3.0; kb = 1.5; kw = 0.15
        "jump", "box", "leap", "crouch", "getup":
            kt = 2.0; kb = 1.0; kw = 0.1
    var tpen := (kt * sum_ttilt + kb * sum_bend + kw * sum_tw) / n
    return _base_score(goal) + imit - pen - tpen

func _base_score(goal: String) -> float:
    var n := float(sim.ep_steps)
    var upr := sum_up / n
    var hm := sum_h / n
    var th := thr / n
    var ef := eff / n
    var p: Vector3 = bodies[root_i].global_position
    var fwd := p.z - start.z
    var drift := Vector2(p.x - start.x, p.z - start.z).length()
    if goal == "walk":
        return 3.0 * fwd + 1.5 * upr + clampf(hm / h0, 0.0, 1.1) - 0.3 * ef - 0.5 * th - 1.0 * absf(p.x - start.x)
    if goal == "box":
        var lift := clampf(box_y_fin - BOX_SIZE * 0.5, 0.0, 0.5) if held_fin else 0.0
        return 1.5 * upr + clampf(hm / h0, 0.0, 1.1) + 3.0 * near_sum / n + 3.0 * float(held_n) / n + 8.0 * lift - 0.3 * ef
    if goal == "jump":   # награда за высоту ОБЕИХ ступней над землёй и время в воздухе (раньше платили только за подъём таза на 30 см, и между 0 и 30 см градиента не было)
        var air := clampf(float(air_steps) * dt, 0.0, 1.5)
        return 10.0 * clampf(peak_clear - 0.05, 0.0, 0.4) + 5.0 * air + upr + 0.5 * clampf(hm / h0, 0.0, 1.1) - 0.2 * ef - drift
    if goal == "goto":
        var dn := clampf(tdist_last / d0, 0.0, 1.5)
        return 5.0 * (1.0 - dn) + (2.0 if tdist_last < 0.6 else 0.0) + 2.0 * tsum / n + 1.5 * upr + clampf(hm / h0, 0.0, 1.1) - 0.3 * ef
    if goal == "getup":
        return 6.0 * clampf(h_last / h0, 0.0, 1.1) + 4.0 * clampf(up_last, 0.0, 1.0) + 2.0 * clampf(hm / h0, 0.0, 1.1) + upr - 0.3 * ef
    if goal == "run":
        var airr := clampf(float(air_steps) * dt, 0.0, 2.0)
        return 4.0 * fwd + 1.5 * upr + clampf(hm / h0, 0.0, 1.1) + airr - 0.3 * ef - 1.0 * absf(p.x - start.x)
    if goal == "leap":
        return 3.0 * clampf(fwd, 0.0, 3.5) + 6.0 * clampf(peak_clear - 0.05, 0.0, 0.3) + (3.0 if crossed else 0.0) + upr + 0.5 * clampf(hm / h0, 0.0, 1.1) - 0.3 * ef - 1.0 * absf(p.x - start.x)
    if goal == "crouch":
        return 6.0 * (1.0 - clampf(cerr_sum / n / 0.4, 0.0, 1.0)) + 2.0 * upr + (3.0 if min_crouch < 0.72 else 0.0) - 0.3 * ef
    if goal == "carry":
        var liftc := clampf(box_y_fin - BOX_SIZE * 0.5, 0.0, 0.3) if held_fin else 0.0
        var dnc := clampf(tdist_last / d0, 0.0, 1.5)
        return 1.5 * upr + 3.0 * float(held_n) / n + 8.0 * liftc + 4.0 * (1.0 - dnc) + (2.0 if (tdist_last < 0.8 and held_fin) else 0.0) - 0.3 * ef
    if goal == "fly":
        return clampf(hm, 0.0, 8.0) + 0.5 * upr - 0.2 * ef
    return 2.0 * upr + 3.0 * clampf(hm / h0, 0.0, 1.1) - 0.3 * ef - th - 0.5 * drift

func root_pos() -> Vector3:
    return (bodies[root_i] as RigidBody3D).global_position

# что с ним прямо сейчас: [текст, цвет]
func live_state() -> Array:
    var rb: RigidBody3D = bodies[root_i]
    if not rb.global_position.is_finite():
        return ["сбой", Color(1, 0.3, 0.3)]
    var R: Basis = rb.global_transform.basis * root_rest_inv
    var h := rb.global_position.y
    if h < 0.5 * h0 or R.y.y < 0.3:
        return ["упал", Color(1, 0.35, 0.3)]
    if R.y.y > 0.85 and h > 0.8 * h0:
        return ["стоит", Color(0.4, 1, 0.45)]
    return ["шатается", Color(1, 0.9, 0.35)]

func flash(txt: String, col: Color) -> void:
    verdict = txt
    verdict_col = col
    flash_t = 1.5

func _process(d: float) -> void:
    var inv := sk.global_transform.affine_inverse()
    for k in bodies.size():
        var bw: Transform3D = (bodies[k] as RigidBody3D).global_transform * (b_offset[k] as Transform3D)
        sk.set_bone_global_pose_override(b_bone[k], inv * bw, 1.0, true)
    var p := root_pos()
    if p.is_finite():
        label.position = Vector3(p.x, p.y + 1.25, p.z)
    var st := live_state()
    label.text = "№%d %s\n%s" % [idx + 1, st[0], verdict]
    flash_t = maxf(flash_t - d, 0.0)
    label.modulate = verdict_col if flash_t > 0.0 else st[1]
    label.visible = sim.labels_on
