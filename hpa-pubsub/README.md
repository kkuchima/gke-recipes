# Pub/Sub の準備
```bash
# Topic の作成
gcloud pubsub topics create echo

# Subscription の作成
gcloud pubsub subscriptions create echo-read --topic=echo

# Message の Publish
gcloud pubsub topics publish echo --message="hello"
```

# Workload Identity の設定
```bash
# GKE 側で Workload Identity が有効になっている前提
# 環境変数の設定
export GSA_NAME=gsa-pubsub
export KSA_NAME=ksa-pubsub
export NAMESPACE=default
export PROJECT_ID=kkuchima-sandbox

# Kubernetes サービスアカウントの作成
kubectl create serviceaccount ${KSA_NAME} \
  --namespace ${NAMESPACE}

# Google Cloud サービスアカウント (GSA) の作成
gcloud iam service-accounts create ${GSA_NAME}

# GSA に必要なロールを割り当て
gcloud projects add-iam-policy-binding ${PROJECT_ID} \
    --member "serviceAccount:${GSA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com" \
    --role "roles/pubsub.subscriber"

# GSA と KSA 間でのバインディング
gcloud iam service-accounts add-iam-policy-binding ${GSA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com \
    --role roles/iam.workloadIdentityUser \
    --member "serviceAccount:${PROJECT_ID}.svc.id.goog[${NAMESPACE}/${KSA_NAME}]"

# KSA にアノテーションを付与
kubectl annotate serviceaccount ${KSA_NAME} \
    --namespace ${NAMESPACE} \
    iam.gke.io/gcp-service-account=${GSA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com

# アプリケーションのデプロイ
kubectl apply -f pubsub-app.yaml
```

# Pub/Sub メトリクスベースの HPA

```bash
# GKE 側で Workload Identity が有効になっている前提
# 環境変数の設定
export GSA_NAME=gsa-viewer
export KSA_NAME=custom-metrics-stackdriver-adapter
export NAMESPACE=custom-metrics
export PROJECT_ID=kkuchima-sandbox

# Stackdriver Adapter のデプロイ
kubectl apply -f https://raw.githubusercontent.com/GoogleCloudPlatform/k8s-stackdriver/master/custom-metrics-stackdriver-adapter/deploy/production/adapter_new_resource_model.yaml

# Google Cloud サービスアカウント (GSA) の作成
gcloud iam service-accounts create ${GSA_NAME}

# GSA に必要なロールを割り当て
gcloud projects add-iam-policy-binding ${PROJECT_ID} \
    --member "serviceAccount:${GSA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com" \
    --role "roles/viewer"

# GSA と KSA 間でのバインディング
gcloud iam service-accounts add-iam-policy-binding ${GSA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com \
    --role roles/iam.workloadIdentityUser \
    --member "serviceAccount:${PROJECT_ID}.svc.id.goog[${NAMESPACE}/${KSA_NAME}]"

# KSA にアノテーションを付与
kubectl annotate serviceaccount ${KSA_NAME} \
    --namespace ${NAMESPACE} \
    iam.gke.io/gcp-service-account=${GSA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com

# HPA の構成
kubectl apply -f pubsub-hpa.yaml
```

# 負荷掛け
```bash
export MAX_FOR=30
for ((i=0; i < ${MAX_FOR}; i++)); do
    gcloud pubsub topics publish echo --message="hello"
done

$ kubectl get pods -w | grep pubsub                                                                                                                                               ✘ 130 
pubsub-79766ddf44-996wt         1/1     Running   0          73m
pubsub-79766ddf44-l4kbv         1/1     Running   0          2m45s
pubsub-79766ddf44-q84nk         1/1     Running   0          2m45s
pubsub-79766ddf44-rtrj5         1/1     Running   0          2m45s
pubsub-79766ddf44-w7kj7         1/1     Running   0          2m30s
```