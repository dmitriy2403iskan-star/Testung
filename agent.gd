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

func setup(s, i: int, pos: Vector3) -> void:
    sim = s
    idx = i
    home = pos
    dt = 1.0 / float(Engine.physics_ticks_per_second)
    _build_body()
    n_in = 17 + n_dof
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

func _reset_body() -> void:
    for i in bodies.size():
        var rid: RID = bodies[i].get_rid()
        PhysicsServer3D.body_set_state(rid, PhysicsServer3D.BODY_STATE_TRANSFORM, b_init[i])
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
        start = (b_init[root_i] as Transform3D).origin
        return false
    var act: Array = sim.act
    var goal: String = sim.goal
    _joint_state()
    var out := _policy(_sense(), cur_w)
    var e := 0.0
    var g_on: bool = sim.gait_on
    var gmix: float = sim.gait_mix
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
    var R: Basis = rb.global_transform.basis * root_rest_inv
    var h := rb.global_position.y
    var lvl: int = sim.support
    if lvl > 0:
        # подвес: выравнивает корпус, подхватывает при проседании, держит курс
        var kt: float = SUP_KT[lvl]
        rb.apply_torque(R.y.cross(Vector3.UP) * kt - rb.angular_velocity * (kt * 0.12))
        var fmax: float = SUP_F[lvl] * total_mass * 9.8
        var fy := clampf(fmax / 0.12 * (h0 - h) - rb.linear_velocity.y * fmax * 0.12, 0.0, fmax)
        rb.apply_central_force(Vector3(0, fy, 0))
        if lvl >= 2:
            var yaw := atan2(R.z.x, R.z.z)
            rb.apply_torque(Vector3(0, -yaw * kt * 0.5 - rb.angular_velocity.y * kt * 0.06, 0))
    if sim.auto_on and step % 60 == 0:
        _coach(R, h, rb)
    sum_up += maxf(R.y.y, 0.0)
    sum_h += h
    max_h = maxf(max_h, h)
    thr += f.length()
    step += 1
    var pos := rb.global_position
    fell = goal != "fly" and lvl < 3 and h < 0.5 * h0 and step > 40
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
    done = true

func finite() -> bool:
    return (bodies[root_i] as RigidBody3D).global_position.is_finite()

func score() -> float:
    var goal: String = sim.goal
    var imit := 0.0
    if sim.gait_on and sim.gait_n > 0:
        imit = 3.0 * sum_im / float(sim.ep_steps)   # награда за повторение эталонной походки/позы
    return _base_score(goal) + imit

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
        return 3.0 * fwd + 1.5 * upr + clampf(hm / h0, 0.0, 1.1) - 0.3 * ef - 0.5 * th
    if goal == "jump":
        return 4.0 * maxf(0.0, max_h - (h0 + 0.3)) + upr + clampf(hm / h0, 0.0, 1.1) - 0.3 * ef - th
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
