
```bash
export CLUSTER_NAME=std-01
export NODEPOOL_NAME=pool01
export COMPUTE_ZONE=asia-northeast1-b
```

# Cluster Autoscaler enabled
```bash
export TOTAL_MIN_NODES=1
export TOTAL_MAX_NODES=3

gcloud container node-pools create ${NODEPOOL_NAME} \
    --cluster=${CLUSTER_NAME} \
    --zone=${COMPUTE_ZONE} \
    --workload-metadata=GKE_METADATA \
    --enable-private-nodes \
    --enable-autoscaling \
    --total-min-nodes=${TOTAL_MIN_NODES} \
    --total-max-nodes=${TOTAL_MAX_NODES} \
    --enable-image-streaming
```

# Spot VMs Node Pool
```bash
export TOTAL_MIN_NODES=1
export TOTAL_MAX_NODES=3

gcloud container node-pools create ${NODEPOOL_NAME} \
    --cluster=${CLUSTER_NAME} \
    --zone=${COMPUTE_ZONE} \
    --workload-metadata=GKE_METADATA \
    --enable-private-nodes \
    --enable-autoscaling \
    --total-min-nodes=${TOTAL_MIN_NODES} \
    --total-max-nodes=${TOTAL_MAX_NODES} \
    --enable-image-streaming \
    --spot
```