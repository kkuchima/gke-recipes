variable "project_id" {
  description = "検証環境を作成する GCP プロジェクト ID（例: my-gcp-project）"
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{4,28}[a-z0-9]$", var.project_id))
    error_message = "有効な GCP プロジェクト ID を指定してください。"
  }
}

variable "region" {
  description = "デプロイ先リージョン（東京 G4 対応リージョン）"
  type        = string
  default     = "asia-northeast1"
}

variable "cluster_location" {
  description = "GKE クラスタのロケーション。短時間での高速起動（約4〜5分）にはゾーン指定（asia-northeast1-b）、本番同等構成にはリージョン指定（asia-northeast1）を使用します。"
  type        = string
  default     = "asia-northeast1-b"
}

variable "name_prefix" {
  description = "クラスタ・Artifact Registry・GCS バケット名に付与するプレフィックス"
  type        = string
  default     = "gpu-batch-verify"
}

variable "network" {
  description = "利用する VPC ネットワーク名"
  type        = string
  default     = "default"
}

variable "subnetwork" {
  description = "利用するサブネットワーク名"
  type        = string
  default     = "default"
}

variable "gke_release_channel" {
  description = "GKE Release Channel（REGULAR で GKE 1.36+ / G4 / CapacityQuota 対応）"
  type        = string
  default     = "REGULAR"
}

variable "enable_dws_queued_pools" {
  description = "Kueue AdmissionCheck + ProvisioningRequest (queued provisioning) 検証用の DWS ノードプール（G4 / L4）を作成するかどうか"
  type        = bool
  default     = true
}

variable "g4_machine_type" {
  description = "G4 (NVIDIA RTX PRO 6000 Blackwell 96GB) ノードのマシンタイプ"
  type        = string
  default     = "g4-standard-48"
}

variable "g4_max_nodes" {
  description = "DWS G4 ノードプールの最大ノード数"
  type        = number
  default     = 2
}

variable "l4_machine_type" {
  description = "L4 (NVIDIA G2) ノードのマシンタイプ。サンドボックス Quota 節約時は g2-standard-8、本番同等検証時は g2-standard-32 を指定"
  type        = string
  default     = "g2-standard-8"
}

variable "l4_max_nodes" {
  description = "DWS L4 マルチゾーンノードプールの最大ノード数"
  type        = number
  default     = 4
}

variable "l4_zones" {
  description = "L4 マルチゾーンフォールバック対象ゾーン一覧"
  type        = list(string)
  default     = ["asia-northeast1-a", "asia-northeast1-b", "asia-northeast1-c"]
}

variable "specific_g4_reservation_name" {
  description = "（任意）Specific Capacity Reservation 名を指定した場合、ComputeClass の最優先（Priority 1）に自動追加します。未指定時はオンデマンド → L4 → DWS flex-start の順となります。"
  type        = string
  default     = ""
}

variable "k8s_namespace" {
  description = "検証ジョブを実行する Kubernetes Namespace 名"
  type        = string
  default     = "batch-verify"
}

variable "k8s_service_account" {
  description = "Direct Workload Identity で GCS 権限を付与する Kubernetes ServiceAccount 名"
  type        = string
  default     = "batch-job-ksa"
}

variable "kueue_version" {
  description = "インストールする Kueue のバージョン（v1beta2 対応の実機検証済みバージョン）"
  type        = string
  default     = "v0.20.6"
}

variable "image_tag" {
  description = "ビルド・デプロイする検証用 JAX コンテナイメージのタグ"
  type        = string
  default     = "v1"
}

variable "auto_bootstrap_workloads" {
  description = "true にすると terraform apply 完了時にローカルの gcloud / kubectl を使って Cloud Build イメージビルド・サンプル画像配置・Kueue 導入・K8s マニフェスト適用まで自動実行します（手動で段階実行したい場合は false のまま scripts/bootstrap.sh を実行）。"
  type        = bool
  default     = false
}
