#
# --- 1. CONFIGURE PROVIDERS ---
#
terraform {
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 5.16.0" # Service Extensions require a recent provider version
    }
    google-beta = {
      source  = "hashicorp/google-beta"
      version = ">= 5.16.0"
    }
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
}

provider "google-beta" {
  project = var.project_id
  region  = var.region
}

#
# --- VARIABLE DEFINITIONS ---
#
variable "project_id" {
  description = "The GCP project ID to deploy resources into."
  type        = string
}

variable "region" {
  description = "The GCP region for the Cloud Run services and NEGs."
  type        = string
  default     = "us-central1"
}

variable "domain_name" {
  description = "The custom domain name for the load balancer (e.g., myapp.example.com)."
  type        = string
}

variable "main_app_cloud_run_service_name" {
  description = "The name of the Cloud Run service for your main application."
  type        = string
}

variable "grpc_callout_cloud_run_service_name" {
  description = "The name of the Cloud Run service for your gRPC callout server."
  type        = string
}


#
# --- 2. DEFINE MAIN APPLICATION BACKEND ---
# This is where your actual user-facing application runs.
#

# Serverless NEG for the main application Cloud Run service
resource "google_compute_region_network_endpoint_group" "main_app_neg" {
  name                  = "main-app-neg"
  network_endpoint_type = "SERVERLESS"
  region                = var.region
  cloud_run {
    service = var.main_app_cloud_run_service_name
  }
}

# Backend service for the main application
resource "google_compute_backend_service" "main_app_backend" {
  name                            = "main-app-backend-service"
  protocol                        = "HTTP"
  load_balancing_scheme           = "EXTERNAL_MANAGED"
  enable_cdn                      = false # Assuming this is a dynamic app, not a static site
  connection_draining_timeout_sec = 300

  backend {
    group = google_compute_region_network_endpoint_group.main_app_neg.id
  }
}

#
# --- 3. DEFINE GRPC CALLOUT SERVICE BACKEND ---
# This is your gRPC server running on Cloud Run.
#

# Serverless NEG for the gRPC callout Cloud Run service
resource "google_compute_region_network_endpoint_group" "callout_neg" {
  name                  = "grpc-callout-neg"
  network_endpoint_type = "SERVERLESS"
  region                = var.region
  cloud_run {
    service = var.grpc_callout_cloud_run_service_name
  }
}

# Backend service for the gRPC callout service.
# Note: It MUST use HTTP/2.
resource "google_compute_backend_service" "callout_backend" {
  name                  = "grpc-callout-backend-service"
  protocol              = "HTTP2" # Service Extensions require HTTP/2 for gRPC
  load_balancing_scheme = "EXTERNAL_MANAGED"

  backend {
    group = google_compute_region_network_endpoint_group.callout_neg.id
  }

  # Health check is required, but for serverless it's often a formality.
  # Create a basic one.
  health_checks = [google_compute_health_check.grpc_health_check.id]
}

resource "google_compute_health_check" "grpc_health_check" {
  name = "grpc-callout-health-check"
  # For gRPC, a gRPC health check is ideal, but a simple TCP check can also work
  # if your service listens on the port.
  tcp_health_check {
    port = "443" # Cloud Run serves on 443
  }
}


#
# --- 4. CREATE THE SERVICE EXTENSION RESOURCE ---
# This registers your gRPC backend as a "route extension" that intercepts
# traffic on the forwarding rule based on a CEL match.
#
resource "google_network_services_lb_route_extension" "service_extension_callout" {
  provider = google-beta
  name     = "my-grpc-route-extension"
  location = "global" # Extensions for GXLB must be global

  forwarding_rules = [
    google_compute_global_forwarding_rule.default.id
  ]
  load_balancing_scheme = "EXTERNAL_MANAGED"

  extension_chains {
    name = "my-grpc-callout-chain"
    # This CEL expression determines which requests are intercepted and sent to the extension.
    match_condition {
      cel_expression = "request.path.startsWith('/api/')"
    }
    # Defines the steps in the chain. In our case, just one callout.
    extensions {
      name    = "my-callout-step"
      service = google_compute_backend_service.callout_backend.id
      timeout   = "50ms"
      fail_open = false
    }
  }
}


#
# --- 5. CONFIGURE LOAD BALANCER FRONTEND & ROUTING ---
#
resource "google_compute_url_map" "url_map" {
  name            = "gxlb-url-map"
  default_service = google_compute_backend_service.main_app_backend.id

  # This host rule matches all requests to your domain
  host_rule {
    hosts        = [var.domain_name]
    path_matcher = "all-paths"
  }

  # The path matcher is now simplified. The extension logic is no longer here.
  # The LB Route Extension intercepts traffic *before* the URL map logic is fully processed.
  path_matcher {
    name            = "all-paths"
    default_service = google_compute_backend_service.main_app_backend.id
  }
}

# Reserve a global static IP address
resource "google_compute_global_address" "default" {
  name = "gxlb-static-ip"
}

# Managed SSL certificate for your domain
resource "google_compute_managed_ssl_certificate" "default" {
  name    = "ssl-cert-for-gxlb"
  managed {
    domains = [var.domain_name]
  }
}

# Target HTTPS proxy
resource "google_compute_target_https_proxy" "default" {
  name             = "https-proxy"
  url_map          = google_compute_url_map.url_map.id
  ssl_certificates = [google_compute_managed_ssl_certificate.default.id]
}

# Global forwarding rule (the entrypoint)
resource "google_compute_global_forwarding_rule" "default" {
  name                  = "https-forwarding-rule"
  ip_protocol           = "TCP"
  port_range            = "443"
  target                = google_compute_target_https_proxy.default.id
  ip_address            = google_compute_global_address.default.id
  load_balancing_scheme = "EXTERNAL_MANAGED"
}

