extends Node
# Автообучение в CI: ENV GOAL (stand|walk), GAITFILE, SECS, OUT (файл результата), SUP (стартовый подвес)
var f := 0
var sim
var t0 := 0
var last_save := 0

func _write(final: bool) -> void:
    sim._store()
    var sk: Dictionary = sim.skills.get(sim.goal, {})
    var res := {"goal": sim.goal, "support": sim.support, "mastered": sim.mastered, "eps": sim.eps,
        "best": sim.best, "final": final, "skill": sk}
    var fa := FileAccess.open(OS.get_environment("OUT"), FileAccess.WRITE)
    if fa:
        fa.store_string(JSON.stringify(res))
        fa.close()

func _process(_d):
    f += 1
    if f == 3:
        sim = get_tree().current_scene
        t0 = Time.get_ticks_msec()
        var gf := OS.get_environment("GAITFILE")
        if gf != "":
            print("gait err=", sim.set_gait(JSON.parse_string(FileAccess.get_file_as_string(gf))))
            sim.gait_on = true
        sim._set_goal(OS.get_environment("GOAL"))
        sim.set_support(int(OS.get_environment("SUP")))
        sim.gait_on = gf != ""
    if sim == null:
        return
    var el := (Time.get_ticks_msec() - t0) / 1000
    if f % 600 == 0:
        print("T=%ds %s eps=%d best=%.2f sup=%d sigma=%.3f ok=%d mastered=%d" % [el, sim.goal, sim.eps, sim.best, sim.support, sim.sigma, sim.ok_rounds, sim.mastered])
    if el - last_save >= 300:
        last_save = el
        _write(false)
    if el > int(OS.get_environment("SECS")) or (sim.mastered >= 3 and el > 600):
        _write(true)
        print("DONE mastered=", sim.mastered, " support=", sim.support)
        get_tree().quit()
