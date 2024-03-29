
```bash
# Update gcloud 
gcloud components update

# Create GKE Cluster
export PROJECT_ID=kkuchima-sandbox
export CLUSTER_NAME=v100-cluster
export CLUSTER_VERSION=1.26.3-gke.1000

gcloud beta container clusters create ${CLUSTER_NAME} \
    --region=us-central1 \
    --num-nodes=1 \
    --workload-pool=${PROJECT_ID}.svc.id.goog \
    --cluster-version=${CLUSTER_VERSION} \
    --addons GcsFuseCsiDriver \
    --enable-gvnic \
    --enable-image-streaming \
    --enable-managed-prometheus

# Create V100 Node
export ACCELERATOR_TYPE=nvidia-tesla-v100
export MACHINE_TYPE=n1-highmem-32

gcloud container node-pools create np-v100 \
    --accelerator="type=${ACCELERATOR_TYPE},count=4" \
    --region=us-central1 \
    --node-locations=us-central1-f \
    --num-nodes=1 \
    --machine-type=${MACHINE_TYPE} \
    --scopes="gke-default,storage-rw" \
    --cluster=${CLUSTER_NAME} \
    --enable-fast-socket \
    --enable-gvnic \
    --enable-image-streaming

# Install nvidia driver
kubectl apply -f https://raw.githubusercontent.com/GoogleCloudPlatform/container-engine-accelerators/master/nvidia-driver-installer/cos/daemonset-preloaded.yaml
```

# Create GCS Bucket
```bash
export BUCKET_NAME=kkuchima-sandbox-detectron2-sample
gsutil mb -l us-central1 gs://${BUCKET_NAME}
```

# Configure Workload Identity
```bash
# Create Google Cloud Service Account
export GCS_BUCKET_PROJECT_ID=kkuchima-sandbox
export GCP_SA_NAME=sa-gke-gcs
export CLUSTER_PROJECT_ID=kkuchima-sandbox
 
gcloud iam service-accounts create ${GCP_SA_NAME} --project=${GCS_BUCKET_PROJECT_ID}

export STORAGE_ROLE=roles/storage.admin

gcloud projects add-iam-policy-binding ${GCS_BUCKET_PROJECT_ID} \
    --member "serviceAccount:${GCP_SA_NAME}@${GCS_BUCKET_PROJECT_ID}.iam.gserviceaccount.com" \
    --role "${STORAGE_ROLE}"

# Create Kubernetes Service Account
# Kubernetes SA name
export K8S_SA_NAME=ksa-gcs
kubectl create serviceaccount ${K8S_SA_NAME} --namespace default

gcloud iam service-accounts add-iam-policy-binding ${GCP_SA_NAME}@${GCS_BUCKET_PROJECT_ID}.iam.gserviceaccount.com \
    --role roles/iam.workloadIdentityUser \
    --member "serviceAccount:${CLUSTER_PROJECT_ID}.svc.id.goog[default/${K8S_SA_NAME}]"

kubectl annotate serviceaccount ${K8S_SA_NAME} \
    iam.gke.io/gcp-service-account=${GCP_SA_NAME}@${GCS_BUCKET_PROJECT_ID}.iam.gserviceaccount.com
```

# Install DCGM Exporter
```bash
git clone https://github.com/suffiank/dcgm-on-gke && cd dcgm-on-gke

# Install DCGM Exporter
kubectl create namespace gpu-monitoring-system
kubectl apply -f quickstart/dcgm_quickstart.yml

# Configure Cloud Monitoring Dashboard
gcloud monitoring dashboards create \
 --config-from-file quickstart/gke-dcgm-dashboard.yml
```
