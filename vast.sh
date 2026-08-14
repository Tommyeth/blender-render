#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# 在 Vast.ai / RunPod / 任意裸 Ubuntu GPU 实例上直接装 Blender 5.1.2 渲染环境。
#
#   bash <(curl -fsSL https://raw.githubusercontent.com/Tommyeth/blender-render/main/vast.sh)
#
# 装完以后用法和 Docker 镜像完全一样，同一套环境变量：
#   SCENE=/workspace/scene.blend SAMPLES=400 render
#
# 为什么有这个脚本：Vast.ai 用自己的 kaalia shim 包装容器创建，自定义镜像经常
# 起不来，而且它不支持宿主机 bind mount。既然镜像做的事就是"解压一个 tarball",
# 那在它自带的模板里直接解压这个 tarball 更省事。
# ---------------------------------------------------------------------------
set -euo pipefail

BLENDER_VERSION="${BLENDER_VERSION:-5.1.2}"
BLENDER_SERIES="${BLENDER_SERIES:-5.1}"
BLENDER_SHA256="${BLENDER_SHA256:-aaccb355f50183979b698bcce7467103a76261b5fa59f4972295842662a285fb}"
RAW="https://raw.githubusercontent.com/Tommyeth/blender-render/main"

say() { printf '\033[36m[setup]\033[0m %s\n' "$*"; }

[[ $EUID -eq 0 ]] || { echo "run as root"; exit 1; }

say "GPU:"
nvidia-smi --query-gpu=name,memory.total,driver_version --format=csv,noheader || {
    echo "!! nvidia-smi failed — 这台机器没有可用 GPU，先别往下装"; exit 1; }

say "installing runtime libs"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq --no-install-recommends \
    ca-certificates curl xz-utils \
    libx11-6 libxext6 libxrender1 libxi6 libxxf86vm1 libxfixes3 \
    libxrandr2 libxinerama1 libxcursor1 libxkbcommon0 \
    libsm6 libice6 libgl1 libegl1 libgomp1 \
    libfreetype6 libfontconfig1 libdbus-1-3 zlib1g >/dev/null
# mesa GL package name differs between 22.04 and 24.04
apt-get install -y -qq --no-install-recommends libglx-mesa0 >/dev/null 2>&1 || \
apt-get install -y -qq --no-install-recommends libgl1-mesa-glx >/dev/null 2>&1 || true

if [[ -x /opt/blender/blender ]] && /opt/blender/blender --version 2>/dev/null | grep -q "${BLENDER_VERSION}"; then
    say "Blender ${BLENDER_VERSION} already installed"
else
    say "downloading Blender ${BLENDER_VERSION} (~400 MB)"
    url="https://download.blender.org/release/Blender${BLENDER_SERIES}/blender-${BLENDER_VERSION}-linux-x64.tar.xz"
    curl -fL --retry 5 --retry-delay 3 --progress-bar -o /tmp/blender.tar.xz "$url"
    say "verifying checksum"
    echo "${BLENDER_SHA256}  /tmp/blender.tar.xz" | sha256sum -c -
    rm -rf /opt/blender && mkdir -p /opt/blender
    tar -xJf /tmp/blender.tar.xz -C /opt/blender --strip-components=1
    rm -f /tmp/blender.tar.xz
fi
ln -sf /opt/blender/blender /usr/local/bin/blender

say "installing render wrapper"
mkdir -p /opt/render /scene /out
curl -fsSL -o /opt/render/render.py     "${RAW}/render.py"
curl -fsSL -o /opt/render/entrypoint.sh "${RAW}/entrypoint.sh"
chmod +x /opt/render/entrypoint.sh

cat > /usr/local/bin/render <<'WRAP'
#!/usr/bin/env bash
# same knobs as the docker image
: "${SCENE:=/scene/scene.blend}";      export SCENE
: "${OUT:=/out/frame_}";               export OUT
: "${MODE:=still}";                    export MODE
: "${FRAME:=1}";                       export FRAME
: "${FRAME_START:=}";                  export FRAME_START
: "${FRAME_END:=}";                    export FRAME_END
: "${FRAME_STEP:=1}";                  export FRAME_STEP
: "${FRAME_OFFSET:=0}";                export FRAME_OFFSET
: "${DEVICE:=OPTIX}";                  export DEVICE
: "${SAMPLES:=}";                      export SAMPLES
: "${RES_PERCENT:=}";                  export RES_PERCENT
: "${FORMAT:=PNG}";                    export FORMAT
: "${DENOISE:=1}";                     export DENOISE
: "${MOTION_BLUR:=}";                  export MOTION_BLUR
: "${THREADS:=0}";                     export THREADS
: "${FAIL_IF_NO_GPU:=1}";              export FAIL_IF_NO_GPU
: "${ENABLE_AUTOEXEC:=1}";             export ENABLE_AUTOEXEC
: "${EXTRA_ARGS:=}";                   export EXTRA_ARGS
: "${BLENDER_VERSION:=5.1.2}";         export BLENDER_VERSION
exec /opt/render/entrypoint.sh "$@"
WRAP
chmod +x /usr/local/bin/render

say "done."
/opt/blender/blender --version | head -1
cat <<'EOF'

下一步：
  1) 把场景传上来（在你的 Mac 上执行）：
       scp -P <端口> "围棋星空场景.blend" root@<主机>:/scene/
  2) 试渲一帧看 GPU 认没认出来：
       SCENE=/scene/围棋星空场景.blend SAMPLES=64 RES_PERCENT=25 render
  3) 正式 4K：
       SCENE=/scene/围棋星空场景.blend SAMPLES=400 render
  4) 整段动画：
       SCENE=/scene/围棋星空场景.blend MODE=animation FRAME_START=1 FRAME_END=1800 \
       SAMPLES=200 FORMAT=OPEN_EXR render

日志里出现  [render.py] engine CYCLES / GPU (OPTIX)  就说明卡吃上了。
EOF
