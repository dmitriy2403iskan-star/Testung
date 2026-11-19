#!/usr/bin/env python3
"""Второй хостинг: только считает кандидатов для главного сервера (ROLE=worker).
POST /eval (JSON задания как у локального воркера) -> JSON результата. GET / -> статус.
Переменные: WORKERS (процессов Godot), WTOKEN (общий пароль), PORT."""
import os, sys, json, shutil, subprocess, threading, queue, time, socket, http.server, socketserver

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import kaggle_run as K
import cma_run

PORT = int(os.environ.get("PORT", "8080"))
TOKEN = os.environ.get("WTOKEN", "")
N = int(os.environ.get("WORKERS", os.cpu_count() or 2))
FREE = queue.Queue()
POOL = {}
STAT = {"done": 0, "t0": time.time(), "ready": False}


def setup():
    godot = K.get_godot()
    work = os.path.abspath("work")
    if os.path.exists(work):
        shutil.rmtree(work)
    shutil.copytree(K.REPO, work, ignore=shutil.ignore_patterns(".git", "web", "logs"))
    shutil.copy(os.path.join(work, "ci", "cma_worker.gd"), os.path.join(work, "cma_worker.gd"))
    pg = os.path.join(work, "project.godot")
    s = open(pg, encoding="utf-8").read().replace("[autoload]", '[autoload]\nTrainer="*res://cma_worker.gd"', 1)
    open(pg, "w", encoding="utf-8").write(s)
    subprocess.run('"%s" --headless --import' % godot, shell=True, cwd=work, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    POOL["p"] = cma_run.Pool(godot, work, N)
    for i in range(N):
        FREE.put(i)
    STAT["ready"] = True
    print("Удалённый воркер готов: процессов %d" % N, flush=True)


def eval_task(task):
    p = POOL["p"]
    wi = FREE.get()
    try:
        d = p.dirs[wi]
        rp = os.path.join(d, "res.json")
        if os.path.exists(rp):
            os.remove(rp)
        tmp = os.path.join(d, "task.tmp")
        json.dump(task, open(tmp, "w"))
        os.replace(tmp, os.path.join(d, "task.json"))
        t0 = time.time()
        while True:
            time.sleep(0.1)
            if os.path.exists(rp):
                try:
                    r = json.load(open(rp))
                except Exception:
                    continue
                if r["gen"] == task["gen"] and r["chunk"] == task["chunk"]:
                    STAT["done"] += 1
                    return r
            if p.procs[wi].poll() is not None or time.time() - t0 > 900:
                raise RuntimeError("процесс умер или завис")
    finally:
        FREE.put(wi)


class H(http.server.BaseHTTPRequestHandler):
    def _send(self, code, body):
        b = body.encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Length", str(len(b)))
        self.end_headers()
        self.wfile.write(b)

    def do_GET(self):
        self._send(200, "worker ready=%s done=%d up=%ds\n" % (STAT["ready"], STAT["done"], time.time() - STAT["t0"]))

    def do_POST(self):
        if TOKEN and self.headers.get("X-Token") != TOKEN:
            return self._send(403, "no")
        if not STAT["ready"]:
            return self._send(503, "not ready")
        try:
            task = json.loads(self.rfile.read(int(self.headers.get("Content-Length", "0"))))
            self._send(200, json.dumps(eval_task(task)))
        except Exception as e:
            self._send(500, str(e))

    def log_message(self, *a):
        pass


class S(socketserver.ThreadingMixIn, http.server.HTTPServer):
    address_family = socket.AF_INET6   # приватная сеть Railway работает по IPv6
    daemon_threads = True

    def server_bind(self):
        self.socket.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 0)
        super().server_bind()


if __name__ == "__main__":
    threading.Thread(target=setup, daemon=True).start()
    try:
        srv = S(("::", PORT), H)
    except OSError:   # без IPv6 (например, локальный тест)
        S.address_family = socket.AF_INET
        S.server_bind = socketserver.TCPServer.server_bind
        srv = S(("", PORT), H)
    srv.serve_forever()
