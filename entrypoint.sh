#!/usr/bin/env bash
# Container entrypoint: boot -> render -> exit with the render's status.
#
#   docker run --rm --gpus all \
#     -v /srv/scenes:/scene -v /srv/out:/out \
#     -e SCENE=/scene/围棋星空场景.blend -e MODE=animation \
#     -e FRAME_START=1 -e FRAME_END=1800 -e SAMPLES=200 \
#     ghcr.io/<owner>/blender-render:5.1.2
#
# Pass any argument to skip rendering and run that command instead:
#   docker run --rm -it ... ghcr.io/<owner>/blender-render bash
set -euo pipefail

if [[ $# -gt 0 ]]; then
    exec "$@"
fi

BLENDER=/opt/blender/blender

# --------------------------------------------------------------- serve mode
# GPU marketplaces launch the container and expect it to stay up with sshd,
# not to render once and exit. Detect that and serve instead.
#
# Only when we are the container's own init (direct child of PID 1) — so that
# typing `render` inside an SSH session still renders instead of sleeping.
ppid=$(awk '{print $4}' /proc/self/stat 2>/dev/null || echo 0)
if [[ "${SERVE:-0}" == "1" || ( -n "${VAST_CONTAINERLABEL:-}" && "${ppid}" == "1" ) ]]; then
    echo "[render] serve mode (${VAST_CONTAINERLABEL:-SERVE=1})"
    mkdir -p /run/sshd /root/.ssh /scene /out
    [[ -n "${PUBLIC_KEY:-}" ]] && echo "${PUBLIC_KEY}" >> /root/.ssh/authorized_keys
    # normalise whatever the platform injected; sshd is picky and fails silently
    chown -R root:root /root/.ssh 2>/dev/null || true
    chmod 700 /root/.ssh 2>/dev/null || true
    [[ -f /root/.ssh/authorized_keys ]] && chmod 600 /root/.ssh/authorized_keys
    ssh-keygen -A >/dev/null 2>&1 || true
    /usr/sbin/sshd -e 2>&1 | sed 's/^/[sshd] /' &
    nvidia-smi --query-gpu=name,driver_version --format=csv,noheader 2>/dev/null \
        | sed 's/^/[render] gpu     /' || echo "[render] gpu     (none visible)"
    cat <<'BANNER'
[render] ------------------------------------------------------------------
[render] container is up. ssh in, then render with the same env vars:
[render]
[render]   SCENE=/scene/xxx.blend SAMPLES=64 RES_PERCENT=25 render
[render]   SCENE=/scene/xxx.blend SAMPLES=400 render
[render]   SCENE=/scene/xxx.blend MODE=animation FRAME_START=1 FRAME_END=1800 render
[render]
[render] upload the scene from your machine:
[render]   scp -P <port> your.blend root@<host>:/scene/
[render] set AUTORENDER=1 to render on boot instead of waiting.
[render] ------------------------------------------------------------------
BANNER
    if [[ "${AUTORENDER:-0}" == "1" ]]; then
        SERVE=0 "$0" || echo "[render] boot render failed (status $?), staying up"
    fi
    exec sleep infinity
fi

# ---------------------------------------------------------------- scene file
if [[ ! -f "${SCENE}" ]]; then
    # be forgiving: pick the only .blend we can find under /scene
    mapfile -t found < <(find /scene -maxdepth 2 -name '*.blend' -type f 2>/dev/null | sort)
    if [[ ${#found[@]} -eq 1 ]]; then
        SCENE="${found[0]}"
        echo "[render] SCENE not set/found, using ${SCENE}"
    elif [[ ${#found[@]} -gt 1 ]]; then
        echo "[render] ERROR: several .blend files under /scene, set -e SCENE=..." >&2
        printf '  %s\n' "${found[@]}" >&2
        exit 2
    else
        echo "[render] ERROR: no .blend at ${SCENE} and none under /scene." >&2
        echo "         mount it:  -v /path/to/scenes:/scene -e SCENE=/scene/x.blend" >&2
        exit 2
    fi
fi

mkdir -p "$(dirname "${OUT}")"

# ------------------------------------------------------------------ run flags
bool01() { case "${1,,}" in 1|true|yes|on) echo 1 ;; *) echo 0 ;; esac; }
cfg=$(cat <<JSON
{"device":"${DEVICE}","samples":"${SAMPLES}","res_percent":"${RES_PERCENT}",
 "format":"${FORMAT}","denoise":$(bool01 "${DENOISE:-1}"),"motion_blur":"${MOTION_BLUR}",
 "threads":"${THREADS}","fail_if_no_gpu":$(bool01 "${FAIL_IF_NO_GPU:-0}"),
 "gpu_index":"${GPU_INDEX}"}
JSON
)

args=(-b "${SCENE}" -noaudio)
[[ "${ENABLE_AUTOEXEC}" == "1" ]] && args+=(--enable-autoexec)
args+=(-o "${OUT}" -F "${FORMAT}" --python /opt/render/render.py)
# shellcheck disable=SC2206
[[ -n "${EXTRA_ARGS}" ]] && args+=(${EXTRA_ARGS})

# Blender executes flags in order, so the render range must come *after*
# --python (so the script has already set the device) but *before* the "--"
# that hands the rest of the line to Python.
if [[ "${MODE}" == "animation" || "${MODE}" == "anim" ]]; then
    [[ -n "${FRAME_START:-}" ]] && args+=(-s "$(( FRAME_START + FRAME_OFFSET ))")
    [[ -n "${FRAME_END:-}"   ]] && args+=(-e "${FRAME_END}")
    [[ "${FRAME_STEP}" != "1" ]] && args+=(-j "${FRAME_STEP}")
    args+=(-a)
else
    args+=(-f "$(( FRAME + FRAME_OFFSET ))")
fi
args+=(-- "${cfg}")

echo "[render] blender ${BLENDER_VERSION}"
echo "[render] scene   ${SCENE}"
echo "[render] out     ${OUT}"
echo "[render] mode    ${MODE}  device=${DEVICE}"
nvidia-smi --query-gpu=index,name,memory.total,driver_version \
           --format=csv,noheader 2>/dev/null | sed 's/^/[render] gpu     /' || \
    echo "[render] gpu     (nvidia-smi unavailable — did you pass --gpus all ?)"

set +e
"${BLENDER}" "${args[@]}"
status=$?
set -e

if [[ ${status} -ne 0 ]]; then
    echo "[render] FAILED with status ${status}" >&2
    exit ${status}
fi

echo "[render] done. files in $(dirname "${OUT}"):"
ls -lh "$(dirname "${OUT}")" | tail -n +2 | sed 's/^/[render]   /'
