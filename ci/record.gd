extends Node
# Запись видео: проигрывает сохранённое умение (REPLAY_FILE = json чекпоинта), без мутаций.
# ENV: REPLAY_FILE, FRAMES (кадров при 30 fps), SUP (необязательно, переопределяет подвес)
var f := 0
var sim
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
        print("replay goal=", goal, " support=", sup, " gait=", sim.gait_on)
    if f > 3 and f % 30 == 0:
        sim.sigma = 0.0
    if f >= int(OS.get_environment("FRAMES")):
        get_tree().quit()
