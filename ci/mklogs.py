import subprocess
def sh(*a): return subprocess.run(a, capture_output=True, text=True).stdout
commits = sh('git', 'log', '--reverse', '--format=%H %cI', 'origin/train-status').strip().split('\n')
out = ["# История серверного обучения\n", "Каждая запись = состояние обучения на момент (снимок раз в ~4 минуты). Время в UTC (Киев = UTC+2).\n"]
for c in commits:
    if not c.strip():
        continue
    h, t = c.split(' ')
    s = sh('git', 'show', f'{h}:STATUS.md').strip()
    if s:
        out.append(f"## {t[:19].replace('T',' ')}\n```\n{s}\n```\n")
open('logs/train_history.md', 'w', encoding='utf-8').write('\n'.join(out))
log = sh('git', 'log', '--reverse', '--format=- %cd — %s', '--date=format:%Y-%m-%d %H:%M', 'origin/main')
open('logs/CHANGELOG.md', 'w', encoding='utf-8').write("# История изменений проекта (что и когда делалось)\n\n" + log)
