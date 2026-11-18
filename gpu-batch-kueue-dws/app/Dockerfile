FROM python:3.12-slim

# GKE Standard COS_CONTAINERD のホスト NVIDIA ドライバ (/usr/local/nvidia/lib64, bin) を参照するため必須
ENV DEBIAN_FRONTEND=noninteractive \
    PYTHONUNBUFFERED=1 \
    XLA_PYTHON_CLIENT_PREALLOCATE=false \
    PATH="/usr/local/nvidia/bin:${PATH}" \
    LD_LIBRARY_PATH="/usr/local/nvidia/lib64"

# jax[cuda12] により CUDA 12.9+ (ptxas sm_120 対応) が導入され、
# G4 (RTX PRO 6000 Blackwell, sm_120) と G2 (L4, sm_89) の両方で @jax.jit が動作します
RUN pip install --no-cache-dir --upgrade pip && \
    pip install --no-cache-dir "jax[cuda12]" pillow numpy

WORKDIR /app
COPY process_sensor_image.py /app/process_sensor_image.py
ENTRYPOINT ["python3", "/app/process_sensor_image.py"]
