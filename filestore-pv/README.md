## API 有効化
```bash
gcloud services enable file.googleapis.com \
    container.googleapis.com \
    artifactregistry.googleapis.com
```

## GKE Cluster 作成
```bash
export PROJECT_ID=<YOUR_PROJECT_ID>
export CLUSTER_NAME=stateful-cluster
export CLUSTER_VER=1.27.13-gke.1201000

gcloud container clusters create ${CLUSTER_NAME} \
  --location=us-central1-a --cluster-version=${CLUSTER_VER} \
  --enable-dataplane-v2 --enable-ip-alias \
  --enable-multi-networking \
  --no-enable-autoupgrade \
  --enable-image-streaming \
  --workload-pool=${PROJECT_ID}.svc.id.goog \
  --addons=GcpFilestoreCsiDriver,GcsFuseCsiDriver
```

## Filestore PV の作成

```bash
# Deploy Filestore StorageClass
kubectl apply -f sc-filestore.yaml 

# Deploy Sample Application
kubectl apply -f filestore-example-deployment.yaml
```

```yaml:sc-filestore.yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: sc-filestore
provisioner: filestore.csi.storage.gke.io
volumeBindingMode: Immediate
allowVolumeExpansion: true
parameters:
  tier: standard
  network: default
```

```yaml:filestore-example-deployment.yaml
kind: PersistentVolumeClaim
apiVersion: v1
metadata:
  name: pvc-filestore
spec:
  accessModes:
  - ReadWriteMany
  storageClassName: sc-filestore
  resources:
    requests:
      storage: 1Ti
```