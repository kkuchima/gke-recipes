# 事前にやるべきこと
Filestore API を有効化、Filestore CSI

```bash
gcloud container clusters create CLUSTER_NAME \
    --addons=GcpFilestoreCsiDriver \
    --cluster-version=VERSION
```