extends Node3D
signal said(who, text)

const SPEED := 3.0
const BASE := Color(0.35, 0.45, 0.25)
var world
var id := 0
var hp := 100
var inv: Array = []
var goal: Dictionary = {}
var pending: Dictionary = {}
var mesh: MeshInstance3D
var mat := StandardMaterial3D.new()
var label: Label3D

func setup(n: int, pos: Vector3) -> void:
    id = n
    position = pos
    mat.albedo_color = BASE
    var b := BoxMesh.new()
    b.size = Vector3(0.8, 1.6, 0.8)
    b.material = mat
    mesh = MeshInstance3D.new()
    mesh.mesh = b
    mesh.position.y = 0.8
    add_child(mesh)
    label = Label3D.new()
    label.text = "№%d" % n
    label.position.y = 2.3
    label.font_size = 72
    label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
    label.no_depth_test = true
    add_child(label)

func _process(d: float) -> void:
    if hp <= 0 or goal.is_empty():
        return
    var to: Vector3 = goal.ref.global_position - global_position
    to.y = 0
    if to.length() < 1.6:
        _arrive()
    else:
        position += to.normalized() * SPEED * d

func observe() -> String:
    var hands := ", ".join(PackedStringArray(inv)) if inv.size() > 0 else "ничего"
    var s := "Здоровье %d. В руках: %s. " % [hp, hands]
    for it in world.items:
        var dist: float = it.global_position.distance_to(global_position)
        if it.visible and dist < 9.0:
            s += "Рядом лежит %s (ключ %s, %d м). " % [it.get_meta("title"), it.get_meta("kind"), int(dist)]
    for o in world.soldiers:
        if o != self and o.hp > 0 and o.global_position.distance_to(global_position) < 12.0:
            s += "Рядом солдат №%d. " % o.id
    return s

func has_item_near() -> bool:
    for it in world.items:
        if it.visible and it.global_position.distance_to(global_position) < 9.0:
            return true
    return false

func find(key: String):
    if key.is_valid_int():
        for s in world.soldiers:
            if s.id == int(key) and s != self:
                return s
        return null
    var best = null
    var bd := 1e9
    for it in world.items:
        if it.visible and (key == "nearest" or it.get_meta("kind") == key):
            var d: float = it.global_position.distance_to(global_position)
            if d < bd:
                bd = d
                best = it
    return best

func do(a: Dictionary) -> void:
    if hp <= 0:
        return
    var key := str(a.get("target", ""))
    var t = find(key) if key != "" else null
    match str(a.get("action", "idle")):
        "move_to":
            if t:
                goal = {"ref": t, "type": "move"}
        "pick_up":
            if t == null:
                t = find("nearest")
            if t and t.has_meta("kind"):
                goal = {"ref": t, "type": "pick"}
        "shoot":
            _shoot(t)
        "attention":
            goal = {}
            _flash(Color.YELLOW)
        "clean":
            goal = {}
            _bob()
    var s = a.get("say", "")
    if s is String and s != "":
        said.emit(self, s)

func _arrive() -> void:
    var g := goal
    goal = {}
    if g.type != "pick":
        return
    var it: Node3D = g.ref
    if it.visible:
        it.visible = false
        inv.append(it.get_meta("kind"))
        said.emit(self, "Взял: %s." % it.get_meta("title"))
    if pending.size() > 0:
        var p := pending
        pending = {}
        do(p)

func _shoot(t) -> void:
    if not (t is Node3D) or not t.has_method("hurt") or t.hp <= 0:
        said.emit(self, "По кому стрелять, командир?")
        return
    if "rpg" not in inv:
        var r = find("rpg")
        if r:
            pending = {"action": "shoot", "target": str(t.id)}
            goal = {"ref": r, "type": "pick"}
            said.emit(self, "РПГ нет, бегу за ним!")
        else:
            said.emit(self, "Нет РПГ, командир!")
        return
    inv.erase("rpg")
    goal = {}
    var m := BoxMesh.new()
    m.size = Vector3(0.2, 0.2, 0.8)
    var rk := MeshInstance3D.new()
    rk.mesh = m
    get_parent().add_child(rk)
    rk.global_position = global_position + Vector3(0, 1.2, 0)
    var tw := create_tween()
    tw.tween_property(rk, "global_position", t.global_position + Vector3(0, 0.8, 0), 0.5)
    tw.tween_callback(func():
        rk.queue_free()
        t.hurt(60))

func hurt(n: int) -> void:
    hp -= n
    if hp <= 0:
        goal = {}
        mat.albedo_color = Color(0.25, 0.25, 0.25)
        label.text = "№%d ✖" % id
        said.emit(self, "Я ранен… Командир…")
    else:
        _flash(Color.RED)
        said.emit(self, "Задело! Держусь, здоровье %d." % hp)

func _flash(c: Color) -> void:
    mat.albedo_color = c
    create_tween().tween_property(mat, "albedo_color", BASE, 0.8)

func _bob() -> void:
    var tw := create_tween().set_loops(4)
    tw.tween_property(mesh, "position:y", 1.1, 0.15)
    tw.tween_property(mesh, "position:y", 0.8, 0.15)
