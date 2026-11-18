locals {
  manifest_vars = {
    project_id                   = var.project_id
    region                       = var.region
    g4_zone                      = local.g4_zone
    l4_zones                     = var.l4_zones
    g4_machine_type              = var.g4_machine_type
    specific_g4_reservation_name = var.specific_g4_reservation_name
    bucket_name                  = google_storage_bucket.sensor_data.name
    jax_image_uri                = local.jax_image_uri
    k8s_namespace                = var.k8s_namespace
    k8s_service_account          = var.k8s_service_account
  }
}

resource "local_file" "m01_namespace_and_storage" {
  filename        = "${path.module}/generated-manifests/01-namespace-and-storage.yaml"
  file_permission = "0644"
  content         = templatefile("${path.module}/templates/01-namespace-and-storage.yaml.tftpl", local.manifest_vars)
}

resource "local_file" "m02_computeclass_and_quota" {
  filename        = "${path.module}/generated-manifests/02-computeclass-and-capacityquota.yaml"
  file_permission = "0644"
  content         = templatefile("${path.module}/templates/02-computeclass-and-capacityquota.yaml.tftpl", local.manifest_vars)
}

resource "local_file" "m03_kueue_computeclass" {
  filename        = "${path.module}/generated-manifests/03-kueue-computeclass-queue.yaml"
  file_permission = "0644"
  content         = templatefile("${path.module}/templates/03-kueue-computeclass-queue.yaml.tftpl", local.manifest_vars)
}

resource "local_file" "m04_kueue_dws_provreq" {
  filename        = "${path.module}/generated-manifests/04-kueue-dws-provreq.yaml"
  file_permission = "0644"
  content         = templatefile("${path.module}/templates/04-kueue-dws-provreq.yaml.tftpl", local.manifest_vars)
}

resource "local_file" "m05_job_computeclass" {
  filename        = "${path.module}/generated-manifests/05-job-computeclass.yaml"
  file_permission = "0644"
  content         = templatefile("${path.module}/templates/05-job-computeclass.yaml.tftpl", local.manifest_vars)
}

resource "local_file" "m06_job_dws_provreq" {
  filename        = "${path.module}/generated-manifests/06-job-dws-provreq.yaml"
  file_permission = "0644"
  content         = templatefile("${path.module}/templates/06-job-dws-provreq.yaml.tftpl", local.manifest_vars)
}

# auto_bootstrap_workloads = true の場合、Cloud Build・サンプル画像配置・Kueue & K8s リソース適用まで自動実行
resource "terraform_data" "bootstrap_workloads" {
  count = var.auto_bootstrap_workloads ? 1 : 0

  triggers_replace = [
    google_container_cluster.batch_verify.id,
    local.jax_image_uri,
    var.kueue_version,
  ]

  provisioner "local-exec" {
    working_dir = path.module
    environment = {
      PROJECT_ID       = var.project_id
      REGION           = var.region
      CLUSTER_NAME     = google_container_cluster.batch_verify.name
      CLUSTER_LOCATION = google_container_cluster.batch_verify.location
      BUCKET_NAME      = google_storage_bucket.sensor_data.name
      IMAGE_URI        = local.jax_image_uri
      KUEUE_VERSION    = var.kueue_version
      ENABLE_DWS_POOLS = tostring(var.enable_dws_queued_pools)
    }
    command = "bash ./scripts/bootstrap.sh"
  }

  depends_on = [
    google_container_node_pool.system_cpu_pool,
    google_container_node_pool.dws_g4_queued_pool,
    google_container_node_pool.dws_l4_queued_pool,
    google_storage_bucket_iam_member.batch_ksa_gcs_access,
    local_file.m01_namespace_and_storage,
    local_file.m02_computeclass_and_quota,
    local_file.m03_kueue_computeclass,
    local_file.m04_kueue_dws_provreq,
    local_file.m05_job_computeclass,
    local_file.m06_job_dws_provreq,
  ]
}
