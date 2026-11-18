#!/usr/bin/env python3
"""Долгое автообучение: sep-CMA-ES над весами нейросети (поправка к позе/походке), по этапам.
Задачи: stand -> walk. Внутри задачи подвес снимается по ступеням 3,2,1,0. Прогресс сохраняется
в DATA_DIR (на Railway - том /data), после перезапуска обучение продолжается с того же места.
Переменные: SECS (потолок времени, сек), WORKERS (процессов Godot), POP (кандидатов за поколение),
DATA_DIR, SIGMA0."""
import os, sys, time, json, shutil, subprocess, threading, queue, glob
import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import kaggle_run as K

DATA = os.path.abspath(os.environ.get("DATA_DIR", "state"))
SECS = int(os.environ.get("SECS", "43200"))
WORKERS = int(os.environ.get("WORKERS", os.cpu_count() or 2))
POP = int(os.environ.get("POP", "48"))
SIGMA0 = float(os.environ.get("SIGMA0", "0.1"))
N_IN, N_HID, N_OUT = 91, 16, 77
N_W = N_IN * N_HID + N_HID + N_HID * N_OUT + N_OUT   # 2781
TASKS = [("stand", "ci/gait_stand.json"), ("walk", "ci/gait_walk.json")]
SUPPORTS = [3, 2, 1, 0]
LOG = []


def say(*a):
    s = " ".join(str(x) for x in a)
    print(s, flush=True)
    LOG.append(s)


class Cma:
    """sep-CMA-ES (диагональная ковариация), максимизирует оценку."""
    def __init__(self, n, lam, sigma, mean=None, seed=1):
        self.n, self.lam = n, lam
        self.rng = np.random.default_rng(seed)
        self.m = mean.copy() if mean is not None else self.rng.normal(0, 0.03, n)
        self.sigma = sigma
        self.C = np.ones(n)
        self.ps = np.zeros(n)
        self.pc = np.zeros(n)
        mu = lam // 2
        w = np.log(mu + 0.5) - np.log(np.arange(1, mu + 1))
        self.w = w / w.sum()
        self.mu = mu
        self.mueff = 1.0 / np.sum(self.w ** 2)
        me = self.mueff
        self.cs = (me + 2) / (n + me + 5)
        self.damps = 1 + 2 * max(0.0, np.sqrt((me - 1) / (n + 1)) - 1) + self.cs
        self.cc = (4 + me / n) / (n + 4 + 2 * me / n)
        c1 = 2 / ((n + 1.3) ** 2 + me)
        cmu = min(1 - c1, 2 * (me - 2 + 1 / me) / ((n + 2) ** 2 + me))
        k = (n + 2) / 3.0
        self.c1, self.cmu = min(c1 * k, 0.5), min(cmu * k, 0.5)
        self.chiN = np.sqrt(n) * (1 - 1 / (4 * n) + 1 / (21 * n * n))
        self.gen = 0

    def ask(self):
        self.z = self.rng.normal(size=(self.lam, self.n))
        self.y = self.z * np.sqrt(self.C)
        return self.m + self.sigma * self.y

    def tell(self, f):
        idx = np.argsort(-np.asarray(f))[: self.mu]
        yw = self.w @ self.y[idx]
        zw = self.w @ self.z[idx]
        self.m = self.m + self.sigma * yw
        self.ps = (1 - self.cs) * self.ps + np.sqrt(self.cs * (2 - self.cs) * self.mueff) * zw
        self.gen += 1
        hs = np.linalg.norm(self.ps) / np.sqrt(1 - (1 - self.cs) ** (2 * self.gen)) / self.chiN < 1.4 + 2 / (self.n + 1)
        self.pc = (1 - self.cc) * self.pc + (hs * np.sqrt(self.cc * (2 - self.cc) * self.mueff)) * yw
        self.C = ((1 - self.c1 - self.cmu) * self.C + self.c1 * self.pc ** 2
                  + self.cmu * (self.w @ (self.y[idx] ** 2)))
        self.C = np.clip(self.C, 1e-4, 1e4)
        self.sigma *= float(np.exp(self.cs / self.damps * (np.linalg.norm(self.ps) / self.chiN - 1)))
        self.sigma = float(np.clip(self.sigma, 0.003, 0.5))

    def dump(self):
        return {k: (getattr(self, k).tolist() if isinstance(getattr(self, k), np.ndarray) else getattr(self, k))
                for k in ("m", "sigma", "C", "ps", "pc", "gen")}

    def load(self, d):
        for k in ("m", "C", "ps", "pc"):
            setattr(self, k, np.array(d[k]))
        self.sigma, self.gen = d["sigma"], d["gen"]


class Pool:
    def __init__(self, godot, work, n):
        self.dirs, self.procs = [], []
        for i in range(n):
            d = os.path.join(work, "w%d" % i)
            os.makedirs(d, exist_ok=True)
            for fn in ("task.json", "res.json"):
                if os.path.exists(os.path.join(d, fn)):
                    os.remove(os.path.join(d, fn))
            xdg = os.path.join(work, "xdg_w%d" % i)
            os.makedirs(xdg, exist_ok=True)
            env = dict(os.environ, NO_LLM="1", XDG_DATA_HOME=xdg, XDG_CONFIG_HOME=xdg + "/cfg", WDIR=d)
            lg = open(os.path.join(work, "w%d.log" % i), "w")
            self.procs.append(subprocess.Popen([godot, "--headless", "--fixed-fps", "240"], cwd=work, env=env,
                                               stdout=lg, stderr=subprocess.STDOUT))
            self.dirs.append(d)

    def evaluate(self, goal, gait, support, gen, X):
        chunks = [X[i:i + 8] for i in range(0, len(X), 8)]
        res = [None] * len(chunks)
        q = queue.Queue()
        for ci in range(len(chunks)):
            q.put(ci)

        def run(wi):
            d = self.dirs[wi]
            while True:
                try:
                    ci = q.get_nowait()
                except queue.Empty:
                    return
                task = {"gen": gen, "chunk": ci, "goal": goal, "gait": gait, "support": support,
                        "cands": [np.round(x, 4).tolist() for x in chunks[ci]]}
                tmp = os.path.join(d, "task.tmp")
                json.dump(task, open(tmp, "w"))
                rp = os.path.join(d, "res.json")
                if os.path.exists(rp):
                    os.remove(rp)
                os.replace(tmp, os.path.join(d, "task.json"))
                t0 = time.time()
                while True:
                    time.sleep(0.5)
                    if os.path.exists(rp):
                        try:
                            r = json.load(open(rp))
                        except Exception:
                            continue
                        if r["gen"] == gen and r["chunk"] == ci:
                            res[ci] = r
                            break
                    if self.procs[wi].poll() is not None or time.time() - t0 > 900:
                        raise RuntimeError("рабочий процесс %d умер или завис" % wi)

        ths = [threading.Thread(target=run, args=(i,)) for i in range(len(self.dirs))]
        for t in ths:
            t.start()
        for t in ths:
            t.join()
        if any(r is None for r in res):
            raise RuntimeError("не все кандидаты посчитаны")
        out = {k: [] for k in ("scores", "ok", "fwd", "h")}
        for r in res:
            for k in out:
                out[k] += r[k]
        return {k: np.array(v, dtype=float) for k, v in out.items()}

    def stop(self):
        for p in self.procs:
            p.kill()


def save_ckpt(work, goal, gait, support, m, score, gen, mastered):
    skill = {"w": [round(float(v), 4) for v in m], "eps": gen, "best": float(score)}
    skill["gait"] = json.load(open(os.path.join(work, gait)))["gait"]
    os.makedirs(os.path.join(work, "out"), exist_ok=True)
    r = {"goal": goal, "support": support, "mastered": mastered, "eps": gen, "best": float(score), "skill": skill}
    tmp = os.path.join(work, "out", goal + ".tmp")
    json.dump(r, open(tmp, "w"))
    os.replace(tmp, os.path.join(work, "out", goal + ".json"))


def main():
    godot = K.get_godot()
    K.WORK = work = os.path.abspath(os.environ.get("WORKDIR", "work"))
    if os.path.exists(work):
        shutil.rmtree(work)
    shutil.copytree(K.REPO, work, ignore=shutil.ignore_patterns(".git", "web", "logs"))
    shutil.copy(os.path.join(work, "ci", "cma_worker.gd"), os.path.join(work, "cma_worker.gd"))
    # railway_main ждёт K.WORK/ci/record.gd и K.WORK/out/<имя>.json
    pg = os.path.join(work, "project.godot")
    s = open(pg, encoding="utf-8").read().replace("[autoload]", '[autoload]\nTrainer="*res://cma_worker.gd"', 1)
    open(pg, "w", encoding="utf-8").write(s)
    sh = lambda c: subprocess.run(c, shell=True, cwd=work, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    say("Импорт проекта...")
    sh('"%s" --headless --import' % godot)
    os.makedirs(DATA, exist_ok=True)
    os.makedirs(K.RES, exist_ok=True)
    stf = os.path.join(DATA, "state.json")
    st = json.load(open(stf)) if os.path.exists(stf) else {"task": 0, "sup": 0, "gen": 0, "ok_streak": 0, "master": 0,
                                                            "elapsed": 0.0, "best": -1e9, "cma": None, "history": []}
    cma = Cma(N_W, POP, SIGMA0)
    if st["cma"]:
        cma.load(st["cma"])
        say("Продолжаю с сохранения: задача %d, подвес %d, поколение %d" % (st["task"], SUPPORTS[st["sup"]], st["gen"]))
    pool = Pool(godot, work, WORKERS)
    say("Запущено процессов: %d, популяция %d, потолок %d мин" % (WORKERS, POP, SECS // 60))
    t_run = time.time()
    last_save = 0
    try:
        while st["task"] < len(TASKS) and st["elapsed"] + time.time() - t_run < SECS:
            goal, gait = TASKS[st["task"]]
            support = SUPPORTS[st["sup"]]
            X = cma.ask()
            allx = np.vstack([cma.m[None, :], X])    # нулевой кандидат - текущая средняя модель
            t0 = time.time()
            r = pool.evaluate(goal, gait, support, st["gen"], allx)
            sc = np.nan_to_num(r["scores"], nan=-100.0, posinf=-100.0, neginf=-100.0)
            cma.tell(sc[1:])
            st["gen"] += 1
            top = np.argsort(-sc)[:8]
            ok_top = float(r["ok"][top].mean())
            mean_ok = bool(r["ok"][0])
            st["best"] = float(sc.max())
            # ступень подвеса пройдена, когда большинство лучших справляются несколько поколений подряд
            st["ok_streak"] = st["ok_streak"] + 1 if ok_top >= 0.75 else 0
            st["master"] = st["master"] + 1 if (support == 0 and mean_ok) else 0
            if st["gen"] % 5 == 0 or st["master"] > 0:
                st["history"].append([int(st["gen"]), goal, support, round(float(sc.max()), 2), round(ok_top, 2)])
            elapsed = st["elapsed"] + time.time() - t_run
            line = ("Поколение %d | %s | подвес %d | лучший %.2f, средний %.2f, модель-среднее %.2f | справились: %d%% лучших | "
                    "модель стоит подряд: %d/10 | шаг поиска %.3f | %.0f с на поколение" %
                    (st["gen"], goal, support, sc.max(), sc.mean(), sc[0], ok_top * 100, st["master"], cma.sigma, time.time() - t0))
            say(line)
            save_ckpt(work, goal, gait, support, cma.m, sc[0], st["gen"], st["master"])
            if st["master"] >= 10:
                say(">>> Задача «%s» освоена без подвеса. Идём дальше." % goal)
                st.update(task=st["task"] + 1, sup=0, ok_streak=0, master=0)
                if st["task"] < len(TASKS):
                    st["sup"] = 0
                    cma.sigma = max(cma.sigma, 0.1)
            elif st["ok_streak"] >= 3 and st["sup"] < len(SUPPORTS) - 1:
                st["sup"] += 1
                st["ok_streak"] = 0
                cma.sigma = min(max(cma.sigma * 1.5, 0.05), 0.3)
                say(">>> Подвес снижен до %d" % SUPPORTS[st["sup"]])
            st["elapsed"] = elapsed
            st["cma"] = cma.dump()
            if time.time() - last_save > 120:
                last_save = time.time()
                json.dump(st, open(stf + ".tmp", "w"))
                os.replace(stf + ".tmp", stf)
                text = ("Задача %d из %d: %s | подвес %d (0 = без подвеса)\nПоколение %d, идёт %.1f ч из %.0f ч\n%s\n\n"
                        "Последние строки:\n%s\n\nЗаписать видео: /rec\n" %
                        (st["task"] + 1, len(TASKS), goal, support, st["gen"], elapsed / 3600, SECS / 3600,
                         "Лучший результат поколения: %.2f" % st["best"], "\n".join(LOG[-6:])))
                open(os.path.join(K.RES, "status.txt"), "w", encoding="utf-8").write(text)
                shutil.copy(os.path.join(work, "out", goal + ".json"), K.RES)
        json.dump(st, open(stf, "w"))
    finally:
        pool.stop()
    done = st["task"] >= len(TASKS)
    open(os.path.join(K.RES, "status.txt"), "w", encoding="utf-8").write(
        ("ГОТОВО: все задачи освоены\n" if done else "Время вышло\n") + "\n".join(LOG[-10:]) + "\nСкачать: /result.zip\n")
    import zipfile
    with zipfile.ZipFile("result.zip", "w", zipfile.ZIP_DEFLATED) as z:
        for f in glob.glob(os.path.join(work, "out", "*.json")) + [stf]:
            z.write(f, os.path.basename(f))
    say("ГОТОВО")


if __name__ == "__main__":
    main()
