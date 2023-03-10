
```bash
export CLUSTER_NAME=std-01
export NODEPOOL_NAME=pool02
export COMPUTE_REGION=asia-northeast1
```

# Cluster Autoscaler enabled
```bash
export TOTAL_MIN_NODES=3
export TOTAL_MAX_NODES=6

gcloud container node-pools create ${NODEPOOL_NAME} \
    --cluster=${CLUSTER_NAME} \
    --region=${COMPUTE_REGION} \
    --workload-metadata=GKE_METADATA \
    --enable-private-nodes \
    --enable-autoscaling \
    --num-nodes=1 \
    --total-min-nodes=${TOTAL_MIN_NODES} \
    --total-max-nodes=${TOTAL_MAX_NODES} \
    --enable-image-streaming
```

# Spot VMs Node Pool
```bash
export TOTAL_MIN_NODES=3
export TOTAL_MAX_NODES=6

gcloud container node-pools create ${NODEPOOL_NAME} \
    --cluster=${CLUSTER_NAME} \
    --region=${COMPUTE_REGION}  \
    --workload-metadata=GKE_METADATA \
    --enable-private-nodes \
    --enable-autoscaling \
    --num-nodes=1 \
    --total-min-nodes=${TOTAL_MIN_NODES} \
    --total-max-nodes=${TOTAL_MAX_NODES} \
    --enable-image-streaming \
    --spot
```