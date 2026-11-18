extends Node
# Рабочий процесс для CMA-ES: ждёт задание (WDIR/task.json: цель, подвес, походка, до 8 наборов весов),
# прогоняет один эпизод всеми людьми сразу и пишет WDIR/res.json (оценки по каждому набору).
var sim
var f := 0
var running := false
var job := {}
var cur_goal := ""
var cur_gait := ""
var wdir := ""

func _process(_d):
    f += 1
    if f == 3:
        wdir = OS.get_environment("WDIR")
        sim = get_tree().current_scene
        sim.auto_on = false
        sim.sigma = 0.0
        sim.set_physics_process(false)   # эпизодами управляю я
        print("worker ready ", wdir)
    if sim == null or running or f % 15 != 0:
        return
    var tp := wdir + "/task.json"
    if not FileAccess.file_exists(tp):
        return
    var txt := FileAccess.get_file_as_string(tp)
    var j = JSON.parse_string(txt)
    if typeof(j) != TYPE_DICTIONARY:
        return   # файл ещё пишется
    job = j
    _start_job()

func _start_job() -> void:
    var goal: String = job["goal"]
    var gf: String = job.get("gait", "")
    if goal != cur_goal or gf != cur_gait:
        if gf != "":
            sim.set_gait(JSON.parse_string(FileAccess.get_file_as_string("res://" + gf)))
            sim.gait_on = true
        sim._set_goal(goal)
        sim.gait_on = gf != ""
        cur_goal = goal
        cur_gait = gf
    sim.set_support(int(job["support"]))
    var cands: Array = job["cands"]
    for i in sim.agents.size():
        var a = sim.agents[i]
        a.cur_w = PackedFloat32Array(cands[mini(i, cands.size() - 1)])
        a.bonus = 0.0
        a.events.clear()
        a.done = false
        a.fell = false
        a.step = -1
    running = true

func _physics_process(_d):
    if not running:
        return
    var all_done := true
    for a in sim.agents:
        if a.done:
            continue
        if a.tick():
            a.finish()
        else:
            all_done = false
    if not all_done:
        return
    var n: int = job["cands"].size()
    var sc := []
    var ok := []
    var fwd := []
    var hm := []
    for i in n:
        var a = sim.agents[i]
        sc.append(a.res)
        var h: float = a.sum_h / float(sim.ep_steps)
        var good: bool = sim._agent_ok(a) and h > 0.8 * a.h0
        ok.append(1 if good else 0)
        fwd.append(a.fin_fwd)
        hm.append(h)
    var out := {"gen": job["gen"], "chunk": job["chunk"], "scores": sc, "ok": ok, "fwd": fwd, "h": hm}
    var tmp := wdir + "/res.tmp"
    var fa := FileAccess.open(tmp, FileAccess.WRITE)
    fa.store_string(JSON.stringify(out))
    fa.close()
    DirAccess.rename_absolute(tmp, wdir + "/res.json")
    DirAccess.remove_absolute(wdir + "/task.json")
    running = false
