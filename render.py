# Runs inside Blender:  blender -b scene.blend --python render.py -- <json>
# Configures the compute device and applies per-run overrides, then Blender's
# own -f / -a flags (added by entrypoint.sh) do the actual rendering.
import bpy
import json
import os
import sys

argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
cfg = json.loads(argv[0]) if argv else {}


def log(msg):
    print("[render.py] %s" % msg, flush=True)


scene = bpy.context.scene
scene.render.engine = 'CYCLES'

# --------------------------------------------------------------- device setup
want = (cfg.get("device") or "OPTIX").upper()
gpu_ok = False
backend = "CPU"

if want != "CPU":
    try:
        prefs = bpy.context.preferences.addons["cycles"].preferences

        candidates = [want] + [b for b in ("OPTIX", "CUDA", "HIP", "ONEAPI", "METAL")
                               if b != want]
        available = set()
        try:
            available = {i.identifier for i in
                         prefs.bl_rna.properties["compute_device_type"].enum_items}
        except Exception:
            pass

        for b in candidates:
            if available and b not in available:
                continue
            try:
                prefs.compute_device_type = b
            except TypeError:
                continue
            for fn in ("refresh_devices", "get_devices"):
                if hasattr(prefs, fn):
                    try:
                        getattr(prefs, fn)()
                        break
                    except Exception:
                        pass
            devs = [d for d in prefs.devices if d.type == b]
            if devs:
                for d in prefs.devices:
                    # enable every accelerator of the chosen backend; leave the
                    # CPU off so it does not throttle the GPU queue
                    d.use = (d.type == b)
                backend = b
                gpu_ok = True
                log("backend %s -> %s" % (b, ", ".join(d.name for d in devs)))
                break
            log("backend %s: no devices" % b)
    except Exception as e:                                   # pragma: no cover
        log("device setup failed: %r" % e)

scene.cycles.device = 'GPU' if gpu_ok else 'CPU'
if not gpu_ok:
    if cfg.get("fail_if_no_gpu"):
        log("FATAL: no GPU found and FAIL_IF_NO_GPU=1")
        sys.exit(3)
    log("WARNING: falling back to CPU")

# ------------------------------------------------------------------ overrides
def setnum(obj, attr, key, cast=float):
    v = cfg.get(key)
    if v not in (None, ""):
        setattr(obj, attr, cast(v))
        log("%s = %s" % (key, getattr(obj, attr)))


setnum(scene.cycles, "samples", "samples", int)
setnum(scene.render, "resolution_percentage", "res_percent", int)

if cfg.get("denoise") is not None:
    scene.cycles.use_denoising = bool(cfg["denoise"])
if cfg.get("motion_blur") not in (None, ""):
    scene.render.use_motion_blur = bool(int(cfg["motion_blur"]))
if cfg.get("threads"):
    scene.render.threads_mode = 'FIXED'
    scene.render.threads = int(cfg["threads"])

fmt = (cfg.get("format") or "").upper()
if fmt:
    scene.render.image_settings.file_format = fmt
    if fmt in ("OPEN_EXR", "OPEN_EXR_MULTILAYER"):
        scene.render.image_settings.color_depth = '16'

# An empty sequencer silently short-circuits the whole render: Blender outputs
# the (blank) VSE strip instead of the 3D scene. Guard against it.
if cfg.get("guard_sequencer", 1) and scene.render.use_sequencer:
    se = scene.sequence_editor
    # Blender renamed .sequences -> .strips in 5.x; check whichever exists
    strips = None
    for attr in ("strips", "sequences"):
        if se is not None and hasattr(se, attr):
            strips = getattr(se, attr)
            break
    if se is None or (strips is not None and len(strips) == 0):
        scene.render.use_sequencer = False
        log("empty sequencer disabled (it would have rendered a blank frame)")

# ---------------------------------------------------------------- diagnostics
log("blender      %s" % bpy.app.version_string)
log("file         %s" % bpy.data.filepath)
log("engine       %s / %s (%s)" % (scene.render.engine, scene.cycles.device, backend))
log("resolution   %dx%d @ %d%%" % (scene.render.resolution_x,
                                   scene.render.resolution_y,
                                   scene.render.resolution_percentage))
log("samples      %d  denoise=%s  motion_blur=%s"
    % (scene.cycles.samples, scene.cycles.use_denoising, scene.render.use_motion_blur))
log("camera       %s" % (scene.camera.name if scene.camera else "!! NONE !!"))
log("frames       %d..%d" % (scene.frame_start, scene.frame_end))
log("output       %s (%s)" % (scene.render.filepath,
                              scene.render.image_settings.file_format))
if not scene.camera:
    log("FATAL: scene has no camera")
    sys.exit(4)
