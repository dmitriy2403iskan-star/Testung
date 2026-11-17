import json, glob, sys
goal = sys.argv[1]
best = None
for f in glob.glob("ckpt/ckpt_*.json"):
    try:
        r = json.load(open(f))
    except Exception:
        continue
    if r.get("goal") != goal or not r.get("skill", {}).get("w"):
        continue
    key = (r["support"], -r["mastered"], -r["best"])
    if best is None or key < best[0]:
        best = (key, f)
print(best[1] if best else "")
