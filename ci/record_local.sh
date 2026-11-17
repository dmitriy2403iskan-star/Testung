#!/bin/bash
# Запись видео: ci/record_local.sh <чекпоинт.json> <секунд> [подвес 0-3] [выход.mp4]
# Пример: ci/record_local.sh /tmp/ck_walk_a.json 20 2 walk.mp4
set -e
CK=$(realpath "$1"); S=${2:-20}; SUP=${3:-}; OUT=$(realpath -m "${4:-video.mp4}"); SRC=$PWD
G=${GODOT_BIN:-godot}
W=$(mktemp -d); cp -r "$SRC" $W/p; cd $W/p
cp ci/record.gd record.gd
sed -i 's|^\[autoload\]|[autoload]\nRecorder="*res://record.gd"|' project.godot
$G --headless --import >/dev/null 2>&1 || true
REPLAY_FILE=$CK FRAMES=$((S*30)) SUP=$SUP NO_LLM=1 xvfb-run -a -s "-screen 0 720x1280x24" \
  $G --rendering-driver opengl3 --write-movie out.avi --fixed-fps 30 --resolution 540x960
ffmpeg -y -loglevel error -i out.avi -c:v libx264 -pix_fmt yuv420p -crf 26 "$OUT"
