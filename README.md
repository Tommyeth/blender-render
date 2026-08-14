# blender-render — 开机即渲的 Blender 渲染节点镜像

装好 **Blender 5.1.2**（和 `围棋星空场景.blend` 同版本，版本不一致会静默丢材质/节点）的无头渲染镜像。
容器一启动就渲染，渲完退出，退出码就是渲染结果 —— 适合塞进 systemd、K8s Job、或者按量计费的 GPU 实例。

镜像地址：`ghcr.io/<你的用户名>/blender-render:5.1.2`

---

## 1. 服务器准备（只做一次）

宿主机需要 NVIDIA 驱动 + NVIDIA Container Toolkit。镜像本身**不含** CUDA，
驱动和 OptiX 由 toolkit 在运行时注入，所以镜像只有 ~1.2 GB 而不是 4 GB。

```bash
# Ubuntu / Debian
curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
  | sudo gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
  | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
  | sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list
sudo apt-get update && sudo apt-get install -y nvidia-container-toolkit
sudo nvidia-ctk runtime configure --runtime=docker && sudo systemctl restart docker
```

自检：

```bash
docker run --rm --gpus all ubuntu:24.04 nvidia-smi
```

## 2. 渲一张图

```bash
docker run --rm --gpus all \
  -v /srv/scenes:/scene -v /srv/out:/out \
  -e SCENE=/scene/围棋星空场景.blend \
  -e SAMPLES=400 \
  ghcr.io/<你的用户名>/blender-render:5.1.2
```

## 3. 渲整段动画（1–1800 帧）

```bash
docker run --rm --gpus all \
  -v /srv/scenes:/scene -v /srv/out:/out \
  -e SCENE=/scene/围棋星空场景.blend \
  -e MODE=animation -e FRAME_START=1 -e FRAME_END=1800 \
  -e SAMPLES=200 -e FORMAT=OPEN_EXR \
  ghcr.io/<你的用户名>/blender-render:5.1.2
```

## 4. 多卡 / 多机分片

一块卡跑一个容器，用 `FRAME_OFFSET` + `FRAME_STEP` 交错分帧，谁快谁多干，不用调度器：

```bash
for i in 0 1 2 3; do
  docker run -d --rm --gpus "device=${i}" \
    -v /srv/scenes:/scene -v /srv/out:/out \
    -e SCENE=/scene/围棋星空场景.blend \
    -e MODE=animation -e FRAME_START=1 -e FRAME_END=1800 \
    -e FRAME_OFFSET=${i} -e FRAME_STEP=4 \
    -e SAMPLES=200 \
    ghcr.io/<你的用户名>/blender-render:5.1.2
done
```

## 5. 环境变量

| 变量 | 默认 | 说明 |
|---|---|---|
| `SCENE` | `/scene/scene.blend` | .blend 路径。找不到时会自动在 `/scene` 下找唯一的 .blend |
| `OUT` | `/out/frame_` | 输出前缀，Blender 会自动补帧号 |
| `MODE` | `still` | `still` 单帧 / `animation` 序列 |
| `FRAME` | `1` | 单帧模式渲第几帧 |
| `FRAME_START` / `FRAME_END` | 用文件里的 | 动画范围 |
| `FRAME_STEP` / `FRAME_OFFSET` | `1` / `0` | 分片用 |
| `DEVICE` | `OPTIX` | `OPTIX` / `CUDA` / `HIP` / `ONEAPI` / `CPU`；选定的后端没设备时按顺序回退 |
| `SAMPLES` | 用文件里的 | Cycles 采样数 |
| `RES_PERCENT` | 用文件里的 | 分辨率百分比，试渲用 `25` |
| `FORMAT` | `PNG` | `PNG` / `JPEG` / `OPEN_EXR` / `OPEN_EXR_MULTILAYER` |
| `DENOISE` | `1` | 降噪开关 |
| `MOTION_BLUR` | 用文件里的 | `0` 关 / `1` 开 |
| `THREADS` | `0` | CPU 线程数，0 = 自动 |
| `FAIL_IF_NO_GPU` | `1` | 找不到 GPU 直接退出码 3，**不要**悄悄用 CPU 慢慢磨 |

传任意命令进去就跳过渲染，进容器排查：

```bash
docker run --rm -it --gpus all ghcr.io/<你的用户名>/blender-render:5.1.2 bash
```

## 6. 把场景烤进镜像

想要真正的"开机就渲、不挂载任何东西"：

```bash
cp ../围棋星空场景.blend scene/scene.blend
docker build -t ghcr.io/<你的用户名>/blender-render:scene .
```

`scene/` 下的东西会被复制到镜像的 `/scene`。缺点是镜像大 45 MB 且改场景要重新构建。

## 7. 发布到 GHCR

推到 GitHub 后 Actions 自动构建推送（`.github/workflows/publish.yml`）：

```bash
cd blender-render-image
git init && git add -A && git commit -m "blender render node image"
gh repo create blender-render --private --source=. --push
```

首次推送后到仓库 **Packages** 页面把镜像设为 private/public。私有镜像在服务器上要先登录：

```bash
echo "$GHCR_PAT" | docker login ghcr.io -u <你的用户名> --password-stdin
```

不想用 Actions 也可以本机构建推送（Apple Silicon 上必须加 `--platform`，否则推出去的是 arm64，服务器跑不了）：

```bash
docker buildx build --platform linux/amd64 \
  -t ghcr.io/<你的用户名>/blender-render:5.1.2 --push .
```

## 8. 换 Blender 版本

改 `Dockerfile` 里的三个 ARG，校验值取自
`https://download.blender.org/release/Blender<X.Y>/blender-<X.Y.Z>.sha256`。
**版本必须和保存 .blend 的 Blender 一致。**

---

## 已知的坑（都已在镜像里处理）

- **空的视频序列编辑器**会让 Blender 输出空白帧而完全跳过 3D 渲染。`render.py` 会检测并关掉它。
- **`--` 之后的参数属于 Python，不属于 Blender**，所以 `-f` / `-a` 必须写在 `--` 前面，
  否则容器看起来跑完了却一帧都没渲。
- **`cycles.device` 存在 .blend 里，但具体用哪块卡是本机偏好设置**，不跟着文件走 ——
  所以每次渲染都要在 `render.py` 里重新枚举并启用设备。
- CPU 设备**故意不启用**：混合 CPU+GPU 在 Cycles 里经常拖慢整体队列。
