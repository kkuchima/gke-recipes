locals {
  required_apis = toset([
    "cloudresourcemanager.googleapis.com",
    "compute.googleapis.com",
    "container.googleapis.com",
    "artifactregistry.googleapis.com",
    "storage.googleapis.com",
    "cloudbuild.googleapis.com",
    "iam.googleapis.com",
    "monitoring.googleapis.com",
    "logging.googleapis.com",
  ])

  bucket_name     = "${var.project_id}-${var.name_prefix}-data"
  jax_image_uri   = "${var.region}-docker.pkg.dev/${var.project_id}/${google_artifact_registry_repository.jax_repo.repository_id}/jax-sensor-job:${var.image_tag}"
  is_zonal        = length(split("-", var.cluster_location)) == 3
  g4_zone         = "${var.region}-b"
}

resource "google_project_service" "apis" {
  for_each           = local.required_apis
  project            = var.project_id
  service            = each.value
  disable_on_destroy = false
}

data "google_project" "current" {
  project_id = var.project_id
  depends_on = [google_project_service.apis]
}

# センサー画像入力・解析結果出力用 Cloud Storage バケット
resource "google_storage_bucket" "sensor_data" {
  name                        = local.bucket_name
  location                    = var.region
  storage_class               = "STANDARD"
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"
  force_destroy               = true

  depends_on = [google_project_service.apis]
}

# Direct Workload Identity Federation for GKE（GSA 作成・鍵発行なしで KSA に直接権限付与）
resource "google_storage_bucket_iam_member" "batch_ksa_gcs_access" {
  bucket = google_storage_bucket.sensor_data.name
  role   = "roles/storage.objectUser"
  member = "principal://iam.googleapis.com/projects/${data.google_project.current.number}/locations/global/workloadIdentityPools/${var.project_id}.svc.id.goog/subject/ns/${var.k8s_namespace}/sa/${var.k8s_service_account}"

  depends_on = [google_container_cluster.batch_verify]
}

# JAX CUDA 12.9 コンテナ格納用 Artifact Registry
resource "google_artifact_registry_repository" "jax_repo" {
  location      = var.region
  repository_id = var.name_prefix
  description   = "GKE GPU batch verification container images (CUDA 12.9 JAX for G4 Blackwell & L4)"
  format        = "DOCKER"

  depends_on = [google_project_service.apis]
}
