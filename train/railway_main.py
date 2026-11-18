#!/usr/bin/env python3
"""Точка входа для Railway/любого Docker-хоста: обучает и одновременно отдаёт статус и результат по HTTP.
  GET /            - живой статус обучения (текст)
  GET /result.zip  - результат после окончания
  GET /rec         - страница записи видео: выбрать чекпоинт и длину, нажать "Записать"
  GET /record?which=walk_b&secs=30 - снять видео с текущего состояния обучения (потом /video.mp4)
Переменные: SECS (по умолчанию 10800), PROCS, PORT (даёт хост)."""
import os, re, glob, sys, json, urllib.parse, time, signal, shutil, subprocess, threading, http.server, socketserver

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
try:
    import numpy  # noqa
except ImportError:
    subprocess.run([sys.executable, "-m", "pip", "install", "-q", "numpy"], check=False)
import kaggle_run
import cma_run

PORT = int(os.environ.get("PORT", "8080"))
ROOT = os.path.abspath(".")
REC = os.path.abspath("rec")
REC_ST = {"state": "нет", "msg": "Видео ещё не запрашивали", "t": 0}
REC_LOCK = threading.Lock()
REC_PROC = {"p": None, "cancel": False}
VID_TTL = 1200   # история записей: видео живёт 20 минут, потом удаляется
NAMES = ["stand", "walk", "jump", "box"]


def rec_banner():
    """Понятная плашка про видео для страницы статуса."""
    st, now = REC_ST["state"], time.time()
    if st == "нет":
        return "🎥 Видео: не записывается. Запись: ссылка «Записать видео» или команда /rec stand 30"
    mins = int((now - REC_ST.get("began", REC_ST["t"])) / 60)
    began = cma_run.hhmm(REC_ST.get("began", REC_ST["t"]))
    if st == "идёт":
        return "🎥 ВИДЕО ЗАПИСЫВАЕТСЯ (%s). Начато в %s, идёт %d мин. %s. Отмена: /cancel" % (REC_ST.get("pos", ""), began, mins, REC_ST["msg"])
    if st == "готово":
        return "✅ ВИДЕО ГОТОВО. %s Смотри историю на /rec (хранится 20 минут)." % REC_ST["msg"]
    if st == "отменено":
        return "⏹ Запись видео отменена."
    return "❌ ВИДЕО НЕ ВЫШЛО: %s" % REC_ST["msg"]


def rec_prepare():
    """Копия проекта для рендера: тот же импорт, но вместо Trainer автозагружается Recorder."""
    if os.path.exists(os.path.join(REC, "project.godot")):
        return
    os.makedirs(REC, exist_ok=True)
    shutil.copytree(kaggle_run.WORK, REC, dirs_exist_ok=True, ignore=shutil.ignore_patterns("out", "xdg_*"))
    pg = os.path.join(REC, "project.godot")
    s = re.sub(r'Trainer="\*res://[a-z_]+\.gd"', 'Recorder="*res://record.gd"', open(pg, encoding="utf-8").read())
    open(pg, "w", encoding="utf-8").write(s)
    shutil.copy(os.path.join(REC, "ci", "record.gd"), os.path.join(REC, "record.gd"))


def rec_one(which, secs, snap):
    REC_ST.update(state="идёт", msg="Рендерю %d с видео (%s). Это занимает несколько минут." % (secs, which), t=time.time())
    rec_prepare()
    out = os.path.join(REC, "out.avi")
    if os.path.exists(out):
        os.remove(out)
    if not (shutil.which("ffmpeg") and shutil.which("xvfb-run")):   # пакеты не поставились при старте
        REC_ST["msg"] = "Ставлю xvfb и ffmpeg (1-2 мин)..."
        r = subprocess.run("apt-get update -qq; DEBIAN_FRONTEND=noninteractive apt-get install -y xvfb ffmpeg "
                           "libgl1-mesa-dri libglu1-mesa libgl1 libegl1 libxcursor1 libxinerama1 libxrandr2 libxi6",
                           shell=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        if not (shutil.which("ffmpeg") and shutil.which("xvfb-run")):
            raise RuntimeError("apt не поставил пакеты: " + r.stdout[-400:])
    REC_ST["msg"] = "Рендерю %d с видео (%s). Это занимает несколько минут." % (secs, which)
    env = dict(os.environ, NO_LLM="1", REPLAY_FILE=snap, FRAMES=str(secs * 30),
               XDG_DATA_HOME=os.path.join(REC, "xdg"), XDG_CONFIG_HOME=os.path.join(REC, "xdg", "cfg"))
    cmd = ('nice -n 5 xvfb-run -a -s "-screen 0 720x1280x24" "%s" --rendering-driver opengl3 '
           '--write-movie %s --fixed-fps 30 --resolution 540x960' % (kaggle_run.get_godot(), out))
    pr = subprocess.Popen(cmd, shell=True, cwd=REC, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                          text=True, start_new_session=True)
    REC_PROC["p"] = pr
    try:
        o, _ = pr.communicate(timeout=3 * 3600)
    except subprocess.TimeoutExpired:
        os.killpg(pr.pid, signal.SIGKILL)
        o, _ = pr.communicate()
    REC_PROC["p"] = None
    if REC_PROC["cancel"]:
        REC_ST.update(state="отменено", msg="Запись отменена")
        return False

    class r:
        stdout, returncode = o or "", pr.returncode
    open(os.path.join(REC, "render.log"), "w").write(r.stdout)
    if not os.path.exists(out):
        raise RuntimeError("Godot не создал видео (код %s): %s" % (r.returncode, r.stdout[-500:]))
    tmp = os.path.join(REC, "video_new.mp4")
    subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-i", out, "-c:v", "libx264", "-pix_fmt", "yuv420p",
                    "-crf", "26", tmp], check=True)
    os.replace(tmp, os.path.join(kaggle_run.RES, "video_%s_%d.mp4" % (which, int(time.time()))))
    return True


def rec_job(items, secs):
    """items: [(имя, снимок)]; по очереди снимает каждое. Минимум 5 секунд на каждый вариант."""
    try:
        t0 = time.time()
        REC_ST["began"] = t0
        done = []
        for n, (which, snap) in enumerate(items):
            REC_ST["pos"] = "%d из %d" % (n + 1, len(items))
            if not rec_one(which, secs, snap):
                return
            done.append(which)
        REC_ST.update(state="готово", msg="Готово: %s (%d с каждое, начато в %s по Киеву)." % (", ".join(done), secs, cma_run.hhmm(t0)))
    except Exception as e:
        REC_ST.update(state="ошибка", msg="Не вышло: %s" % e)
    finally:
        REC_LOCK.release()


def rec_start(which, secs):
    names = [n for n in NAMES if os.path.exists(os.path.join(kaggle_run.WORK, "out", n + ".json"))] if which == "all" else [which]
    for w in names:
        if w not in NAMES or not os.path.exists(os.path.join(kaggle_run.WORK, "out", w + ".json")):
            return "Нет чекпоинта %s (обучение его ещё не сохранило, подожди минуту)" % w
    if not REC_LOCK.acquire(blocking=False):
        return "Запись уже идёт: " + REC_ST["msg"]
    REC_PROC["cancel"] = False
    os.makedirs(REC, exist_ok=True)
    items = []
    for w in names:   # снимки состояния в момент запроса
        snap = os.path.join(REC, "snap_%s.json" % w)
        shutil.copy(os.path.join(kaggle_run.WORK, "out", w + ".json"), snap)
        items.append((w, snap))
    threading.Thread(target=rec_job, args=(items, secs), daemon=True).start()
    return "Запись пошла: %s, по %d с. Смотри статус на /rec" % (", ".join(names), secs)


def rec_cancel():
    p = REC_PROC["p"]
    if not REC_LOCK.locked():
        return "Сейчас ничего не записывается"
    REC_PROC["cancel"] = True
    if p is not None:
        try:
            os.killpg(p.pid, signal.SIGKILL)
        except Exception:
            pass
    REC_ST.update(state="отменено", msg="Запись отменена")
    return "Отменяю запись..."


def rec_page(note=""):
    opts = "".join('<option value="%s">%s</option>' % (n, t) for n, t in [("all", "Все, что уже обучается"), ("stand", "stand: стойка"), ("walk", "walk: ходьба"), ("jump", "jump: прыжки"), ("box", "box: коробка")])
    rows = []
    for f in sorted(glob.glob(os.path.join(kaggle_run.RES, "video_*_*.mp4")), key=os.path.getmtime, reverse=True):
        m = os.path.getmtime(f)
        left = max(0, int((VID_TTL - (time.time() - m)) / 60))
        n = os.path.basename(f)
        rows.append('<li>%s, <b>%s</b> (%.1f МБ): <a href="/%s">скачать</a>, удалится через %d мин</li>' % (
            cma_run.hhmm(m), n.split("_")[1], os.path.getsize(f) / 1e6, n, left))
    link = "<ul>%s</ul>" % "".join(rows) if rows else " Записей пока нет."
    return ("""<!doctype html><meta charset=utf-8><meta name=viewport content="width=device-width,initial-scale=1">
<body style="font:18px sans-serif;max-width:520px;margin:20px auto;padding:0 12px"><h3>Запись видео</h3>
<form action=/record><p>Кто: <select name=which>%s</select></p>
<p>Секунд: <input name=secs type=number value=30 min=5 max=60></p><button style="font-size:20px">Записать</button></form>
<p><a href=/cancel style="font-size:18px">Отменить запись</a></p>
<p>%s</p><p><b>Статус:</b> %s.</p><p><b>История записей (по Киеву):</b>%s</p><p><a href=/rec>Обновить</a> | <a href=/>Статус обучения</a></p>
<p style="color:#888;font-size:14px">Берётся последнее сохранение обучения (обновляется раз в минуту). История записей хранится 20 минут, потом старые удаляются. Рендер идёт параллельно с обучением, 30 с видео ≈ 5-15 мин.</p>""" % (opts, note, REC_ST["msg"], link)).encode("utf-8")


TRAIN = {"thread": None}


def train_start(force):
    def run():
        try:
            cma_run.main(force=force)
        except Exception:   # сервер остаётся жить, чтобы можно было прочитать ошибку
            import traceback
            err = traceback.format_exc()
            print(err, flush=True)
            open(os.path.join(kaggle_run.RES, "status.txt"), "w", encoding="utf-8").write("ОШИБКА ОБУЧЕНИЯ:\n" + err)
    t = threading.Thread(target=run, daemon=True)
    TRAIN["thread"] = t
    t.start()


def status_text():
    f = os.path.join(kaggle_run.RES, "status.txt")
    return open(f, encoding="utf-8").read() if os.path.exists(f) else "Запускается, жди 1-2 минуты...\n"


HELP = ("Команды:\n/stop - остановить обучение (веса сохраняются, скажу где)\n/start - продолжить остановленное обучение\n"
        "/rec stand 30 - записать видео (stand, walk, jump, box или all; секунд 5-60)\n/cancel - отменить запись видео\n"
        "/status - показать статус\n/help - эта подсказка")


def run_cmd(raw):
    parts = raw.strip().split()
    if not parts:
        return HELP
    c = parts[0].lower().lstrip("/")
    alive = TRAIN["thread"] is not None and TRAIN["thread"].is_alive()
    if c in ("help", "?", "h"):
        return HELP
    if c == "stop":
        if not alive:
            return "Обучение уже не идёт. Сохранённые веса: смотри статус."
        cma_run.STOP.set()
        return "Останавливаю обучение. Закончу текущее поколение (до минуты), сохраню веса и покажу в статусе, где они лежат."
    if c == "start":
        if alive:
            return "Обучение уже идёт."
        cma_run.STOP.clear()
        train_start(True)
        return "Запускаю обучение с сохранённого места. Первые строки статуса появятся через 1-2 минуты."
    if c == "rec":
        which = parts[1] if len(parts) > 1 else "all"
        try:
            secs = max(5, min(60, int(parts[2]))) if len(parts) > 2 else 30
        except ValueError:
            secs = 30
        return rec_start(which, secs)
    if c == "cancel":
        return rec_cancel()
    if c == "status":
        return status_text()
    return "Не знаю команду «%s».\n%s" % (raw.strip(), HELP)


PAGE = """<!doctype html><meta charset=utf-8><meta name=viewport content="width=device-width,initial-scale=1">
<title>Обучение</title><body style="font:15px sans-serif;margin:0;padding:10px;max-width:760px">
<div id=banner style="padding:10px;border-radius:8px;background:#e8f1ff;margin-bottom:8px;white-space:pre-wrap"></div>
<pre id=st style="white-space:pre-wrap;word-break:break-word;font:13px monospace"></pre>
<form id=f style="position:sticky;bottom:0;background:#fff;padding:8px 0;display:flex;gap:6px">
<input id=c placeholder="команда, например /stop" autocomplete=off style="flex:1;font-size:18px;padding:8px">
<button style="font-size:18px">OK</button></form>
<div id=r style="white-space:pre-wrap;color:#06c;margin:6px 0"></div>
<div style="color:#888;font-size:13px">Команды: /stop /start /rec stand 30 /cancel /help. <a href=/rec>Страница записи видео</a></div>
<script>
async function upd(){try{const j=await (await fetch('/state.json',{cache:'no-store'})).json();
document.getElementById('banner').textContent=j.banner;document.getElementById('st').textContent=j.status;}catch(e){}}
document.getElementById('f').onsubmit=async e=>{e.preventDefault();const v=document.getElementById('c').value;if(!v)return;
document.getElementById('c').value='';const t=await (await fetch('/cmd?c='+encodeURIComponent(v),{cache:'no-store'})).text();
document.getElementById('r').textContent=t;upd();};
upd();setInterval(upd,8000);
</script>"""


class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        path, _, qs = self.path.partition("?")
        if path == "/":
            body = PAGE.encode("utf-8")
            ctype = "text/html; charset=utf-8"
        elif path == "/state.json":
            body = json.dumps({"banner": rec_banner(), "status": status_text()}, ensure_ascii=False).encode("utf-8")
            ctype = "application/json; charset=utf-8"
        elif path == "/cmd":
            q = urllib.parse.parse_qs(qs)
            body = run_cmd((q.get("c") or [""])[0]).encode("utf-8")
            ctype = "text/plain; charset=utf-8"
        elif path in ("/stop", "/start"):
            body = run_cmd(path).encode("utf-8")
            ctype = "text/plain; charset=utf-8"
        elif path in ("/rec", "/record", "/cancel"):
            q = dict(p.split("=", 1) for p in qs.split("&") if "=" in p)
            note = ""
            if path == "/record":
                try:
                    secs = max(5, min(60, int(q.get("secs", "30"))))
                except ValueError:
                    secs = 30
                note = rec_start(q.get("which", "stand"), secs)
            if path == "/cancel":
                note = rec_cancel()
            body = rec_page(note)
            ctype = "text/html; charset=utf-8"
        elif path == "/status":
            f = os.path.join(kaggle_run.RES, "status.txt")
            body = open(f, "rb").read() if os.path.exists(f) else "Запускается, жди 1-2 минуты...\n".encode()
            body += "\nЗаписать видео: /rec\n".encode("utf-8")
            ctype = "text/plain; charset=utf-8"
        else:
            name = path.lstrip("/")
            f = os.path.join(ROOT, name) if name == "result.zip" else os.path.join(kaggle_run.RES, name)
            if ".." in name or not os.path.isfile(f):
                self.send_error(404)
                return
            body = open(f, "rb").read()
            ctype = "application/zip" if name.endswith(".zip") else "video/mp4" if name.endswith(".mp4") else "text/plain; charset=utf-8"
        self.send_response(200)
        self.send_header("Content-Type", ctype)
        self.send_header("Cache-Control", "no-store, no-cache, must-revalidate, max-age=0")
        self.send_header("Pragma", "no-cache")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *a):
        pass


def video_cleaner():
    while True:
        time.sleep(30)
        for f in glob.glob(os.path.join(kaggle_run.RES, "video_*.mp4")):
            try:
                if time.time() - os.path.getmtime(f) > VID_TTL:
                    os.remove(f)
            except OSError:
                pass


def serve():
    socketserver.ThreadingTCPServer.allow_reuse_address = True
    with socketserver.ThreadingTCPServer(("", PORT), H) as srv:
        srv.serve_forever()


if __name__ == "__main__":
    os.makedirs(kaggle_run.RES, exist_ok=True)
    threading.Thread(target=serve, daemon=True).start()
    threading.Thread(target=video_cleaner, daemon=True).start()
    train_start(False)
    last = None
    while True:   # плашка про видео дублируется в логи сервера при каждой смене состояния
        time.sleep(5)
        key = (REC_ST["state"], REC_ST.get("pos"), REC_ST["msg"])
        if key != last and REC_ST["state"] != "нет":
            print(rec_banner(), flush=True)
            last = key
