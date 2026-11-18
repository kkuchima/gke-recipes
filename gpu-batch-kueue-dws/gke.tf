# ==============================================================================
# GKE Standard クラスタ本体
# - Custom ComputeClass (nodePoolAutoCreation: true) を管理プレミアム $0 で利用可能
# - Cloud Storage FUSE CSI Driver / Workload Identity / Managed Prometheus / Cost Allocation 有効
# ==============================================================================
resource "google_container_cluster" "batch_verify" {
  provider = google-beta

  name     = var.name_prefix
  location = var.cluster_location

  network    = var.network
  subnetwork = var.subnetwork

  remove_default_node_pool = true
  initial_node_count       = 1

  # 検証終了後に terraform destroy で即座に削除可能にする設定
  deletion_protection = false

  release_channel {
    channel = var.gke_release_channel
  }

  workload_identity_config {
    workload_pool = "${var.project_id}.svc.id.goog"
  }

  addons_config {
    gcs_fuse_csi_driver_config {
      enabled = true
    }
    http_load_balancing {
      disabled = false
    }
    horizontal_pod_autoscaling {
      disabled = false
    }
  }

  monitoring_config {
    managed_prometheus {
      enabled = true
    }
  }

  cost_management_config {
    enabled = true
  }

  depends_on = [google_project_service.apis]
}

# ==============================================================================
# 常駐コントロール系（Kueue Controller 等）用 CPU システムノードプール
# ==============================================================================
resource "google_container_node_pool" "system_cpu_pool" {
  provider = google-beta

  name     = "system-cpu-pool"
  cluster  = google_container_cluster.batch_verify.name
  location = var.cluster_location

  initial_node_count = local.is_zonal ? 2 : 1

  autoscaling {
    total_min_node_count = 2
    total_max_node_count = 4
    location_policy      = "BALANCED"
  }

  node_config {
    machine_type = "e2-standard-4"
    image_type   = "COS_CONTAINERD"
    disk_type    = "pd-balanced"
    disk_size_gb = 100

    # Artifact Registry Image Streaming 有効化
    gcfs_config {
      enabled = true
    }

    workload_metadata_config {
      mode = "GKE_METADATA"
    }

    oauth_scopes = [
      "https://www.googleapis.com/auth/cloud-platform",
    ]
  }
}

# ==============================================================================
# DWS queued provisioning (ProvisioningRequest) 検証用 G4 ノードプール (0スケール待機)
# ※ 東京リージョンの G4 は asia-northeast1-b 限定 + hyperdisk-balanced 必須
# ==============================================================================
resource "google_container_node_pool" "dws_g4_queued_pool" {
  provider = google-beta
  count    = var.enable_dws_queued_pools ? 1 : 0

  name           = "dws-g4-queued-pool"
  cluster        = google_container_cluster.batch_verify.name
  location       = var.cluster_location
  node_locations = [local.g4_zone]

  initial_node_count = 0

  queued_provisioning {
    enabled = true
  }

  autoscaling {
    total_min_node_count = 0
    total_max_node_count = var.g4_max_nodes
    location_policy      = "ANY"
  }

  management {
    auto_repair  = false
    auto_upgrade = true
  }

  node_config {
    machine_type = var.g4_machine_type
    image_type   = "COS_CONTAINERD"
    disk_type    = "hyperdisk-balanced"
    disk_size_gb = 100
    flex_start   = true

    ephemeral_storage_local_ssd_config {
      local_ssd_count = 4
    }

    reservation_affinity {
      consume_reservation_type = "NO_RESERVATION"
    }

    gcfs_config {
      enabled = true
    }

    workload_metadata_config {
      mode = "GKE_METADATA"
    }

    guest_accelerator {
      type  = "nvidia-rtx-pro-6000"
      count = 1
      gpu_driver_installation_config {
        gpu_driver_version = "LATEST"
      }
    }

    oauth_scopes = [
      "https://www.googleapis.com/auth/cloud-platform",
    ]
  }
}

# ==============================================================================
# DWS queued provisioning (ProvisioningRequest) 検証用 L4 マルチゾーンノードプール (0スケール待機)
# ※ G2 では local_ssd_count ではなく標準 pd-balanced を使用
# ==============================================================================
resource "google_container_node_pool" "dws_l4_queued_pool" {
  provider = google-beta
  count    = var.enable_dws_queued_pools ? 1 : 0

  name           = "dws-l4-queued-pool"
  cluster        = google_container_cluster.batch_verify.name
  location       = var.cluster_location
  node_locations = var.l4_zones

  initial_node_count = 0

  queued_provisioning {
    enabled = true
  }

  autoscaling {
    total_min_node_count = 0
    total_max_node_count = var.l4_max_nodes
    location_policy      = "ANY"
  }

  management {
    auto_repair  = false
    auto_upgrade = true
  }

  node_config {
    machine_type = var.l4_machine_type
    image_type   = "COS_CONTAINERD"
    disk_type    = "pd-balanced"
    disk_size_gb = 100
    flex_start   = true

    reservation_affinity {
      consume_reservation_type = "NO_RESERVATION"
    }

    gcfs_config {
      enabled = true
    }

    workload_metadata_config {
      mode = "GKE_METADATA"
    }

    guest_accelerator {
      type  = "nvidia-l4"
      count = 1
      gpu_driver_installation_config {
        gpu_driver_version = "LATEST"
      }
    }

    oauth_scopes = [
      "https://www.googleapis.com/auth/cloud-platform",
    ]
  }
}
