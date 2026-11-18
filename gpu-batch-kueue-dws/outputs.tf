output "cluster_name" {
  description = "作成された GKE Standard クラスタ名"
  value       = google_container_cluster.batch_verify.name
}

output "cluster_location" {
  description = "GKE クラスタのロケーション"
  value       = google_container_cluster.batch_verify.location
}

output "gcs_bucket_name" {
  description = "センサー画像入力・結果出力用の Cloud Storage バケット名"
  value       = google_storage_bucket.sensor_data.name
}

output "jax_image_uri" {
  description = "Artifact Registry 上の検証用 JAX CUDA 12.9 コンテナイメージ URI"
  value       = local.jax_image_uri
}

output "get_credentials_command" {
  description = "kubectl 認証情報を取得するコマンド"
  value       = "gcloud container clusters get-credentials ${google_container_cluster.batch_verify.name} --location=${google_container_cluster.batch_verify.location} --project=${var.project_id}"
}

output "bootstrap_command" {
  description = "（auto_bootstrap_workloads = false の場合）Kueue 導入・コンテナビルド・マニフェスト適用を一括実行するコマンド"
  value       = "PROJECT_ID=${var.project_id} REGION=${var.region} CLUSTER_NAME=${google_container_cluster.batch_verify.name} CLUSTER_LOCATION=${google_container_cluster.batch_verify.location} BUCKET_NAME=${google_storage_bucket.sensor_data.name} IMAGE_URI=${local.jax_image_uri} KUEUE_VERSION=${var.kueue_version} ENABLE_DWS_POOLS=${var.enable_dws_queued_pools} bash ./scripts/bootstrap.sh"
}

output "demo_commands" {
  description = "そのまま実行できる検証ジョブ投入・確認コマンド集"
  value       = <<-EOT
    # [パターン1: CUD/予約優先 + DWS flex-start ComputeClass 経路のジョブ投入]
    # ※ 1回目: Cold Start 計測 / 完了直後に2回目実行: Warm Node Reuse (約16秒完走) を実演可能
    kubectl create -f generated-manifests/05-job-computeclass.yaml
    kubectl get workloads,jobs,pods -n ${var.k8s_namespace} -w

    # [パターン2: Kueue AdmissionCheck + DWS ProvisioningRequest (queued provisioning) 経路のジョブ投入]
    kubectl create -f generated-manifests/06-job-dws-provreq.yaml
    kubectl describe provisioningrequest -n ${var.k8s_namespace}

    # [完了した Pod の GPU / GCSFuse / emptyDir / AWS OIDC 計測ログ確認]
    kubectl logs -n ${var.k8s_namespace} -l app=sensor-jax-worker -c jax-worker --tail=50
  EOT
}
