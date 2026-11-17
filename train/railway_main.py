#!/usr/bin/env python3
"""Точка входа для Railway/любого Docker-хоста: обучает и одновременно отдаёт статус и результат по HTTP.
  GET /            - живой статус обучения (текст)
  GET /result.zip  - результат после окончания
Переменные: SECS (по умолчанию 10800), PROCS, PORT (даёт хост)."""
import os, sys, threading, http.server, socketserver

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import kaggle_run

PORT = int(os.environ.get("PORT", "8080"))
ROOT = os.path.abspath(".")


class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        path = self.path.split("?")[0]
        if path in ("/", "/status"):
            f = os.path.join(kaggle_run.RES, "status.txt")
            body = open(f, "rb").read() if os.path.exists(f) else "Запускается, жди 1-2 минуты...\n".encode()
            ctype = "text/plain; charset=utf-8"
        else:
            name = path.lstrip("/")
            f = os.path.join(ROOT, name) if name == "result.zip" else os.path.join(kaggle_run.RES, name)
            if ".." in name or not os.path.isfile(f):
                self.send_error(404)
                return
            body = open(f, "rb").read()
            ctype = "application/zip" if name.endswith(".zip") else "text/plain; charset=utf-8"
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
