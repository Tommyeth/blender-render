#!/usr/bin/env bash
# 单机多卡：一卡一进程，交错分帧。
#   farm.sh <scene.blend> <first> <last> [samples] [res%]
# 每张卡跑一个 Blender，各取每第 N 帧，谁快谁多干，不需要调度器。
# 比"一个进程吃 N 张卡"快得多 —— 每帧的场景同步是串行的，卡再多也摊不掉。
set -euo pipefail
SCENE="${1:?用法: farm.sh <scene.blend> <first> <last> [samples] [res%]}"
FIRST="${2:?}"; LAST="${3:?}"; SAMP="${4:-300}"; RES="${5:-100}"
N=$(nvidia-smi --query-gpu=index --format=csv,noheader | wc -l)
echo "[farm] $N 张卡, 帧 $FIRST..$LAST, $SAMP 采样, $RES%"
mkdir -p /out/logs
for i in $(seq 0 $((N-1))); do
  SCENE="$SCENE" MODE=animation FRAME_START="$FIRST" FRAME_END="$LAST" \
  FRAME_OFFSET="$i" FRAME_STEP="$N" GPU_INDEX="$i" \
  SAMPLES="$SAMP" RES_PERCENT="$RES" FORMAT=PNG OUT="/out/frame_" \
  nohup render > "/out/logs/gpu${i}.log" 2>&1 &
  echo "[farm]   卡 $i -> 帧 $((FIRST+i)), 步长 $N"
done
wait
echo "[farm] 全部完成，共 $(ls /out/frame_*.png 2>/dev/null | wc -l) 帧"
