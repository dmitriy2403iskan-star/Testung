extends Node3D
const AgentS := preload("res://agent.gd")
const GOALS := {"stand":"СТОЯТЬ","walk":"ИДТИ","jump":"ПРЫГАТЬ","fly":"ЛЕТАТЬ"}
const AGENTS := 8
const N_HID := 16
const MUT_P := 0.05
const SUCCESS_STREAK := 10
const SAVE := "user://auto_skills.json"
const EXPORT_DIR := "user://auto_skills"
var agents:Array = []
var goal := "stand"
var support := 0
var act:Array = []
var groups := {"legs":true,"toes":true,"spine":true,"neck":true,"arms":true,"hands":true,"fingers":false,"thrust":true}
var n_dof := 0
var n_in := 0
var n_out := 0
var n_w := 0
var w := PackedFloat32Array()
var best_score := -1.0e9
var sigma := 0.05
var episode := 0
var success_streak := 0
var total_success := 0
var running := true
var last_result := "Запуск"
var skills := {}
var hud:Label
var status:Label

func _ready() -> void:
    randomize()
    Engine.max_physics_steps_per_frame = 64
    _build_world()
    _build_ui()
    _spawn(AGENTS)
    _load_skills()
    _new_goal("stand")

func _build_world() -> void:
    var floor := StaticBody3D.new()
    var shape := CollisionShape3D.new()
    var box := BoxShape3D.new()
    box.size = Vector3(30,0.2,30)
    shape.shape = box
    floor.add_child(shape)
    floor.position.y = -0.1
    add_child(floor)
    var cam := Camera3D.new()
    cam.position = Vector3(0,2.5,7.0)
    add_child(cam)
    cam.look_at(Vector3(0,0.9,0))
    var light := DirectionalLight3D.new()
    light.rotation_degrees = Vector3(-55,-25,0)
    add_child(light)

func _build_ui() -> void:
    var layer := CanvasLayer.new()
    add_child(layer)
    var root := VBoxContainer.new()
    root.position = Vector2(20,20)
    root.size = Vector2(680,520)
    layer.add_child(root)
    status = Label.new()
    status.add_theme_font_size_override("font_size",26)
    root.add_child(status)
    hud = Label.new()
    hud.add_theme_font_size_override("font_size",22)
    root.add_child(hud)
    var row := HBoxContainer.new()
    root.add_child(row)
    for g in GOALS:
        var b := Button.new()
        b.text = GOALS[g]
        b.custom_minimum_size = Vector2(150,70)
        b.pressed.connect(func(): _new_goal(g))
        row.add_child(b)
    var run := Button.new()
    run.text = "Пауза"
    run.custom_minimum_size = Vector2(220,70)
    run.pressed.connect(func():
        running = not running
        run.text = "Пауза" if running else "Продолжить")
    root.add_child(run)
    var export := Button.new()
    export.text = "Экспортировать умения"
    export.custom_minimum_size = Vector2(300,70)
    export.pressed.connect(_export_all)
    root.add_child(export)
    var info := Label.new()
    info.text = "Автооценка: падение = минус, выполнение цели без падения = плюс. 10 успешных эпизодов подряд — автоматическое сохранение."
    info.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
    info.add_theme_font_size_override("font_size",20)
    root.add_child(info)

func _spawn(n:int) -> void:
    for a in agents:
        a.queue_free()
    agents.clear()
    for i in n:
        var a:Node3D = AgentS.new()
        add_child(a)
        a.setup(self,i,Vector3((i-(n-1)*0.5)*1.7,0,0))
        a.sigma_mul = [1.0,0.6,1.5,2.2][i%4]
        agents.append(a)
    n_dof=agents[0].n_dof
    n_in=agents[0].n_in
    n_out=agents[0].n_out
    n_w=n_in*N_HID+N_HID+N_HID*n_out+n_out
    act=[]
    for i in n_dof:
        act.append(groups[agents[0].d_g[i]])
    for i in 3:
        act.append(groups["thrust"])

func _new_goal(g:String) -> void:
    if not GOALS.has(g):
        return
    _save_current()
    goal=g
    episode=0
    success_streak=0
    total_success=0
    best_score=-1.0e9
    sigma=0.05
    if skills.has(goal) and (skills[goal].get("w",[]) as Array).size()==n_w:
        w=PackedFloat32Array(skills[goal]["w"])
        episode=int(skills[goal].get("episodes",0))
    else:
        w=PackedFloat32Array()
        w.resize(n_w)
        for i in n_w:
            w[i]=randfn(0.0,0.03)
    _restart_all()
    status.text="Цель: %s" % GOALS[goal]

func _restart_all() -> void:
    for a in agents:
        a.cur_w=w.duplicate()
        a.done=false
        a.bonus=0.0
        a.events.clear()
        a.step=-1

func _mutate(mul:float)->PackedFloat32Array:
    var c=w.duplicate()
    var o2=n_in*N_HID+N_HID
    var o3=o2+N_HID*n_out
    var sg=sigma*mul
    for k in n_out:
        if not act[k]:
            continue
        for j in N_HID:
            if randf()<MUT_P:
                c[o2+k*N_HID+j]+=randfn(0,sg)
        if randf()<MUT_P:
            c[o3+k]+=randfn(0,sg)
    return c

func _physics_process(_d:float) -> void:
    if not running:
        return
    var all_done=true
    for a in agents:
        if a.done:
            continue
        if a.tick():
            a.finish()
        if not a.done:
            all_done=false
    if all_done:
        _round_end()
    hud.text="Эпизод: %d | подряд: %d/%d | всего +: %d | sigma %.3f\nПоследний: %s\nВариантов: %d | скорость: %.1fx" % [episode,success_streak,SUCCESS_STREAK,total_success,sigma,last_result,agents.size(),Engine.time_scale]

func _success(a)->bool:
    if not a.finite() or a.fell:
        return false
    var rb=a.bodies[a.root_i]
    var R=rb.global_transform.basis*a.root_rest_inv
    var upright=R.y.y>=0.75 and rb.global_position.y>=0.7*a.h0
    if goal=="stand":
        return upright
    if goal=="walk":
        return upright and (rb.global_position.z-a.start.z)>=0.35
    if goal=="jump":
        return a.max_h>=a.h0+0.30 and upright
    if goal=="fly":
        return a.sum_h/float(max(a.step,1))>=a.h0+0.45
    return false

func _round_end() -> void:
    var top=agents[0]
    var top_score=-1.0e9
    for a in agents:
        var sc=(1.0 if _success(a) else -1.0)+0.001*float(a.score())
        if sc>top_score:
            top_score=sc
            top=a
    var ok=_success(top)
    episode+=1
    if ok:
        success_streak+=1
        total_success+=1
        last_result="+1 — цель выполнена без падения"
    else:
        success_streak=0
        last_result="−1 — падение или цель не выполнена"
    if ok and (top_score>best_score or best_score < -1.0e8):
        best_score=top_score
        w=top.cur_w.duplicate()
        sigma=min(sigma*1.08,0.30)
    elif not ok:
        sigma=max(sigma*0.995,0.01)
    if success_streak>=SUCCESS_STREAK:
        _save_current()
        _export_goal()
        last_result="✓ 10 успешных эпизодов подряд — навык сохранён и экспортирован"
        success_streak=0
    for a in agents:
        a.cur_w=_mutate(a.sigma_mul)
        a.done=false
        a.bonus=0.0
        a.events.clear()
        a.step=-1

func _save_current() -> void:
    if w.size()!=n_w:
        return
    var arr=[]
    for v in w:
        arr.append(snappedf(v,0.0001))
    skills[goal]={"w":arr,"episodes":episode,"best":best_score,"success_streak":success_streak}
    _save_file()

func _save_file() -> void:
    var f=FileAccess.open(SAVE,FileAccess.WRITE)
    if f:
        f.store_string(JSON.stringify(skills))
    DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(EXPORT_DIR))

func _export_goal() -> void:
    _save_current()
    var f=FileAccess.open(EXPORT_DIR+"/skill_"+goal+".json",FileAccess.WRITE)
    if f:
        f.store_string(JSON.stringify(skills.get(goal,{})))
    var all=FileAccess.open(EXPORT_DIR+"/skills_auto.json",FileAccess.WRITE)
    if all:
        all.store_string(JSON.stringify(skills))

func _export_all() -> void:
    _save_current()
    _export_goal()
    DisplayServer.clipboard_set(JSON.stringify(skills))
    last_result="Экспорт готов: skills_auto.json + skill_"+goal+".json"

func _load_skills() -> void:
    if not FileAccess.file_exists(SAVE):
        return
    var j=JSON.parse_string(FileAccess.get_file_as_string(SAVE))
    if j is Dictionary:
        skills=j
