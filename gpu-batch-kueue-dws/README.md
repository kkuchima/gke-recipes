# GKE GPU バッチ実行基盤 検証・ハンズオン用 Terraform 一式

GKE Standard 上で **CUD / キャパシティ予約優先の Custom `ComputeClass`（＋ DWS `flex-start` フォールバック）** と **Kueue (`v1beta2`) ＋ DWS `ProvisioningRequest` (`queued provisioning`)** の双方をすぐに再現・検証できる Terraform コードです。

## ディレクトリ構成

```text
gpu-batch-kueue-dws/
├── versions.tf                  # Terraform / Google Provider バージョン定義
├── variables.tf                 # プロジェクト ID・ロケーション・GPU プール設定等の変数
├── terraform.tfvars.example     # 設定テンプレート
├── main.tf                      # API 有効化・GCS バケット・Direct WIF IAM・Artifact Registry
├── gke.tf                       # GKE Standard クラスタ・CPU プール・DWS (G4 / L4) ノードプール
├── manifests.tf                 # 環境値埋め込み済み K8s YAML 生成 (generated-manifests/)
├── outputs.tf                   # 接続・ビルド・デモ投入コマンド出力
├── templates/                   # K8s マニフェストテンプレート (.tftpl)
├── app/                         # 実機検証済み CUDA 12.9 JAX (G4 sm_120 / L4 sm_89 両対応) コンテナ
└── scripts/
    └── bootstrap.sh             # サンプル画像配置・Cloud Build・Kueue (v0.20.6) ＆ K8s マニフェスト一括適用
```

---

## 1. 環境構築手順（約 8〜10 分）

### Step 1: 変数ファイルの作成とインフラ構築

```bash
cd gpu-batch-kueue-dws
cp terraform.tfvars.example terraform.tfvars
# 必要に応じて terraform.tfvars の project_id 等を編集

terraform init
terraform apply
```

> **Tips**: `terraform.tfvars` で `auto_bootstrap_workloads = true` に設定すると、`terraform apply` の中で下記 Step 2（Cloud Build によるイメージ作成・Kueue インストール・K8s マニフェスト適用）まで一気通貫で自動実行されます。段階的に進めたい場合はデフォルト (`false`) のまま Step 2 を実行してください。

### Step 2: コンテナビルド・Kueue (`v1beta2`)・マニフェストの一括セットアップ

`terraform apply` 完了後、`generated-manifests/` 配下にプロジェクト ID・バケット名・イメージ URI が自動反映された YAML が生成されます。以下のスクリプトで一括セットアップします。

```bash
eval "$(terraform output -raw bootstrap_command)"
```

---

## 2. 動作確認・デモ手順

生成される Job マニフェストは `generateName` を使っているため、**Job を削除しなくても同じコマンドを連続実行**して「初回コールドスタート」と「2回目の Warm ノード再利用」を比較実演できます。

### シナリオ A: 本番推奨 `ComputeClass` 経路（予約/オンデマンド優先 ➔ L4 3ゾーン ➔ DWS `flex-start`）

```bash
# 1 回目投入（Cold Start: ノードプール自動生成 + VM 起動 + R580 ドライバ導入）
kubectl create -f generated-manifests/05-job-computeclass.yaml

# Kueue Admit 状況・Pod 起動・自動生成されたノードの確認
kubectl get workloads,jobs,pods -n batch-verify -w
kubectl get nodes -l cloud.google.com/gke-gpu=true \
  -o custom-columns="NODE:.metadata.name,ZONE:.metadata.labels.topology\.kubernetes\.io/zone,TYPE:.metadata.labels.node\.kubernetes\.io/instance-type,DRIVER:.metadata.annotations.cloud\.google\.com/cuda\.driver-version\.full"

# 1 回目完了直後に 2 回目を投入 ➔ Warm ノード再利用により約 16 秒で即完走することを実演！
kubectl create -f generated-manifests/05-job-computeclass.yaml
```

### シナリオ B: DWS 明示検証 `ProvisioningRequest` (`queued provisioning`) 経路

```bash
# Kueue AdmissionCheck 経由で ProvisioningRequest を発行（G4 -> L4 ResourceFlavor フォールバック）
kubectl create -f generated-manifests/06-job-dws-provreq.yaml

# DWS キュー待機状況・在庫切れ時の理由 (SuccessfullyQueued / ResourcePoolExhausted 等) を確認
kubectl get provisioningrequest -n batch-verify
kubectl describe provisioningrequest -n batch-verify
```

### E2E 検証ログと GCS 出力結果の確認

1 つの Job 実行の中で **① `nvidia-smi` (R580 ドライバ)、② JAX GPU 認識 & `@jax.jit` (2D FFT + 行列積)、③ `emptyDir` (`/instrumentation`) 読み書き、④ AWS `AssumeRoleWithWebIdentity` 用 OIDC トークン投影、⑤ Cloud Storage FUSE サイドカー経由の画像読込 & 結果書込** がすべて構造化 JSON ログとして出力されます。

```bash
kubectl logs -n batch-verify -l app=sensor-jax-worker -c jax-worker --tail=50
gcloud storage ls -l "gs://$(terraform output -raw gcs_bucket_name)/output/"
```

---

## 3. 検証終了後のクリーンアップ

クラスタの `deletion_protection = false` および GCS バケットの `force_destroy = true` を設定済みのため、1 コマンドですべての課金リソースを完全削除できます。

```bash
# ComputeClass が自動生成したノードプールが残っている場合も GKE クラスタ削除と同時に自動破棄されます
terraform destroy
```
