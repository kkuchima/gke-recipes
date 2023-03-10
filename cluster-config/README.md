
```bash
export PROJECT_ID=kkuchima-sandbox
export CLUSTER_NAME=std01
export COMPUTE_REGION=asia-northeast1

gcloud container clusters create ${CLUSTER_NAME} \
    --region=${COMPUTE_REGION} \
    --release-channel "regular" \
    --enable-ip-alias \
    --enable-private-nodes \
    --master-ipv4-cidr "172.16.0.0/28" \
    --addons HorizontalPodAutoscaling,HttpLoadBalancing,NodeLocalDNS,GcePersistentDiskCsiDriver,GcpFilestoreCsiDriver \
    --enable-managed-prometheus \
    --workload-pool "${PROJECT_ID}.svc.id.goog" \
    --enable-image-streaming
```