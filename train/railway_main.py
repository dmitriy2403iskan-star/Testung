#!/usr/bin/env python3
"""Точка входа для Railway/любого Docker-хоста: обучает и одновременно отдаёт статус и результат по HTTP.
  GET /            - живой статус обучения (текст)
  GET /result.zip  - результат после окончания
  GET /rec         - страница записи видео: выбрать чекпоинт и длину, нажать "Записать"
  GET /record?which=walk_b&secs=30 - снять видео с текущего состояния обучения (потом /video.mp4)
Переменные: SECS (по умолчанию 10800), PROCS, PORT (даёт хост)."""
import os, sys, time, shutil, subprocess, threading, http.server, socketserver

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import kaggle_run

PORT = int(os.environ.get("PORT", "8080"))
ROOT = os.path.abspath(".")
REC = os.path.abspath("rec")
REC_ST = {"state": "нет", "msg": "Видео ещё не запрашивали", "t": 0}
REC_LOCK = threading.Lock()
NAMES = ["stand_a", "walk_a", "stand_b", "walk_b"]


def rec_prepare():
    """Копия проекта для рендера: тот же импорт, но вместо Trainer автозагружается Recorder."""
    if os.path.exists(os.path.join(REC, "project.godot")):
        return
    os.makedirs(REC, exist_ok=True)
    shutil.copytree(kaggle_run.WORK, REC, dirs_exist_ok=True, ignore=shutil.ignore_patterns("out", "xdg_*"))
    pg = os.path.join(REC, "project.godot")
    s = open(pg, encoding="utf-8").read().replace('Trainer="*res://train.gd"', 'Recorder="*res://record.gd"')
    open(pg, "w", encoding="utf-8").write(s)
    shutil.copy(os.path.join(REC, "ci", "record.gd"), os.path.join(REC, "record.gd"))


def rec_job(which, secs, snap):
    try:
        REC_ST.update(state="идёт", msg="Рендерю %d с видео (%s). Это занимает несколько минут." % (secs, which), t=time.time())
        rec_prepare()
        out = os.path.join(REC, "out.avi")
        env = dict(os.environ, NO_LLM="1", REPLAY_FILE=snap, FRAMES=str(secs * 30),
                   XDG_DATA_HOME=os.path.join(REC, "xdg"), XDG_CONFIG_HOME=os.path.join(REC, "xdg", "cfg"))
        cmd = ('nice -n 5 xvfb-run -a -s "-screen 0 720x1280x24" "%s" --rendering-driver opengl3 '
               '--write-movie out.avi --fixed-fps 30 --resolution 540x960' % kaggle_run.get_godot())
        r = subprocess.run(cmd, shell=True, cwd=REC, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=3 * 3600)
        if not shutil.which("ffmpeg"):   # на случай, если при старте контейнера пакет не поставился
            REC_ST["msg"] = "Ставлю ffmpeg..."
            subprocess.run("apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq ffmpeg", shell=True, check=True)
        tmp = os.path.join(REC, "video_new.mp4")
        subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-i", out, "-c:v", "libx264", "-pix_fmt", "yuv420p",
                        "-crf", "26", tmp], check=True)
        os.replace(tmp, os.path.join(kaggle_run.RES, "video.mp4"))
        REC_ST.update(state="готово", msg="Видео готово (%s, %d с, снято в %s). Скачать: /video.mp4" % (
            which, secs, time.strftime("%H:%M:%S UTC", time.gmtime(REC_ST["t"]))))
    except Exception as e:
        REC_ST.update(state="ошибка", msg="Не вышло: %s" % e)
    finally:
        REC_LOCK.release()


def rec_start(which, secs):
    f = os.path.join(kaggle_run.WORK, "out", which + ".json")
    if which not in NAMES or not os.path.exists(f):
        return "Нет чекпоинта %s (обучение его ещё не сохранило, подожди минуту)" % which
    if not REC_LOCK.acquire(blocking=False):
        return "Запись уже идёт: " + REC_ST["msg"]
    os.makedirs(REC, exist_ok=True)
    snap = os.path.join(REC, "snap.json")
    shutil.copy(f, snap)   # снимок состояния в момент запроса
    threading.Thread(target=rec_job, args=(which, secs, snap), daemon=True).start()
    return "Запись пошла: %s, %d с. Смотри статус на /rec" % (which, secs)


def rec_page(note=""):
    opts = "".join('<option>%s</option>' % n for n in NAMES)
    link = ' <a href="/video.mp4">Скачать видео</a>' if os.path.exists(os.path.join(kaggle_run.RES, "video.mp4")) else ""
    return ("""<!doctype html><meta charset=utf-8><meta name=viewport content="width=device-width,initial-scale=1">
<body style="font:18px sans-serif;max-width:520px;margin:20px auto;padding:0 12px"><h3>Запись видео</h3>
<form action=/record><p>Кто: <select name=which>%s</select></p>
<p>Секунд: <input name=secs type=number value=30 min=5 max=60></p><button style="font-size:20px">Записать</button></form>
<p>%s</p><p><b>Статус:</b> %s.%s</p><p><a href=/rec>Обновить</a> | <a href=/>Статус обучения</a></p>
<p style="color:#888;font-size:14px">Берётся последнее сохранение обучения (обновляется раз в минуту). Рендер идёт параллельно с обучением, 30 с видео ≈ 5-15 мин.</p>""" % (opts, note, REC_ST["msg"], link)).encode("utf-8")


class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        path, _, qs = self.path.partition("?")
        if path in ("/rec", "/record"):
            q = dict(p.split("=", 1) for p in qs.split("&") if "=" in p)
            note = ""
            if path == "/record":
                try:
                    secs = max(5, min(60, int(q.get("secs", "30"))))
                except ValueError:
                    secs = 30
                note = rec_start(q.get("which", "walk_b"), secs)
            body = rec_page(note)
            ctype = "text/html; charset=utf-8"
        elif path in ("/", "/status"):
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
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *a):
        pass


def serve():
    socketserver.ThreadingTCPServer.allow_reuse_address = True
    with socketserver.ThreadingTCPServer(("", PORT), H) as srv:
        srv.serve_forever()


if __name__ == "__main__":
    os.makedirs(kaggle_run.RES, exist_ok=True)
    threading.Thread(target=serve, daemon=True).start()
    kaggle_run.main()
    print("Обучение закончено; сервер отдаёт результат. Можно остановить сервис.", flush=True)
    threading.Event().wait()   # держим процесс, чтобы можно было скачать result.zip
