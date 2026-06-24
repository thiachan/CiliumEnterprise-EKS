# ============================================================================
# Phase 2 (opt-in) — Hubble Timescape (lite)
#
# Gives you a single pane that correlates Hubble *network flows* with Tetragon
# *runtime/process events* over a long retention window (the thing OSS Hubble
# cannot do). Uses LITE + PUSH mode: one all-in-one hubble-timescape pod with an
# embedded ClickHouse; Cilium streams flows straight to its gRPC push API. No
# clickhouse-operator, no object storage, no exporter.
#
# Enterprise images are public on quay.io/isovalent (no pull secret required);
# the pull-secret wiring stays optional for licensed/air-gapped setups.
#
# Gated on var.enable_timescape (default false): off = ZERO plan changes.
# Values verified against hubble-timescape chart 1.18.8.
# ============================================================================

locals {
  ts_count = var.enable_timescape ? 1 : 0

  # Per-component image pull secrets (the chart has no global key).
  ts_pull_secrets = local.create_pull_secret ? [{ name = var.isovalent_pull_secret_name }] : []
}

# --- Namespace + pull secret -------------------------------------------------
resource "kubernetes_namespace" "timescape" {
  count = local.ts_count
  metadata {
    name = var.timescape_namespace
  }
}

resource "kubernetes_secret" "timescape_pull_secret" {
  count = local.ts_count == 1 && local.create_pull_secret ? 1 : 0

  metadata {
    name      = var.isovalent_pull_secret_name
    namespace = kubernetes_namespace.timescape[0].metadata[0].name
  }

  type = "kubernetes.io/dockerconfigjson"

  data = {
    ".dockerconfigjson" = var.isovalent_pull_secret_json
  }
}

# --- Hubble Timescape (lite: single all-in-one pod + embedded ClickHouse) ---
resource "helm_release" "hubble_timescape" {
  count      = local.ts_count
  name       = "hubble-timescape"
  repository = var.isovalent_helm_repo
  chart      = "hubble-timescape"
  version    = var.timescape_version
  namespace  = kubernetes_namespace.timescape[0].metadata[0].name

  wait    = false
  timeout = 600

  values = [yamlencode({
    # Lite mode: one hubble-timescape pod runs ingest + serve + UI with an
    # embedded ClickHouse (no clickhouse-operator). Ideal for small clusters.
    lite = {
      enabled    = true
      image      = { pullSecrets = local.ts_pull_secrets }
      clickhouse = { enabled = true }
    }

    # Push mode: no bucket configured, so the lite pod ingests flows streamed
    # from Cilium over its gRPC push API, exposed via the
    # "hubble-timescape-export" service on port 4260.
    ingester = {
      server = {
        grpc = { enabled = true }
        tls  = { enabled = false }
      }
    }
  })]

  depends_on = [
    helm_release.cilium,
  ]
}
