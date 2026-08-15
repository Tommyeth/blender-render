# syntax=docker/dockerfile:1.7
# ---------------------------------------------------------------------------
# Blender headless render node.
# Base is plain Ubuntu: the NVIDIA Container Toolkit injects the driver
# libraries (libcuda / OptiX) at run time, so we do NOT need a CUDA base image
# and the result stays ~1.2 GB instead of ~4 GB.
# ---------------------------------------------------------------------------

# Runtime base. Plain Ubuntu is enough for Cycles (see README "为什么不装 CUDA"),
# but some GPU clouds (Vast.ai, RunPod...) assume a CUDA base, so it is a knob.
ARG RUNTIME_BASE=ubuntu:24.04
ARG BLENDER_VERSION=5.1.2
ARG BLENDER_SERIES=5.1
# from https://download.blender.org/release/Blender5.1/blender-5.1.2.sha256
ARG BLENDER_SHA256=aaccb355f50183979b698bcce7467103a76261b5fa59f4972295842662a285fb

# --------------------------------------------------------------------- fetch
FROM ubuntu:24.04 AS fetch
ARG BLENDER_VERSION
ARG BLENDER_SERIES
ARG BLENDER_SHA256
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates curl xz-utils \
    && rm -rf /var/lib/apt/lists/*
RUN set -eux; \
    url="https://download.blender.org/release/Blender${BLENDER_SERIES}/blender-${BLENDER_VERSION}-linux-x64.tar.xz"; \
    curl -fsSL --retry 5 --retry-delay 3 -o /tmp/blender.tar.xz "$url"; \
    echo "${BLENDER_SHA256}  /tmp/blender.tar.xz" | sha256sum -c -; \
    mkdir -p /opt/blender; \
    tar -xJf /tmp/blender.tar.xz -C /opt/blender --strip-components=1; \
    rm /tmp/blender.tar.xz

# ------------------------------------------------------------------- runtime
FROM ${RUNTIME_BASE}
ARG BLENDER_VERSION
ARG RUNTIME_BASE

LABEL org.opencontainers.image.title="blender-render" \
      org.opencontainers.image.description="Headless Blender ${BLENDER_VERSION} render node (Cycles, NVIDIA OptiX/CUDA)" \
      org.opencontainers.image.licenses="GPL-3.0-or-later" \
      io.blender-render.runtime-base="${RUNTIME_BASE}"

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates tini openssh-server \
        libx11-6 libxext6 libxrender1 libxi6 libxxf86vm1 libxfixes3 \
        libxrandr2 libxinerama1 libxcursor1 libxkbcommon0 \
        libsm6 libice6 libgl1 libglx-mesa0 libegl1 libgomp1 \
        libfreetype6 libfontconfig1 libdbus-1-3 zlib1g \
    && rm -rf /var/lib/apt/lists/*

# GPU marketplaces (Vast.ai, RunPod) start the container and SSH into it.
# Ubuntu's sshd defaults to StrictModes yes, and the authorized_keys those
# platforms inject routinely arrives with perms/ownership it rejects, which
# shows up as a bare "Permission denied (publickey)" with no useful hint.
RUN mkdir -p /run/sshd /root/.ssh && chmod 700 /root/.ssh && \
    printf '%s\n' \
      'StrictModes no' \
      'PermitRootLogin prohibit-password' \
      'PasswordAuthentication no' \
      'ClientAliveInterval 60' \
      > /etc/ssh/sshd_config.d/99-render-node.conf

COPY --from=fetch /opt/blender /opt/blender

COPY render.py /opt/render/render.py
COPY entrypoint.sh /usr/local/bin/render
COPY farm.sh /usr/local/bin/farm
RUN chmod +x /usr/local/bin/render /usr/local/bin/farm

# let the NVIDIA container runtime hand us the driver + OptiX
ENV NVIDIA_VISIBLE_DEVICES=all \
    NVIDIA_DRIVER_CAPABILITIES=compute,utility,graphics \
    PATH="/opt/blender:${PATH}" \
    BLENDER_VERSION=${BLENDER_VERSION}

# ---- defaults; override any of these with -e at run time --------------------
ENV SCENE=/scene/scene.blend \
    OUT=/out/frame_ \
    MODE=still \
    FRAME=1 \
    FRAME_START= \
    FRAME_END= \
    FRAME_STEP=1 \
    FRAME_OFFSET=0 \
    DEVICE=OPTIX \
    SAMPLES= \
    RES_PERCENT= \
    FORMAT=PNG \
    DENOISE=1 \
    MOTION_BLUR= \
    THREADS=0 \
    GPU_INDEX= \
    FAIL_IF_NO_GPU=1 \
    ENABLE_AUTOEXEC=1 \
    EXTRA_ARGS=

# Anything dropped into ./scene/ in the build context gets baked into the image,
# so a fully self-contained "boot and it renders" image is just:
#   cp 围棋星空场景.blend scene/scene.blend && docker build .
# Leave scene/ empty and mount -v /path:/scene instead to keep the image small.
COPY scene/ /scene/

WORKDIR /out

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/render"]
