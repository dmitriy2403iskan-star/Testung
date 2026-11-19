#!/usr/bin/env python3
"""Долгое автообучение: sep-CMA-ES над весами нейросети (поправка к позе/походке), по этапам.
Задачи: stand -> walk. Внутри задачи подвес снимается по ступеням 3,2,1,0. Прогресс сохраняется
в DATA_DIR (на Railway - том /data), после перезапуска обучение продолжается с того же места.
Переменные: SECS (потолок времени, сек), WORKERS (процессов Godot), LAM (кандидатов на человека; их 8 с разными подходами, раз в 10 поколений обмен опытом),
DATA_DIR."""
import urllib.request, os, sys, time, json, datetime, shutil, subprocess, threading, queue, glob
import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import kaggle_run as K

DATA = os.path.abspath(os.environ.get("DATA_DIR", "state"))
SECS = int(os.environ.get("SECS", "43200"))
WORKERS = int(os.environ.get("WORKERS", os.cpu_count() or 2))
REMOTES = [u for u in os.environ.get("REMOTE_URLS", "").split(",") if u.strip()]   # адреса удалённых воркеров (второй хостинг)
REMOTE_SLOTS = int(os.environ.get("REMOTE_SLOTS", "2"))
LAM = int(os.environ.get("LAM", "15"))   # кандидатов на остров (+1 слот под текущую модель = 16 = 2 чанка)
N_MAIN = 8   # основные люди (их видно на видео)
N_ISL = 10   # + 2 помощника: берут лучшее знание, дорабатывают отдельно и возвращают, если вышло лучше
MIXES = [0.3, 0.2, 0.4, 0.25, 0.35, 0.15, 0.5, 0.3, 0.3, 0.3]
SIGMAS = [0.1, 0.05, 0.2, 0.08, 0.15, 0.1, 0.12, 0.3, 0.03, 0.05]
MIGRATE_EVERY = 10
REPEATS = int(os.environ.get("REPEATS", "3"))   # сколько раз прогнать всю цепочку повторно после первого прохода
N_IN, N_HID, N_OUT = 97, 16, 77   # 17 + 74 суставов + 6 командных входов (цель, высота, настроение)
N_W = N_IN * N_HID + N_HID + N_HID * N_OUT + N_OUT   # 2877
OLD_IN, OLD_W = 91, 2781   # прошлая версия сети: веса дополняются нулями для новых входов


def expand(v, fill=0.0):
    """Старые веса (91 вход) -> новые (97): новые входы получают нулевые связи, остальное без изменений."""
    v = np.asarray(v, dtype=float)
    if v.shape[0] != OLD_W:
        return v
    o1 = OLD_IN * N_HID
    B = np.full((N_HID, N_IN), fill)
    B[:, :OLD_IN] = v[:o1].reshape(N_HID, OLD_IN)
    return np.concatenate([B.reshape(-1), v[o1:]])

# need - сколько из 8 людей должны стоять/справляться без подвеса 10 поколений подряд; cap_h - потолок времени на задачу
TASKS = [
    {"name": "stand", "gait": "ci/gait_stand.json", "ep": 8.0, "push": 35.0, "inherit": None, "need": 4, "cap_h": None, "fast": True},
    {"name": "walk", "gait": "ci/gait_walk.json", "ep": 10.0, "push": 20.0, "inherit": "stand", "need": 1, "cap_h": None, "fast": True},
    {"name": "jump", "gait": "ci/gait_stand.json", "ep": 8.0, "push": 0.0, "inherit": "stand", "need": 1, "cap_h": None, "fast": True},
    {"name": "box", "gait": "ci/gait_stand.json", "ep": 10.0, "push": 0.0, "inherit": "stand", "need": 1, "cap_h": None},
    {"name": "carry", "gait": "ci/gait_walk.json", "ep": 12.0, "push": 0.0, "inherit": "box", "need": 1, "cap_h": None},   # сразу после коробки
    {"name": "goto", "gait": "ci/gait_walk.json", "ep": 8.0, "push": 0.0, "inherit": "walk", "need": 1, "cap_h": None, "fast": True},
    {"name": "getup", "gait": "ci/gait_stand.json", "ep": 10.0, "push": 0.0, "inherit": "stand", "need": 1, "cap_h": None},
    {"name": "run", "gait": "ci/gait_run.json", "ep": 8.0, "push": 0.0, "inherit": "walk", "need": 1, "cap_h": None, "fast": True},
    {"name": "leap", "gait": "ci/gait_stand.json", "ep": 8.0, "push": 0.0, "inherit": "jump", "need": 1, "cap_h": None},
    {"name": "crouch", "gait": "ci/gait_stand.json", "ep": 10.0, "push": 0.0, "inherit": "stand", "need": 1, "cap_h": None},
]
SUPPORTS = [3, 2, 1, 0]
LOG = []
STOP = threading.Event()   # /stop на странице статуса


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
            setattr(self, k, expand(d[k], 1.0 if k == "C" else 0.0))
        self.sigma, self.gen = d["sigma"], d["gen"]


class Pool:
    def __init__(self, godot, work, n):
        self.dirs, self.procs = [], []
        self.remote_done, self.remote_err = 0, ""
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

    def evaluate(self, goal, gait, support, gen, chunks, extra=None):
        """chunks: [(массив до 8 весов, доля нейросети)]. Возвращает список результатов по чанкам."""
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
                        "mix": chunks[ci][1], **(extra or {}), "cands": [np.round(x, 4).tolist() for x in chunks[ci][0]]}
                tmp = os.path.join(d, "task.tmp")
                json.dump(task, open(tmp, "w"))
                rp = os.path.join(d, "res.json")
                if os.path.exists(rp):
                    os.remove(rp)
                os.replace(tmp, os.path.join(d, "task.json"))
                t0 = time.time()
                while True:
                    time.sleep(0.1)
                    if os.path.exists(rp):
                        try:
                            r = json.load(open(rp))
                        except Exception:
                            continue
                        if r["gen"] == gen and r["chunk"] == ci:
                            res[ci] = {k: np.array(r[k], dtype=float) for k in ("scores", "ok", "fwd", "h", "fell", "up")}
                            break
                    if self.procs[wi].poll() is not None or time.time() - t0 > 900:
                        raise RuntimeError("рабочий процесс %d умер или завис" % wi)

        def remote(url):
            while True:
                try:
                    ci = q.get_nowait()
                except queue.Empty:
                    return
                task = {"gen": gen, "chunk": ci, "goal": goal, "gait": gait, "support": support,
                        "mix": chunks[ci][1], **(extra or {}), "cands": [np.round(x, 4).tolist() for x in chunks[ci][0]]}
                try:
                    req = urllib.request.Request(url.rstrip("/") + "/eval", data=json.dumps(task).encode(),
                                                 headers={"X-Token": os.environ.get("WTOKEN", "")})
                    r = json.loads(urllib.request.urlopen(req, timeout=600).read())
                    res[ci] = {k: np.array(r[k], dtype=float) for k in ("scores", "ok", "fwd", "h", "fell", "up")}
                    self.remote_done += 1
                except Exception as e:   # удалённый хост недоступен: чанк вернётся в очередь, посчитают свои
                    self.remote_err = str(e)[:80]
                    q.put(ci)
                    return

        for attempt in range(3):
            ths = [threading.Thread(target=run, args=(i,)) for i in range(len(self.dirs))]
            if attempt == 0:
                for url in REMOTES:
                    ths += [threading.Thread(target=remote, args=(url,)) for _ in range(REMOTE_SLOTS)]
            for t in ths:
                t.start()
            for t in ths:
                t.join()
            if all(r is not None for r in res):
                break
            for ci in range(len(chunks)):   # недосчитанное досчитывают свои процессы
                if res[ci] is None and ci not in list(q.queue):
                    q.put(ci)
        if any(r is None for r in res):
            raise RuntimeError("не все кандидаты посчитаны")
        return res

    def stop(self):
        for p in self.procs:
            p.kill()


def save_ckpt(work, goal, gait, support, isl, best_i, gen, mastered, ep=6.0, extra=None):
    """Чекпоинт: лучший остров как основное умение + все 8 подходов (для видео)."""
    g = json.load(open(os.path.join(work, gait)))["gait"]
    bi = isl[best_i]
    skill = {"w": [round(float(v), 4) for v in bi.cma.m], "eps": gen, "best": float(bi.ema), "gait": g}
    islands = [{"w": [round(float(v), 4) for v in x.cma.m], "mix": x.mix} for x in isl[:N_MAIN]]
    os.makedirs(os.path.join(work, "out"), exist_ok=True)
    r = {"goal": goal, "support": support, "mastered": mastered, "eps": gen, "best": float(bi.ema),
         "skill": skill, "islands": islands, "ep": ep, "extra": extra or {}}
    tmp = os.path.join(work, "out", goal + ".tmp")
    json.dump(r, open(tmp, "w"))
    os.replace(tmp, os.path.join(work, "out", goal + ".json"))


EVENTS = []   # события для модуля речи: {"t","i","kind","goal","n"}; модуль читает DATA/events.json и пишет DATA/speech.json


def event(i, kind, goal, n=0, info=""):
    EVENTS.append({"t": time.time(), "i": i, "kind": kind, "goal": goal, "n": n, "info": info})
    del EVENTS[:-60]
    try:
        json.dump(EVENTS, open(os.path.join(DATA, "events.json.tmp"), "w"), ensure_ascii=False)
        os.replace(os.path.join(DATA, "events.json.tmp"), os.path.join(DATA, "events.json"))
    except OSError:
        pass


def speech_section():
    """Отдельный раздел «Реплики»: события тела + то, что сказал модуль речи (DATA/speech.json: [{"i","text","t"}])."""
    sp = {}
    try:
        for r in json.load(open(os.path.join(DATA, "speech.json"))):
            sp[int(r["i"])] = r
    except Exception:
        pass
    lines = ["", "=== РЕПЛИКИ ==="]
    for e in EVENTS[-8:]:
        who = "№%d" % (e["i"] + 1) if e["i"] < N_MAIN else "Помощник"
        what = {"fell": "упал (%d-е поколение подряд лежит)" % e["n"], "stood": "встал и стоит!", "learned": "освоил задачу"}.get(e["kind"], e["kind"])
        r = sp.get(e["i"])
        said = "«%s»" % r["text"] if r and r.get("t", 0) >= e["t"] - 5 else "(модуль речи молчит)"
        lines.append("[%s] %s, %s: %s %s" % (hhmm(e["t"]), who, e["goal"], what, said))
    if not EVENTS:
        lines.append("пока событий нет")
    return "\n".join(lines) + "\n"


def scold(x, goal, support, rs):
    """Жёсткий разбор неудачников: текст в лог и статус (сеть текст не читает; настоящий сигнал - штраф в оценке)."""
    fell = float(np.concatenate([r["fell"] for r in rs]).mean())
    up = float(np.concatenate([r["up"] for r in rs]).mean())
    h = float(np.concatenate([r["h"] for r in rs]).mean())
    fwd = float(np.concatenate([r["fwd"] for r in rs]).mean())
    if x.ok_top > 0:
        if x.fail >= 1 and x.i < N_MAIN:
            event(x.i, "stood", goal, x.fail)
            say("РЕПЛИКА-СОБЫТИЕ: №%d снова справляется (%s)" % (x.i + 1, goal))
        x.fail = 0
        x.note = ""
        return
    x.fail += 1
    if x.i < N_MAIN and x.fail in (1, 5, 25) and fell > 0.5:
        event(x.i, "fell", goal, x.fail)
    if fell > 0.5:
        why = "падаешь на пол, %d%% твоих вариантов лежат" % int(fell * 100)
    elif up < 0.9:
        why = "кренишься, корпус заваливается (наклон %.2f)" % up
    elif h < 0.8 * 0.9:
        why = "приседаешь и проседаешь, не держишь рост"
    elif goal == "walk" and fwd < 1.0:
        why = "топчешься на месте, прошёл %.1f м" % fwd
    else:
        why = "не дотягиваешь до нормы"
    x.note = "НЕУДАЧА x%d: ты %s. Позор, давай лучше!" % (x.fail, why)
    if x.i < N_MAIN and (x.fail in (3, 10, 30) or x.fail % 50 == 0):
        say("№%d, ты безнадёжно слаб: %s (%d поколений подряд). Соберись и делай лучше!" % (x.i + 1, why, x.fail))


class Island:
    """Один «человек»: свой CMA-ES, своя доля нейросети поверх позы, свой стартовый шаг."""
    def __init__(self, i, mean=None):
        self.i = i
        self.mix = MIXES[i]
        self.cma = Cma(N_W, LAM, SIGMAS[i], mean=mean, seed=100 + i)
        self.ema = -1e9
        self.ok_top = 0.0
        self.ok_streak = 0
        self.master = 0
        self.last = 0.0
        self.mean_score = 0.0
        self.fail = 0
        self.note = ""

    def dump(self):
        return {"cma": self.cma.dump(), "ema": self.ema, "master": self.master, "ok_streak": self.ok_streak, "mix": self.mix}

    def load(self, d):
        self.cma.load(d["cma"])
        self.ema, self.master, self.ok_streak = d["ema"], d["master"], d["ok_streak"]
        self.mix = d.get("mix", self.mix)


def hhmm(t):
    try:
        from zoneinfo import ZoneInfo
        return datetime.datetime.fromtimestamp(t, ZoneInfo("Europe/Kiev")).strftime("%H:%M")
    except Exception:   # нет базы часовых поясов: киевское зимнее время UTC+2
        return datetime.datetime.utcfromtimestamp(t + 2 * 3600).strftime("%H:%M")


def old_status(st, goal, support, isl, elapsed):
    """Формат как раньше: 'Идёт N мин из M' и строка на каждого из 8 людей (подходов)."""
    now = time.time()
    goal = goal + (" (%d)" % st["cycle"] if st.get("cycle", 0) else "")
    lines = ["Запуск в %s, сейчас %s: %s - %s = %d:%02d (потолок %d ч, по Киеву)" % (
                 hhmm(st["started"]), hhmm(now), hhmm(now), hhmm(st["started"]), elapsed // 3600, elapsed % 3600 // 60, SECS // 3600),
             "Задача %d из %d: %s, подвес %d" % (st["task"] + 1, len(TASKS), goal, support)]
    for x in isl:
        lines.append(("№%d" % (x.i + 1) if x.i < N_MAIN else "Помощник %s" % "АБ"[x.i - N_MAIN]) + ": T=%ds %s eps=%d best=%.2f sup=%d sigma=%.3f ok=%d mastered=%d (доля сети %.2f)" % (
            elapsed, goal, st["gen"], x.last, support, x.cma.sigma, int(x.ok_top * 100), x.master, x.mix) + ("  <- " + x.note if x.note else ""))
    return "\n".join(lines)


def migrate(isl, say_):
    """Обмен опытом. Основные (8): двое худших пересаживаются к лучшему, остальные подтягиваются на 10%.
    Помощники (2): возвращают найденное, если оно лучше, и снова берут лучшее знание для доработки."""
    mains = isl[:N_MAIN]
    helpers = isl[N_MAIN:]
    order = sorted(range(N_MAIN), key=lambda k: -mains[k].ema)
    best = mains[order[0]]
    # 1) помощники возвращают улучшение: лучший помощник заменяет двух худших основных
    hb = max(helpers, key=lambda h: h.ema)
    if hb.ema > best.ema + 0.05:
        for k in order[-2:]:
            mains[k].cma.m = hb.cma.m.copy()
            mains[k].mix = hb.mix   # веса работают только вместе со своей долей сети
            mains[k].cma.sigma = max(hb.cma.sigma, 0.05)
            mains[k].cma.C[:] = 1.0
            mains[k].ema = hb.ema - 0.5
        say_("Помощник %s принёс улучшение (оценка %.2f против %.2f): его знание передано двум слабейшим" % ("А" if hb is helpers[0] else "Б", hb.ema, best.ema))
        order = sorted(range(N_MAIN), key=lambda k: -mains[k].ema)
        best = mains[order[0]]
    # 2) обмен опытом основных
    for k in order[-2:]:
        x = mains[k]
        if x.ema >= best.ema - 0.4:
            continue   # только что получили знание помощника
        x.cma.m = best.cma.m + x.cma.rng.normal(0, 0.01, N_W)
        x.mix = best.mix
        x.cma.sigma = max(best.cma.sigma, 0.05)
        x.cma.C[:] = 1.0
        x.cma.ps[:] = 0
        x.cma.pc[:] = 0
        x.ema = best.ema - 1.0
    for k in order[1:-2]:
        mains[k].cma.m = 0.9 * mains[k].cma.m + 0.1 * best.cma.m
        mains[k].mix = 0.9 * mains[k].mix + 0.1 * best.mix
    # 3) помощники заново питаются знаниями: А берёт лучшего, Б - среднее трёх лучших
    seeds = [best.cma.m.copy(), np.mean([mains[k].cma.m for k in order[:3]], axis=0)]
    mixes = [best.mix, float(np.mean([mains[k].mix for k in order[:3]]))]
    for h, m, mx in zip(helpers, seeds, mixes):
        h.cma.m = m
        h.mix = mx
        h.cma.sigma = SIGMAS[h.i]
        h.cma.C[:] = 1.0
        h.cma.ps[:] = 0
        h.cma.pc[:] = 0
        h.ema = -1e9
    say_("Обмен опытом: №%d лучший; помощники получили свежие знания" % (best.i + 1))


def enter_task(st, isl, ti):
    """Входим в задачу: если есть сохранённое умение этой задачи, продолжаем с него, иначе берём лучшее из родительской."""
    t = TASKS[ti]
    sk = st["skills"].get(t["name"])
    if sk:
        for x, m in zip(isl, sk["means"]):
            x.cma = Cma(N_W, LAM, SIGMAS[x.i], mean=expand(m), seed=300 + x.i + ti)
        st["sup"] = sk["sup"]
        say("Задача «%s»: продолжаю с сохранённого умения, подвес %d" % (t["name"], SUPPORTS[st["sup"]]))
    else:
        par = st["skills"].get(t["inherit"]) if t["inherit"] else None
        for x in isl:
            m = expand(par["best"]) if par else None
            x.cma = Cma(N_W, LAM, SIGMAS[x.i], mean=m, seed=400 + x.i + ti)
        st["sup"] = 0
        say("Задача «%s»: начинаю%s" % (t["name"], " с умения «%s»" % t["inherit"] if par else " с нуля"))
    for h in isl[N_MAIN:]:   # помощники начинают с умения первого основного
        h.cma = Cma(N_W, LAM, SIGMAS[h.i], mean=isl[0].cma.m.copy(), seed=600 + h.i + ti)
        h.mix = isl[0].mix
    for x in isl:
        x.ema, x.master, x.ok_streak = -1e9, 0, 0
    st["task"] = ti
    st["task_t0"] = time.time()


def main(force=False):
    godot = K.get_godot()
    K.WORK = work = os.path.abspath(os.environ.get("WORKDIR", "work"))
    if os.path.exists(work):
        shutil.rmtree(work)
    shutil.copytree(K.REPO, work, ignore=shutil.ignore_patterns(".git", "web", "logs"))
    shutil.copy(os.path.join(work, "ci", "cma_worker.gd"), os.path.join(work, "cma_worker.gd"))
    pg = os.path.join(work, "project.godot")
    s = open(pg, encoding="utf-8").read().replace("[autoload]", '[autoload]\nTrainer="*res://cma_worker.gd"', 1)
    open(pg, "w", encoding="utf-8").write(s)
    subprocess.run('"%s" --headless --import' % godot, shell=True, cwd=work, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    say("Импорт проекта...")
    os.makedirs(DATA, exist_ok=True)
    os.makedirs(K.RES, exist_ok=True)
    flag = os.path.join(DATA, "stopped")
    if os.path.exists(flag) and not force:
        open(os.path.join(K.RES, "status.txt"), "w", encoding="utf-8").write(
            "Обучение остановлено ранее командой /stop. Чтобы продолжить, введи /start.\nВеса сохранены: %s\n" % os.path.join(DATA, "weights"))
        say("Обучение остановлено ранее (/stop). Жду команду /start.")
        return
    if os.path.exists(flag):
        os.remove(flag)
    stf = os.path.join(DATA, "state3.json")
    old = os.path.join(DATA, "state2.json")
    isl = [Island(i) for i in range(N_ISL)]
    if os.path.exists(stf):
        st = json.load(open(stf))
        for x, d in zip(isl, st["isl"]):
            x.load(d)
        say("Продолжаю с сохранения: задача %d, подвес %d, поколение %d" % (st["task"] + 1, SUPPORTS[st["sup"]], st["gen"]))
    elif os.path.exists(old):
        # переезд с прошлой версии: там шла ходьба. Её умение сохраняем, а обучение возвращаем на строгую стойку
        o = json.load(open(old))
        for x, d in zip(isl, o["isl"]):
            x.load(d)
        best = max(isl, key=lambda x: x.ema)
        st = {"task": 0, "sup": 2, "gen": o["gen"], "started": o.get("started", time.time()), "isl": o["isl"],
              "task_t0": time.time(),
              "skills": {"walk": {"means": [x.cma.m.tolist() for x in isl], "best": best.cma.m.tolist(), "sup": o["sup"]}}}
        say("Переезд: умение ходьбы сохранено, возвращаюсь к строгой проверке стойки (подвес %d), веса не сбрасываю" % SUPPORTS[st["sup"]])
        for x in isl:   # те же веса, но поиск заново: старая ковариация настроена под другую цель
            x.cma = Cma(N_W, LAM, SIGMAS[x.i], mean=x.cma.m.copy(), seed=500 + x.i)
            x.ema, x.master, x.ok_streak = -1e9, 0, 0
    else:
        st = {"task": int(os.environ.get("START_TASK", "0")), "sup": int(os.environ.get("START_SUP", "0")), "gen": 0, "started": time.time(), "isl": None, "task_t0": time.time(), "skills": {}, "v": 5}
    if st.get("v", 0) < 5:
        # новая версия (учёт торса, помощники): сохраняем все знания в архив и возвращаемся на строгую стойку
        ts = time.strftime("%Y%m%d_%H%M", time.gmtime())
        arc = os.path.join(DATA, "archive", ts)
        os.makedirs(arc, exist_ok=True)
        for f in [stf] + glob.glob(os.path.join(DATA, "weights", "*.json")):
            if os.path.exists(f):
                shutil.copy(f, arc)
        say("Знания сохранены в архив: %s" % arc)
        if st["isl"] is not None and st["task"] < len(TASKS):
            cur = TASKS[st["task"]]["name"]
            bm = max(isl[:N_MAIN], key=lambda x: x.ema)
            st["skills"][cur] = {"means": [x.cma.m.tolist() for x in isl[:N_MAIN]], "sup": st["sup"], "best": bm.cma.m.tolist()}
        for g in ("jump", "box"):   # их учили с подвесом, который не давал оторваться от земли
            st["skills"].pop(g, None)
        st["v"] = 5
        st["started"] = time.time()
        st["cycle"] = 0
        enter_task(st, isl, 0)
        say("Новый запуск: строгая стойка с учётом торса, умения ног сохранены")
    elif len(st["isl"] or []) < N_ISL:
        for h in isl[N_MAIN:]:
            h.cma = Cma(N_W, LAM, SIGMAS[h.i], mean=isl[0].cma.m.copy(), seed=700 + h.i)
    if not st.get("mixfix"):   # разовая починка: доля сети 0.3+ на стойке не работает, все берут долю лучшего стоящего
        mains = isl[:N_MAIN]
        bm = max(mains, key=lambda x: x.ema)
        for x in isl:
            if x.mix > bm.mix + 0.02 and x.ema < bm.ema - 1.0:
                x.cma.m = bm.cma.m + x.cma.rng.normal(0, 0.01, N_W)
                x.mix = bm.mix
                x.cma.sigma = 0.06
                x.cma.C[:] = 1.0
                x.cma.ps[:] = 0
                x.cma.pc[:] = 0
                x.ema = bm.ema - 1.0
        st["mixfix"] = 1
        say("Починка: застрявшие люди получили веса и долю сети лучшего (№%d, доля %.2f)" % (bm.i + 1, bm.mix))
    pool = Pool(godot, work, WORKERS)
    say("Запущено процессов: %d, удалённых хостов: %d (по %d процесса), людей-подходов: %d по %d кандидатов, потолок %d ч" % (WORKERS, len(REMOTES), REMOTE_SLOTS, N_ISL, LAM + 1, SECS // 3600))
    last_save = 0
    rng = np.random.default_rng(7)
    try:
        while st["task"] < len(TASKS) and time.time() - st["started"] < SECS and not STOP.is_set():
            T = TASKS[st["task"]]
            goal, gait = T["name"], T["gait"]
            support = SUPPORTS[st["sup"]]
            t0 = time.time()
            chunks, owner = [], []
            for x in isl:
                X = x.cma.ask()
                allx = np.vstack([X, x.cma.m[None, :]])    # LAM кандидатов + текущая средняя модель
                for c in range(0, len(allx), 8):
                    chunks.append((allx[c:c + 8], x.mix))
                    owner.append(x.i)
            extra = {"ep": T["ep"] * (0.5 if T.get("fast") and support >= 2 else 1.0)}   # на сильном подвесе эпизоды вдвое короче: быстрее
            if goal in ("goto", "carry"):   # цель на земле: направление и расстояние новые каждое поколение
                dd = rng.uniform(2.5, 4.0) if goal == "goto" else rng.uniform(2.5, 3.2)
                aa = np.deg2rad(rng.uniform(-60, 60) if goal == "goto" else rng.uniform(-40, 40))
                extra["tgt"] = [float(dd * np.sin(aa)), float(dd * np.cos(aa))]
            if goal == "getup":
                extra["lie"] = int(rng.integers(1, 3))
            if T["push"] > 0:   # толчок на 4-й секунде; направление новое каждое поколение, одно для всех в поколении
                ang = rng.uniform(0, 2 * np.pi)
                extra.update(push=[float(T["push"] * np.cos(ang)), float(T["push"] * np.sin(ang))], push_t=4.0)
            res = pool.evaluate(goal, gait, support, st["gen"], chunks, extra)
            st["gen"] += 1
            n_ok_isl = 0
            for x in isl:
                rs = [r for r, o in zip(res, owner) if o == x.i]
                sc = np.nan_to_num(np.concatenate([r["scores"] for r in rs]), nan=-100.0, posinf=-100.0, neginf=-100.0)
                ok = np.concatenate([r["ok"] for r in rs])
                x.cma.tell(sc[:LAM])
                x.mean_score = float(sc[LAM])
                x.last = float(sc.max())
                top = np.argsort(-sc)[:8]
                x.ok_top = float(ok[top].mean())
                x.ema = x.last if x.ema < -1e8 else 0.8 * x.ema + 0.2 * x.last
                x.ok_streak = x.ok_streak + 1 if x.ok_top >= 0.75 else 0
                x.master = x.master + 1 if (support == 0 and ok[LAM] > 0.5) else 0
                if x.i < N_MAIN:
                    n_ok_isl += x.ok_streak >= 2
                scold(x, goal, support, rs)
            # застрявшие (10+ поколений подряд ни один вариант не справился), пока другие справляются: пересаживаем их к успешному
            okers = [y for y in isl[:N_MAIN] if y.ok_top > 0]
            if okers:
                donor = max(okers, key=lambda y: y.ema)
                for x in isl[:N_MAIN]:
                    if x.fail >= 10 and x is not donor:
                        x.cma.m = donor.cma.m + x.cma.rng.normal(0, 0.01, N_W)
                        x.mix = donor.mix   # раньше доля сети оставалась своей (больше), и пересаженный сразу падал
                        x.cma.sigma = 0.06
                        x.cma.C[:] = 1.0
                        x.cma.ps[:] = 0
                        x.cma.pc[:] = 0
                        x.fail = 0
                        x.ema = donor.ema - 1.0
            st["stall"] = st.get("stall", 0) + 1 if 2 <= n_ok_isl < N_MAIN // 2 else 0
            best_i = max(range(N_MAIN), key=lambda k: isl[k].ema)
            n_master = sum(x.master >= 10 for x in isl[:N_MAIN])
            top_master = max(x.master for x in isl[:N_MAIN])
            elapsed = time.time() - st["started"]
            LOG.append("Поколение %d | %s | подвес %d | лучший остров №%d (%.2f) | прошли ступень: %d из %d | освоили: %d (нужно %d) | %.0f с" %
                       (st["gen"], goal, support, best_i + 1, isl[best_i].ema, n_ok_isl, N_MAIN, n_master, T["need"], time.time() - t0))
            save_ckpt(work, goal, gait, support, isl, best_i, st["gen"], top_master, T["ep"], extra)
            if st["gen"] % MIGRATE_EVERY == 0:
                migrate(isl, say)
            in_task_h = (time.time() - st["task_t0"]) / 3600
            done_task = n_master >= T["need"]
            timeout = T["cap_h"] is not None and in_task_h > T["cap_h"]
            if done_task or timeout:
                st["skills"][goal] = {"means": [x.cma.m.tolist() for x in isl], "sup": st["sup"],
                                      "best": isl[best_i].cma.m.tolist()}
                say(">>> Задача «%s» %s. Идём дальше." % (goal, "освоена без подвеса" if done_task else "по времени (%.1f ч), берём лучшее" % in_task_h))
                if st["task"] + 1 < len(TASKS):
                    enter_task(st, isl, st["task"] + 1)
                elif st.get("cycle", 0) < REPEATS:   # вся цепочка пройдена: повторяем её ещё раз с накопленными умениями
                    st["cycle"] = st.get("cycle", 0) + 1
                    say(">>> Все задачи пройдены. Повтор %d из %d: " % (st["cycle"], REPEATS) + ", ".join("%s (%d)" % (t["name"], st["cycle"]) for t in TASKS))
                    enter_task(st, isl, 0)
                else:
                    st["task"] += 1   # все повторы пройдены
            elif (n_ok_isl >= N_MAIN // 2 or st["stall"] >= 10) and st["sup"] < len(SUPPORTS) - 1:
                st["stall"] = 0
                st["sup"] += 1
                say(">>> Подвес снижен до %d (прошли ступень %d из %d)" % (SUPPORTS[st["sup"]], n_ok_isl, N_MAIN))
                for x in isl:
                    x.ok_streak = 0
                    x.cma.sigma = min(max(x.cma.sigma * 1.5, 0.05), 0.3)
            st["isl"] = [x.dump() for x in isl]
            if time.time() - last_save > 60 and st["task"] < len(TASKS):
                last_save = time.time()
                goal2, gait2 = TASKS[st["task"]]["name"], TASKS[st["task"]]["gait"]
                st["skills"][goal2] = {"means": [x.cma.m.tolist() for x in isl], "sup": st["sup"],
                                       "best": isl[best_i].cma.m.tolist()}
                json.dump(st, open(stf + ".tmp", "w"))
                os.replace(stf + ".tmp", stf)
                text = old_status(st, goal2, SUPPORTS[st["sup"]], isl, elapsed)
                if REMOTES:
                    text += "\nВторой сервер: посчитал %d чанков, поколение %.0f с%s" % (
                        pool.remote_done, time.time() - t0, (", ошибка: " + pool.remote_err) if pool.remote_err else "")
                print(text, flush=True)
                open(os.path.join(K.RES, "status.txt"), "w", encoding="utf-8").write(text + speech_section() + "\nЗаписать видео: /rec\n")
                os.makedirs(os.path.join(DATA, "weights"), exist_ok=True)
                for f in glob.glob(os.path.join(work, "out", "*.json")):
                    shutil.copy(f, os.path.join(DATA, "weights", os.path.basename(f)))
                if os.path.exists(os.path.join(work, "out", goal2 + ".json")):
                    shutil.copy(os.path.join(work, "out", goal2 + ".json"), K.RES)
        json.dump(st, open(stf, "w"))
    finally:
        pool.stop()
    json.dump(st, open(stf, "w"))
    wdir = os.path.join(DATA, "weights")
    os.makedirs(wdir, exist_ok=True)
    for f in glob.glob(os.path.join(work, "out", "*.json")):
        shutil.copy(f, os.path.join(wdir, os.path.basename(f)))
    import zipfile
    with zipfile.ZipFile("result.zip", "w", zipfile.ZIP_DEFLATED) as z:
        for f in glob.glob(os.path.join(wdir, "*.json")) + [stf]:
            z.write(f, os.path.basename(f))
    files = ["%s (%.1f МБ)" % (os.path.basename(f), os.path.getsize(f) / 1e6) for f in sorted(glob.glob(os.path.join(wdir, "*.json")))]
    if STOP.is_set():
        open(flag, "w").write("stopped")
    head = ("ОБУЧЕНИЕ ОСТАНОВЛЕНО командой /stop" if STOP.is_set() else
            ("ВСЕ ЗАДАЧИ И ВСЕ %d ПОВТОРА ПРОЙДЕНЫ" % REPEATS if st["task"] >= len(TASKS) else "Время вышло (потолок %d ч)" % (SECS // 3600)))
    text = ("%s в %s (по Киеву).\nДошло до: задача %s, поколение %d, подвес %d.\n\nСохранённые веса:\n"
            "  - на диске сервера (не пропадут при перезапуске): %s\n  - файлы: %s\n  - всё одним архивом: /result.zip (открой на этом же адресе)\n"
            "  - состояние обучения (чтобы продолжить): %s\n\nЧтобы продолжить, введи /start. Чтобы не тратить кредиты, останови сервис в Railway.\n" % (
                head, hhmm(time.time()), TASKS[min(st["task"], len(TASKS) - 1)]["name"], st["gen"], SUPPORTS[st["sup"]], wdir,
                ", ".join(files) or "нет", stf))
    open(os.path.join(K.RES, "status.txt"), "w", encoding="utf-8").write(text)
    print(text, flush=True)
    say("ГОТОВО")


if __name__ == "__main__":
    main()
