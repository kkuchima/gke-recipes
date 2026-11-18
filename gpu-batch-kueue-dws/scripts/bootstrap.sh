#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TF_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

PROJECT_ID="${PROJECT_ID:-$(terraform -chdir="${TF_DIR}" output -raw cluster_name >/dev/null 2>&1 && gcloud config get-value project)}"
CLUSTER_NAME="${CLUSTER_NAME:-$(terraform -chdir="${TF_DIR}" output -raw cluster_name)}"
CLUSTER_LOCATION="${CLUSTER_LOCATION:-$(terraform -chdir="${TF_DIR}" output -raw cluster_location)}"
BUCKET_NAME="${BUCKET_NAME:-$(terraform -chdir="${TF_DIR}" output -raw gcs_bucket_name)}"
IMAGE_URI="${IMAGE_URI:-$(terraform -chdir="${TF_DIR}" output -raw jax_image_uri)}"
KUEUE_VERSION="${KUEUE_VERSION:-v0.20.6}"
ENABLE_DWS_POOLS="${ENABLE_DWS_POOLS:-true}"

echo "=== [1/4] Generating & uploading sample 1024x1024 sensor PNG to gs://${BUCKET_NAME}/input/ ==="
TMP_PNG="$(mktemp /tmp/sensor_frame_XXXXXX.png)"
trap 'rm -f "${TMP_PNG}"' EXIT
python3 "${TF_DIR}/app/generate_sample_png.py" "${TMP_PNG}"
gcloud storage cp "${TMP_PNG}" "gs://${BUCKET_NAME}/input/sensor_frame_001.png" --project="${PROJECT_ID}"

echo "=== [2/4] Building & pushing CUDA 12.9 JAX image (${IMAGE_URI}) via Cloud Build ==="
gcloud builds submit "${TF_DIR}/app" \
  --tag="${IMAGE_URI}" \
  --project="${PROJECT_ID}"

echo "=== [3/4] Fetching GKE cluster credentials & installing Kueue (${KUEUE_VERSION}) ==="
gcloud container clusters get-credentials "${CLUSTER_NAME}" \
  --location="${CLUSTER_LOCATION}" \
  --project="${PROJECT_ID}"

kubectl apply --server-side -f "https://github.com/kubernetes-sigs/kueue/releases/download/${KUEUE_VERSION}/manifests.yaml"
kubectl wait --for=condition=Available deployment/kueue-controller-manager -n kueue-system --timeout=180s

echo "=== [4/4] Applying Namespace, GCSFuse PV/PVC, ComputeClass, CapacityQuota, and Kueue (v1beta2) queues ==="
kubectl apply -f "${TF_DIR}/generated-manifests/01-namespace-and-storage.yaml"
kubectl apply -f "${TF_DIR}/generated-manifests/02-computeclass-and-capacityquota.yaml"
kubectl apply -f "${TF_DIR}/generated-manifests/03-kueue-computeclass-queue.yaml"

if [[ "${ENABLE_DWS_POOLS}" == "true" ]]; then
  kubectl apply -f "${TF_DIR}/generated-manifests/04-kueue-dws-provreq.yaml"
fi

echo ""
echo "Bootstrap completed! Ready to submit verification GPU jobs:"
echo "  1) ComputeClass (CUD/Reservation -> On-Demand -> Flex-start): kubectl create -f ${TF_DIR}/generated-manifests/05-job-computeclass.yaml"
echo "  2) Kueue + DWS ProvisioningRequest (queued provisioning):     kubectl create -f ${TF_DIR}/generated-manifests/06-job-dws-provreq.yaml"
