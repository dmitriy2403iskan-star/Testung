#!/usr/bin/env python3
"""Автообучение на Kaggle/Colab (только стандартная библиотека Python).
Запуск в ноутбуке (интернет включён):
    !git clone https://github.com/dmitriy2403iskan-star/Testung
    !python Testung/train/kaggle_run.py
Настройки через переменные окружения: SECS (секунд на обучение, по умолчанию 10800 = 3 ч),
PROCS (число процессов, по умолчанию число ядер, максимум 4), GODOT_BIN (готовый Godot, чтобы не качать).
Результат: папка result/ (pretrained/skills.json, REPORT.md, логи) и result.zip.
Если в Kaggle Secrets есть TESTUNG_PUSH_TOKEN (доступ к репозиторию), результат сам запушится в main."""
import os, sys, time, shutil, subprocess, zipfile, urllib.request, glob, json

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
WORK = os.path.abspath(os.environ.get("WORKDIR", "work"))
RES = os.path.abspath("result")
SECS = int(os.environ.get("SECS", "10800"))
PROCS = min(int(os.environ.get("PROCS", os.cpu_count() or 2)), 4)
GODOT_URL = "https://github.com/godotengine/godot/releases/download/4.2.2-stable/Godot_v4.2.2-stable_linux.x86_64.zip"


def sh(cmd, **kw):
    return subprocess.run(cmd, shell=True, **kw)


def get_godot():
    if os.environ.get("GODOT_BIN"):
        return os.environ["GODOT_BIN"]
    exe = os.path.abspath("godot/Godot_v4.2.2-stable_linux.x86_64")
    if not os.path.exists(exe):
        os.makedirs("godot", exist_ok=True)
        print("Скачиваю Godot 4.2.2...", flush=True)
        urllib.request.urlretrieve(GODOT_URL, "godot/g.zip")
        zipfile.ZipFile("godot/g.zip").extractall("godot")
        os.chmod(exe, 0o755)
    return exe


def status(logs, start):
    lines = ["Идёт %d мин из %d" % ((time.time() - start) / 60, SECS / 60)]
    for n, lg in logs.items():
        last = ""
        try:
            for ln in open(lg, encoding="utf-8", errors="ignore"):
                if ln.startswith("T="):
                    last = ln.strip()
        except Exception:
            pass
        lines.append("%s: %s" % (n, last))
    return "\n".join(lines)


def main():
    godot = get_godot()
    if os.path.exists(WORK):
        shutil.rmtree(WORK)
    shutil.copytree(REPO, WORK, ignore=shutil.ignore_patterns(".git", "web", "logs"))
    shutil.copy(os.path.join(WORK, "ci", "train.gd"), os.path.join(WORK, "train.gd"))
    pg = os.path.join(WORK, "project.godot")
    s = open(pg, encoding="utf-8").read().replace("[autoload]", '[autoload]\nTrainer="*res://train.gd"', 1)
    open(pg, "w", encoding="utf-8").write(s)
    print("Импорт проекта...", flush=True)
    sh('"%s" --headless --import' % godot, cwd=WORK, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    os.makedirs(os.path.join(WORK, "out"), exist_ok=True)
    plan = [("stand_a", "stand", "ci/gait_stand.json"), ("walk_a", "walk", "ci/gait_walk.json"),
            ("stand_b", "stand", "ci/gait_stand.json"), ("walk_b", "walk", "ci/gait_walk.json")][:PROCS]
    procs, logs = {}, {}
    for name, goal, gait in plan:
        xdg = os.path.join(WORK, "xdg_" + name)
        os.makedirs(xdg, exist_ok=True)
        env = dict(os.environ, NO_LLM="1", XDG_DATA_HOME=xdg, XDG_CONFIG_HOME=xdg + "/cfg", GOAL=goal,
                   GAITFILE=gait, SUP="3", SECS=str(SECS), OUT=os.path.join(WORK, "out", name + ".json"))
        logs[name] = os.path.join(WORK, "out", name + ".log")
        procs[name] = subprocess.Popen([godot, "--headless", "--fixed-fps", "240"], cwd=WORK, env=env,
                                       stdout=open(logs[name], "w"), stderr=subprocess.STDOUT)
    print("Запущено процессов: %d, на %d мин" % (len(procs), SECS // 60), flush=True)
    start = time.time()
    os.makedirs(RES, exist_ok=True)
    while any(p.poll() is None for p in procs.values()):
        time.sleep(60)
        print(status(logs, start), flush=True)
        for f in glob.glob(os.path.join(WORK, "out", "*.json")):  # промежуточные результаты
            shutil.copy(f, RES)
    print(status(logs, start), flush=True)
    sh("python3 %s" % os.path.join(WORK, "ci", "pack.py"), cwd=WORK)
    for f in glob.glob(os.path.join(WORK, "out", "*")):
        shutil.copy(f, RES)
    shutil.copytree(os.path.join(WORK, "pretrained"), os.path.join(RES, "pretrained"), dirs_exist_ok=True)
    with zipfile.ZipFile("result.zip", "w", zipfile.ZIP_DEFLATED) as z:
        for root, _, files in os.walk(RES):
            for fn in files:
                z.write(os.path.join(root, fn), os.path.relpath(os.path.join(root, fn), RES))
    print("\nГОТОВО. Отчёт:\n" + open(os.path.join(RES, "pretrained", "REPORT.md"), encoding="utf-8").read())
    push_result()


def push_result():
    tok = os.environ.get("TESTUNG_PUSH_TOKEN")   # только явно заданный токен, чужие переменные не берём
    if not tok:
        try:
            from kaggle_secrets import UserSecretsClient
            tok = UserSecretsClient().get_secret("TESTUNG_PUSH_TOKEN")
        except Exception:
            tok = None
    if not tok:
        print("TESTUNG_PUSH_TOKEN не задан: результат только в result.zip (скачай из Output).")
        return
    d = os.path.abspath("push_repo")
    shutil.rmtree(d, ignore_errors=True)
    sh("git clone -q https://x-access-token:%s@github.com/dmitriy2403iskan-star/Testung.git %s" % (tok, d))
    shutil.copytree(os.path.join(RES, "pretrained"), os.path.join(d, "pretrained"), dirs_exist_ok=True)
    r = sh('git -C %s config user.email bot@users.noreply.github.com && git -C %s config user.name kaggle-bot && '
           'git -C %s add pretrained && git -C %s commit -qm "Предобученные умения (Kaggle)" && git -C %s push -q origin HEAD:main' % ((d,) * 5))
    print("Результат отправлен в репозиторий." if r.returncode == 0 else "Не удалось отправить в репозиторий (результат есть в result.zip).")


if __name__ == "__main__":
    main()
