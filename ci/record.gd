extends Node
# Запись видео: проигрывает сохранённое умение (REPLAY_FILE = json чекпоинта), без мутаций.
# ENV: REPLAY_FILE, FRAMES (кадров при 30 fps), SUP (необязательно, переопределяет подвес)
var f := 0
var sim
var own := false   # режим «острова»: сам гоняю эпизоды, чтобы веса не перезаписывались
func _process(_d):
    f += 1
    if f == 3:
        sim = get_tree().current_scene
        var r = JSON.parse_string(FileAccess.get_file_as_string(OS.get_environment("REPLAY_FILE")))
        var goal: String = r["goal"]
        sim.w = PackedFloat32Array()   # чтобы _set_goal не затёр умение случайными весами
        sim.skills[goal] = r["skill"]
        sim._set_goal(goal)
        sim.sigma = 0.0
        sim.auto_on = false
        var sup := int(r.get("support", 0))
        if OS.get_environment("SUP") != "":
            sup = int(OS.get_environment("SUP"))
        sim.set_support(sup)
        sim.sigma = 0.0
        sim.focus = -1
        sim.menu_box.visible = false   # в видео только мир и HUD
        sim.cam_dist = 3.4
        sim.cam_pitch = 16.0
        if r.has("ep"):
            sim.ep_steps = int(float(r["ep"]) * float(Engine.physics_ticks_per_second))
        if r.has("islands"):
            own = true
            sim.set_physics_process(false)   # 8 разных подходов: каждому человеку свои веса и своя доля нейросети
            for i in sim.agents.size():
                var isl: Dictionary = r["islands"][mini(i, r["islands"].size() - 1)]
                sim.agents[i].cur_w = PackedFloat32Array(isl["w"])
                sim.agents[i].mix_override = float(isl.get("mix", -1.0))
        print("replay goal=", goal, " support=", sup, " gait=", sim.gait_on)
    if f > 3 and f % 30 == 0:
        sim.sigma = 0.0
    if f >= int(OS.get_environment("FRAMES")):
        get_tree().quit()

func _physics_process(_d):
    if not own or sim == null:
        return
    var all_done := true
    for a in sim.agents:
        if a.done:
            continue
        if a.tick():
            a.finish()
        else:
            all_done = false
    if all_done:
        for a in sim.agents:
            a.done = false
            a.fell = false
            a.step = -1
