import base64
import glob
import json
import os
import subprocess
import time
from datetime import datetime, timezone

import jax
import jax.numpy as jnp
import numpy as np
from PIL import Image


def now_iso():
    return datetime.now(timezone.utc).isoformat()


def log_event(events, stage, detail=None):
    entry = {
        "timestamp": now_iso(),
        "elapsed_sec": round(time.monotonic() - T0, 3),
        "stage": stage,
    }
    if detail is not None:
        entry["detail"] = detail
    events.append(entry)
    print(json.dumps(entry, ensure_ascii=False), flush=True)


T0 = time.monotonic()
events = []
log_event(
    events,
    "container_start",
    {"hostname": os.uname().nodename, "pod_name": os.environ.get("POD_NAME", "")},
)

# 1. Check nvidia-smi & GPU driver / Compute Capability
try:
    smi = subprocess.check_output(
        [
            "nvidia-smi",
            "--query-gpu=name,driver_version,memory.total,compute_cap,utilization.gpu",
            "--format=csv,noheader",
        ],
        text=True,
    ).strip()
    log_event(events, "nvidia_smi_ok", {"gpu_info": smi})
except Exception as exc:
    smi = f"ERROR: {exc}"
    log_event(events, "nvidia_smi_error", {"error": str(exc)})

# 2. Check JAX backend & devices
devices = [
    {"id": d.id, "platform": d.platform, "device_kind": getattr(d, "device_kind", str(d))}
    for d in jax.devices()
]
log_event(
    events,
    "jax_initialized",
    {
        "jax_version": jax.__version__,
        "default_backend": jax.default_backend(),
        "devices": devices,
    },
)
assert jax.default_backend() == "gpu", f"Expected GPU backend, got {jax.default_backend()}"

# 3. Verify emptyDir instrumentation volume (/instrumentation)
inst_dir = os.environ.get("INSTRUMENTATION_DIR", "/instrumentation")
if os.path.isdir(inst_dir):
    inst_path = os.path.join(inst_dir, "heartbeat.json")
    with open(inst_path, "w") as f:
        json.dump({"status": "running", "ts": now_iso(), "gpu": smi}, f)
    with open(inst_path, "r") as f:
        readback = json.load(f)
    log_event(
        events,
        "emptydir_verified",
        {"path": inst_path, "readback_status": readback["status"]},
    )

# 4. Verify Projected OIDC Token for AWS AssumeRoleWithWebIdentity
oidc_token_path = os.environ.get(
    "AWS_WEB_IDENTITY_TOKEN_FILE", "/var/run/secrets/aws-oidc/token"
)
if os.path.isfile(oidc_token_path):
    with open(oidc_token_path, "r") as f:
        tok = f.read().strip()
    parts = tok.split(".")
    pad = lambda s: s + "=" * (-len(s) % 4)
    claims = json.loads(base64.urlsafe_b64decode(pad(parts[1])).decode("utf-8"))
    log_event(
        events,
        "aws_oidc_token_verified",
        {
            "iss": claims.get("iss"),
            "sub": claims.get("sub"),
            "aud": claims.get("aud"),
            "exp_in_sec": claims.get("exp", 0) - claims.get("iat", 0),
        },
    )

# 5. Read sensor image(s) from GCS FUSE mount (/gcs/input)
gcs_input_dir = os.environ.get("GCS_INPUT_DIR", "/gcs/input")
imgs = []
if os.path.isdir(gcs_input_dir):
    t_read0 = time.monotonic()
    files = sorted(glob.glob(os.path.join(gcs_input_dir, "*.png")))
    total_bytes = 0
    for fp in files:
        with open(fp, "rb") as fh:
            data = fh.read()
            total_bytes += len(data)
        img = np.asarray(Image.open(fp), dtype=np.float32)
        imgs.append(img)
    read_sec = time.monotonic() - t_read0
    log_event(
        events,
        "gcs_fuse_read_complete",
        {
            "file_count": len(files),
            "total_bytes": total_bytes,
            "read_sec": round(read_sec, 4),
            "throughput_mb_s": round(
                (total_bytes / (1024 * 1024)) / max(read_sec, 1e-6), 2
            ),
        },
    )

if not imgs:
    imgs = [np.random.rand(1024, 1024, 3).astype(np.float32) * 255.0]


# 6. Run JIT-compiled JAX GPU sensor image analysis (2D FFT + spatial gradient + 4096x4096 matmul)
@jax.jit
def analyze_sensor_frame(frame):
    norm = frame / 255.0
    gray = jnp.mean(norm, axis=-1)
    spectrum = jnp.abs(jnp.fft.fft2(gray))
    gx = jnp.diff(gray, axis=1)
    gy = jnp.diff(gray, axis=0)
    mat = jnp.tile(gray[:1024, :1024], (4, 4))
    prod = jnp.matmul(mat, mat.T)
    return {
        "mean_intensity": jnp.mean(gray),
        "std_intensity": jnp.std(gray),
        "p99_intensity": jnp.percentile(gray, 99.0),
        "fft_peak": jnp.max(spectrum[1:, 1:]),
        "grad_rms": jnp.sqrt(jnp.mean(gx**2) + jnp.mean(gy**2)),
        "matmul_checksum": jnp.mean(prod),
    }


t_jit0 = time.monotonic()
first_res = analyze_sensor_frame(jnp.asarray(imgs[0]))
jax.block_until_ready(first_res)
log_event(
    events,
    "jax_jit_compile_and_first_run",
    {"jit_and_exec_sec": round(time.monotonic() - t_jit0, 4)},
)

num_iters = int(os.environ.get("BENCH_ITERS", "20"))
t_exec0 = time.monotonic()
for i in range(num_iters):
    res = analyze_sensor_frame(jnp.asarray(imgs[i % len(imgs)]))
    jax.block_until_ready(res)
exec_sec = time.monotonic() - t_exec0

metrics = {k: float(v) for k, v in res.items()}
log_event(
    events,
    "jax_gpu_batch_complete",
    {
        "iterations": num_iters,
        "total_exec_sec": round(exec_sec, 4),
        "per_frame_ms": round((exec_sec / num_iters) * 1000.0, 2),
        "metrics": metrics,
    },
)

# 7. Write output JSON to GCS FUSE (/gcs/output)
gcs_output_dir = os.environ.get("GCS_OUTPUT_DIR", "/gcs/output")
if os.path.isdir(os.path.dirname(gcs_output_dir)):
    os.makedirs(gcs_output_dir, exist_ok=True)
    out_path = os.path.join(
        gcs_output_dir,
        os.environ.get("JOB_RUN_ID", os.uname().nodename) + "-result.json",
    )
    with open(out_path, "w") as f:
        json.dump(
            {"gpu": smi, "jax_devices": devices, "metrics": metrics, "events": events},
            f,
            indent=2,
        )
    log_event(events, "gcs_fuse_write_complete", {"output_path": out_path})

log_event(events, "job_succeeded")
