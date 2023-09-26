/**
 * Copyright 2023 Google LLC
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *      http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

locals {
  spanner_instance_name         = "gke-spanner-instance"
  spanner_instance_display_name = "gke-spanner-example"
  spanner_configuration         = "regional-us-central1"
  gke_cluster_name              = "simple-autopilot-cluster"
  gke_region                    = "us-central1"
  network_name                  = "simple-autopilot-private-network"
  subnet_name                   = "simple-autopilot-private-subnet"
  master_auth_subnetwork        = "simple-autopilot-private-master-subnet"
  pods_range_name               = "ip-range-pods-simple-autopilot-private"
  svc_range_name                = "ip-range-svc-simple-autopilot-private"
  subnet_names                  = [for subnet_self_link in module.gcp-network.subnets_self_links : split("/", subnet_self_link)[length(split("/", subnet_self_link)) - 1]]
}

data "google_client_config" "default" {}

provider "kubernetes" {
  host                   = "https://${module.gke.endpoint}"
  token                  = data.google_client_config.default.access_token
  cluster_ca_certificate = base64decode(module.gke.ca_certificate)
}

module "cloud_spanner" {
  source                = "../.."
  project_id            = var.project_id
  instance_name         = local.spanner_instance_name
  instance_display_name = local.spanner_instance_display_name
  instance_config       = local.spanner_configuration
  instance_size = {
    # num_nodes = 2
    processing_units = 200
  }
  instance_labels = {}
  instance_iam    = []
  database_config = {
    gkedb1 = {
      version_retention_period = "3d"
      ddl = [
        "CREATE TABLE t1 (t1 INT64 NOT NULL,) PRIMARY KEY(t1)",
        "CREATE TABLE t2 (t2 INT64 NOT NULL,) PRIMARY KEY(t2)"
      ]
      deletion_protection = false
      database_iam        = []
      enable_backup       = true
      backup_retention    = 86400
      create_db           = true
    }
  }
  backup_schedule = "0 6 * * *"
}

module "gcp-network" {
  source  = "terraform-google-modules/network/google"
  version = ">= 4.0.1"

  project_id   = var.project_id
  network_name = local.network_name

  subnets = [
    {
      subnet_name   = local.subnet_name
      subnet_ip     = "10.0.0.0/17"
      subnet_region = local.gke_region
    },
    {
      subnet_name   = local.master_auth_subnetwork
      subnet_ip     = "10.60.0.0/17"
      subnet_region = local.gke_region
    },
  ]

  secondary_ranges = {
    (local.subnet_name) = [
      {
        range_name    = local.pods_range_name
        ip_cidr_range = "192.168.0.0/18"
      },
      {
        range_name    = local.svc_range_name
        ip_cidr_range = "192.168.64.0/18"
      },
    ]
  }
}

module "gke" {
  source                          = "terraform-google-modules/kubernetes-engine/google//modules/beta-autopilot-private-cluster"
  version                         = "28.0.0"
  project_id                      = var.project_id
  name                            = local.gke_cluster_name
  regional                        = true
  region                          = local.gke_region
  network                         = module.gcp-network.network_name
  subnetwork                      = local.subnet_names[index(module.gcp-network.subnets_names, local.subnet_name)]
  ip_range_pods                   = local.pods_range_name
  ip_range_services               = local.svc_range_name
  release_channel                 = "REGULAR"
  enable_vertical_pod_autoscaling = true
  enable_private_endpoint         = true
  enable_private_nodes            = true
  master_ipv4_cidr_block          = "172.16.0.0/28"
  network_tags                    = [local.gke_cluster_name]

  master_authorized_networks = [
    {
      cidr_block   = "10.60.0.0/17"
      display_name = "VPC"
    },
  ]
}
