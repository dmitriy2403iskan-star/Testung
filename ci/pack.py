import json, glob, os
res = {}
for f in glob.glob("out/*.json"):
    try:
        r = json.load(open(f))
    except Exception:
        continue
    if r.get("skill", {}).get("w"):
        res.setdefault(r["goal"], []).append((f, r))
out = {"_info": "Предобученные умения (обучены в GitHub Actions, см. REPORT.md). Ключ = цель; gait = поза/походка, с которой обучено."}
lines = ["# Предобучение\n"]
for goal, lst in res.items():
    # лучший: ниже подвес, потом освоено, потом оценка
    lst.sort(key=lambda x: (x[1]["support"], -x[1]["mastered"], -x[1]["best"]))
    f, r = lst[0]
    out[goal] = r["skill"]
    lines.append(f"- {goal}: подвес в конце = {r['support']} (0 = без подвеса), освоено раз = {r['mastered']}, эпизодов = {r['eps']}, оценка = {r['best']:.2f} ({os.path.basename(f)})")
os.makedirs("pretrained", exist_ok=True)
json.dump(out, open("pretrained/skills.json", "w"), ensure_ascii=False)
open("pretrained/REPORT.md", "w", encoding="utf-8").write("\n".join(lines) + "\n")
