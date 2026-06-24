# OCP VERIFICATION — Manual, Line-by-Line Runbook

Post-install verification of **Cilium**, **Tetragon**, and **Hubble Timescape** on a
**greenfield OpenShift (OCP)** cluster built via `console.redhat.com/openshift`, using
**CLI access only** (`oc`).

Run every command **in order**, read the expected result under each, and stop if a check
fails — the [Troubleshooting](#section-9--troubleshooting) section maps each failure to a fix.

> Conventions
> - `$` = a command you type. Lines without `$` are example output.
> - Replace `<...>` placeholders with values discovered in Section 1.
> - `oc` is used throughout; `kubectl` works too. Cilium/Hubble CLIs are optional but useful.
> - **Timescape and the Enterprise Hubble UI require the Isovalent Enterprise license/pull
>   secret** to have been configured during the operator install.

---

## Section M — Migration Paths (how you get Cilium onto OCP)

Installing **Isovalent Networking for Kubernetes** from OperatorHub only deploys the
*operator/controller*. It does **not** change the CNI — OVN-Kubernetes is still the datapath
until you act. On OCP the CNI is owned by the **Cluster Network Operator (CNO)**, which is
managed by the CVO, so `network.config/cluster → spec.networkType` is effectively an
install-/migration-time decision. Two supported paths exist; the OCP owner chooses.

| | Option A — Greenfield reinstall | Option B — In-place migration |
|---|---|---|
| Best when | Cluster is disposable (no apps) | Cluster cannot be rebuilt |
| Risk | Low | High (live CNI swap) |
| Downtime | Full (one rebuild) | Rolling node reboots |
| Red Hat support | Strongest (certified greenfield) | **Migration itself is unsupported by Red Hat** — Isovalent supports it; engage both account teams first |

> **Warning (from the Isovalent guide):** Isovalent Networking for Kubernetes is a fully
> certified network plugin for OCP, **but Red Hat provides no support for migrating an active
> existing cluster**. Contact your Red Hat account team and Isovalent support before
> proceeding, test in a dev environment first, and expect downtime (nodes reboot, pods
> restart). Assumes a healthy cluster: all nodes Ready, no ClusterOperators Degraded.

---

### Option A — Greenfield reinstall (Cilium as primary CNI from day 0)

Cleanest, fully supported. Recommended when nothing is running.

```bash
# A1  Generate install assets (do NOT create the cluster yet)
$ openshift-install create install-config --dir ocp-cilium
#     edit install-config.yaml -> networking.networkType: Cilium
$ openshift-install create manifests --dir ocp-cilium

# A2  Inject the certified Isovalent OLM bundle into manifests/ BEFORE bootstrap:
#       cluster-network-03-cilium-namespace.yaml
#       cluster-network-04-cilium-operatorgroup.yaml
#       cluster-network-05-cilium-subscription.yaml   # pin channel + startingCSV to ONE version
#       cluster-network-06-ciliumconfig.yaml          # CiliumConfig (see Option B CR for fields)
#     and confirm in cluster-network-02-config.yml:
#       spec:
#         networkType: Cilium

# A3  Build
$ openshift-install create cluster --dir ocp-cilium
```

CNO hands the datapath to Cilium at bootstrap. Then run **Sections 2–8** below to verify.
Use IPAM `cluster-pool`, overlay routing (VXLAN), and `kubeProxyReplacement: true`. The
`CiliumConfig` fields are the same as Option B below (without the migration-only `devices`
override).

---

### Option B — In-place OVN-Kubernetes → Cilium migration

Faithful to the Isovalent certified procedure. Overlay model, kube-proxy replacement enabled.
**Incurs downtime.** Run every step in order.

```bash
# B0  Pre-flight: confirm healthy starting state
$ oc get network.config/cluster -o jsonpath='{.spec.networkType}{"\n"}'   # OVNKubernetes
$ oc get co                                                               # none Degraded
$ oc get nodes                                                            # all Ready
```

**B1 — Disable the Cluster Network Operator (CNO)**

```bash
# Create cno-disable.yaml so the CVO stops managing the network-operator:
$ cat > cno-disable.yaml <<'EOF'
- op: add
  path: /spec/overrides
  value:
  - kind: Deployment
    group: apps
    name: network-operator
    namespace: openshift-network-operator
    unmanaged: true
EOF
$ oc patch clusterversion version --type json --patch-file cno-disable.yaml

# Scale the operator to zero and confirm no pods remain:
$ oc scale deployment -n openshift-network-operator network-operator --replicas=0
$ oc get pods -n openshift-network-operator

# Remove the initial-deploy state file:
$ oc delete configmap applied-cluster -n openshift-network-operator
```

**B2 — Pause the Machine Config Pools (prevent premature reboots)**

```bash
$ oc patch --type=merge --patch='{"spec":{"paused":true}}' mcp/master
$ oc patch --type=merge --patch='{"spec":{"paused":true}}' mcp/worker
```

**B3 — Point the cluster network at Cilium**

> The Cilium CIDR must NOT overlap the existing OVN-Kubernetes network. Example: `10.253.0.0/16`.

```bash
$ oc patch network.config cluster --type=merge \
  --patch='{"spec":{"clusterNetwork":[{"cidr":"10.253.0.0/16","hostPrefix":24}],"networkType":"Cilium"},"status":null}'

$ oc patch network.operator cluster --type=merge \
  --patch='{"spec":{"clusterNetwork":[{"cidr":"10.253.0.0/16","hostPrefix":24}],"defaultNetwork":{"type":"Cilium"},"deployKubeProxy":false},"status":null}'
```

**B4 — Configure and apply the Isovalent (clife) manifests**

```bash
$ mkdir clife && tar -xzvf /path/to/clife-v1.x.y.tar.gz -C clife && cd clife
```

Edit `ciliumconfig.yaml`:
- set `clusterPoolIPv4PodCIDRList` to your chosen CIDR (`10.253.0.0/16`),
- set `k8sServiceHost`/`k8sServicePort` to the **internal** API server (`api-int.<cluster>.<base-domain>` : `<port>`),
- for IPI/openvswitch clusters set `devices: "br-ex,ens5"` (br-ex = OVN bridge, ens5 = the device Cilium uses post-reboot),
- set `tunnelPort: 4789` (OCP default VXLAN) **or** open 8472 in the cluster firewall.

```yaml
apiVersion: cilium.io/v1alpha1
kind: CiliumConfig
metadata:
  name: cilium-enterprise
  namespace: cilium
spec:
  securityContext: {privileged: true}
  ipam:
    mode: "cluster-pool"
    operator:
      clusterPoolIPv4PodCIDRList: ["10.253.0.0/16"]
      clusterPoolIPv4MaskSize: 24
  cni:
    binPath: "/var/lib/cni/bin"
    confPath: "/var/run/multus/cni/net.d"
    exclusive: false
  kubeProxyReplacement: "true"
  k8sServiceHost: "api-int.openshift1.example.com"
  k8sServicePort: 8443
  hubble:
    enabled: true
    serviceMonitor: {enabled: true}
    metrics:
      enabled:
      - dns:labelsContext=source_namespace,destination_namespace
      - drop:labelsContext=source_namespace,destination_namespace
      - tcp:labelsContext=source_namespace,destination_namespace
      - icmp:labelsContext=source_namespace,destination_namespace
      - flow:labelsContext=source_namespace,destination_namespace;sourceContext=workload-name|reserved-identity;destinationContext=workload-name|reserved-identity
      - "httpV2:exemplars=true;labelsContext=source_ip,source_namespace,source_workload,destination_ip,destination_namespace,destination_workload,traffic_direction;sourceContext=workload-name|reserved-identity;destinationContext=workload-name|reserved-identity"
      - flow_export
  prometheus: {enabled: true, serviceMonitor: {enabled: true}}
  operator:
    prometheus: {enabled: true}
    serviceMonitor: {enabled: true}
  devices: "br-ex,ens5"
  tunnelPort: 4789
```

Add the server details to `apps_v1_deployment_clife-controller-manager.yaml` under `env`:

```yaml
env:
  - name: WATCH_NAMESPACE
    valueFrom: {fieldRef: {fieldPath: metadata.namespace}}
  - name: KUBERNETES_SERVICE_HOST
    value: "api-int.openshift1.example.com"
  - name: KUBERNETES_SERVICE_PORT
    value: "8443"
```

Apply (retry until the CRDs register), then repoint Multus from OVN to Cilium:

```bash
$ until oc apply -f /path/to/clife/; do sleep 1; done

$ KUBE_EDITOR="sed -i s;host/run/multus/cni/net.d/10-ovn-kubernetes.conf;host/run/multus/cni/net.d/05-cilium.conflist;" \
    oc edit cm -n openshift-multus multus-daemon-config
$ oc rollout restart -n openshift-multus ds/multus

# Wait for Cilium to fully roll out before continuing:
$ oc get ds -n cilium cilium
$ oc get pods -n cilium -l k8s-app=cilium
```

**B5 — Re-enable OpenShift operator management**

```bash
$ oc delete pod -n openshift-kube-apiserver -l apiserver=true
$ oc -n openshift-machine-config-operator rollout restart deploy/machine-config-controller
$ oc -n openshift-machine-config-operator rollout restart deploy/machine-config-operator

$ oc scale deployment -n openshift-network-operator network-operator --replicas=1
$ oc patch clusterversions version --type=merge --patch '{"spec":{"overrides":null}}'
```

**B6 — Reboot nodes (unpause the MCPs)**

> This immediately begins cordoning/draining and rebooting nodes. The cluster is degraded
> until all nodes return. Unpause pools in sequence to reduce impact.

```bash
$ oc patch --type=merge --patch='{"spec":{"paused":false}}' mcp/master
$ oc patch --type=merge --patch='{"spec":{"paused":false}}' mcp/worker

# If a node stalls, evictions may be blocked by tolerations/PDBs — inspect:
$ oc logs -n openshift-machine-config-operator -l k8s-app=machine-config-controller -f
```

**B7 — Post-migration cleanup**

```bash
# After all nodes are Ready and ClusterOperators healthy, drop the device override
# so Cilium auto-detects non-openvswitch devices:
$ sed -i "s/br-ex,ens5//" /path/to/clife/ciliumconfig.yaml
$ oc apply -f /path/to/clife
$ oc -n cilium rollout restart ds/cilium
$ oc get pods -n cilium -l k8s-app=cilium       # confirm healthy

# Finally, remove the old OVN-Kubernetes namespace:
$ oc delete namespace openshift-ovn-kubernetes
```

Then proceed to **Sections 2–8** to validate the datapath, Hubble, Tetragon, and Timescape.

---

## Section 0 — Prerequisites (one-time, on the engineer's workstation)

```bash
# 0.1  Confirm the OpenShift CLI is installed
$ oc version --client
# Expect: Client Version: 4.x.x

# 0.2  (Optional but recommended) install the Cilium + Hubble CLIs
$ brew install cilium-cli hubble        # macOS
# or download from https://github.com/cilium/cilium-cli/releases (Linux)

# 0.3  Confirm those clients
$ cilium version
$ hubble version
```

---

## Section 1 — Log in and discover namespaces

```bash
# 1.1  Log in to the cluster (token or user/pass from the OCP console -> "Copy login command")
$ oc login --token=<sha256~...> --server=https://api.<cluster-domain>:6443
# Expect: "Login successful." and a current project line.

# 1.2  Confirm you are talking to the right cluster and are cluster-admin
$ oc whoami
$ oc whoami --show-server
$ oc auth can-i '*' '*' --all-namespaces
# Expect: yes   (you need cluster-admin to inspect cilium/kube-system, etc.)

# 1.3  Confirm overall cluster health BEFORE checking the CNI
$ oc get clusterversion
# Expect: Available=True, Progressing=False, no Degraded.

$ oc get co
# Expect: every ClusterOperator AVAILABLE=True, DEGRADED=False.
# Pay special attention to the "network" operator:
$ oc get co network

# 1.4  Discover exactly where the Isovalent components live (namespaces vary by install)
$ oc get pods -A | grep -Ei 'cilium|tetragon|hubble|timescape|clickhouse'
# Note the NAMESPACE column. Common results:
#   cilium / cilium-operator      -> namespace: cilium  (or kube-system)
#   tetragon                      -> namespace: kube-system (or isovalent)
#   hubble-timescape / clickhouse -> namespace: hubble-timescape (or isovalent)

# 1.5  Save those namespaces as shell variables for the rest of this runbook
$ CILIUM_NS=cilium
$ TETRA_NS=kube-system
$ TS_NS=hubble-timescape
# Adjust the values above to match what step 1.4 actually showed.
```

---

## Section 2 — Verify Cilium is the CNI

```bash
# 2.1  OpenShift must report Cilium as the network type
$ oc get network.config/cluster -o jsonpath='{.spec.networkType}{"\n"}'
# Expect: Cilium

# 2.2  The Cilium operator and per-node agents are running
$ oc -n $CILIUM_NS get pods -o wide
# Expect: cilium-<id> Running on EVERY worker/master node (DaemonSet),
#         cilium-operator Running (1-2 replicas).

# 2.3  One CiliumNode object per cluster node
$ oc get ciliumnodes
# Expect: a row for every node listed by `oc get nodes`.

# 2.4  All nodes Ready
$ oc get nodes
# Expect: every node STATUS=Ready.

# 2.5  No pods stuck without networking
$ oc get pods -A -o wide | grep -Ev 'Running|Completed' | grep -v NAMESPACE
# Expect: empty output (no ContainerCreating/CrashLoop due to CNI).
```

---

## Section 3 — Cilium health and datapath features

```bash
# 3.1  High-level status via the Cilium CLI
$ cilium status --namespace $CILIUM_NS
# Expect: Cilium: OK, Operator: OK, Hubble Relay: OK (if enabled),
#         DaemonSet cilium Ready: N/N.

# 3.2  Detailed agent status (pick any cilium pod) — confirm key features
$ oc -n $CILIUM_NS exec ds/cilium -c cilium-agent -- cilium-dbg status \
    | grep -E 'KubeProxyReplacement|Encryption|IPAM|Routing|Cluster health'
# Expect (typical OCP greenfield):
#   KubeProxyReplacement:   True
#   Encryption:             Wireguard (or IPsec) ... Enabled   [if you enabled it]
#   IPAM:                   ... (cluster-pool on-prem)
#   Cluster health:         N/N reachable

# 3.3  Endpoint list on a node (sanity that workloads have identities)
$ oc -n $CILIUM_NS exec ds/cilium -c cilium-agent -- cilium-dbg endpoint list | head
# Expect: rows with ready state and security identities.

# 3.4  Service load-balancing table (proves kube-proxy replacement is doing the work)
$ oc -n $CILIUM_NS exec ds/cilium -c cilium-agent -- cilium-dbg service list | head
# Expect: ClusterIP/NodePort services listed with backends.

# 3.5  Full connectivity test (creates a test namespace, runs ~all paths, cleans up)
$ cilium connectivity test --namespace $CILIUM_NS
# Expect: "All <N> tests (<M> actions) successful". Takes several minutes.
# NOTE: on OpenShift this creates a temporary namespace; SCCs must allow it.
```

---

## Section 4 — Verify Hubble (live observability)

```bash
# 4.1  Hubble relay reachable
$ cilium hubble port-forward --namespace $CILIUM_NS &
$ hubble status
# Expect: "Healthy", with a flows/s rate and connected peers = number of nodes.

# 4.2  Live flows are visible
$ hubble observe --follow --first 20
# Expect: a stream of FORWARDED flows with source/destination identities.

# 4.3  L7 visibility (if any L7 policy/visibility is configured)
$ hubble observe --protocol http --follow --first 10
# Expect: http-request/response lines with method, path, and status.

# 4.4  Stop the port-forward when done
$ kill %1 2>/dev/null
```

---

## Section 5 — Verify Tetragon (runtime security)

```bash
# 5.1  Tetragon agents running on every node
$ oc -n $TETRA_NS get pods -l app.kubernetes.io/name=tetragon -o wide
# Expect: tetragon-<id> Running on each node (2/2 containers ready).

# 5.2  Tetragon DaemonSet fully rolled out
$ oc -n $TETRA_NS get ds tetragon
# Expect: DESIRED == READY == AVAILABLE.

# 5.3  Tracing policies are loaded
$ oc get tracingpolicies
$ oc get tracingpoliciesnamespaced -A
# Expect: at least the policies you installed; STATE/columns without errors.

# 5.4  Stream live runtime events
$ oc -n $TETRA_NS exec -it ds/tetragon -c tetragon -- tetra getevents -o compact
# Leave this running. You should see process_exec/process_exit events from normal activity.

# 5.5  Trigger an event in another terminal to prove capture
#      (pick any running app pod and namespace)
$ oc -n <app-ns> exec deploy/<app> -- cat /etc/passwd > /dev/null
# Back in the 5.4 stream: expect a file/exec event referencing /etc/passwd.

# 5.6  (If enforcement policies exist) confirm a blocked action is killed
$ oc -n <app-ns> exec deploy/<app> -- cat /etc/shadow
# Expect (only if a Sigkill TracingPolicy targets /etc/shadow):
#   command terminated with exit code 137
```

---

## Section 6 — Verify Hubble Timescape (historical observability, Enterprise)

> The `quay.io/isovalent` images are public — **no pull secret is required**; an Enterprise
> licence only unlocks gated features. The steps below cover the **full** deployment
> (separate ingester/server/UI + ClickHouse + object storage). For small clusters, Timescape
> **lite mode** collapses all of this into a single pod with embedded ClickHouse and no
> object storage (push target service `hubble-timescape-export:4260`).

```bash
# 6.1  Timescape component pods are running (ingester, server, UI backend, ClickHouse)
$ oc -n $TS_NS get pods
# Expect: hubble-timescape-ingester, hubble-timescape-server,
#         clickhouse-* all Running/Ready. None CrashLoopBackOff.

# 6.2  ClickHouse storage backend is healthy
$ oc -n $TS_NS get pods -l app.kubernetes.io/name=clickhouse
$ oc -n $TS_NS get pvc
# Expect: ClickHouse pod Ready; PVCs Bound.

# 6.3  Ingester is consuming flows and writing to object storage (no errors/backlog)
$ oc -n $TS_NS logs deploy/hubble-timescape-ingester --tail=80
# Expect: lines showing files ingested / flows written. 
# RED FLAGS: "access denied", "NoSuchBucket", "connection refused",
#            TLS/cert errors, or a growing backlog -> object-storage/credentials issue.

# 6.4  Timescape server (query API) is healthy
$ oc -n $TS_NS logs deploy/hubble-timescape-server --tail=50
# Expect: server started, listening, no repeated query errors.

# 6.5  Confirm object-storage connectivity config exists (S3/Blob/GCS/MinIO)
$ oc -n $TS_NS get secret | grep -Ei 'timescape|object|s3|storage'
$ oc -n $TS_NS get cm  | grep -Ei 'timescape'
# Expect: the bucket/endpoint config and credentials the ingester/server reference.

# 6.6  FUNCTIONAL PROOF — query the past via the Enterprise Hubble UI
$ cilium hubble ui --namespace $CILIUM_NS
#   In the UI: switch to the "Timescape" view, select a PAST time range
#   (e.g. last 1 hour). If historical flows render for that window, the
#   ingest -> store -> query pipeline works end to end.

# 6.7  Closed-loop test: generate traffic now, then query it later
$ oc -n <app-ns> exec deploy/<app> -- curl -s http://<some-service> > /dev/null
#   Wait 3-5 minutes (ingest interval), then in the Timescape UI query the
#   time window you just generated traffic in -> the new flows should appear.
```

---

## Section 7 — Quick all-in-one sanity sweep (copy/paste block)

```bash
echo "== networkType =="; oc get network.config/cluster -o jsonpath='{.spec.networkType}{"\n"}'
echo "== cluster operators (network) =="; oc get co network
echo "== isovalent pods =="; oc get pods -A | grep -Ei 'cilium|tetragon|hubble|timescape|clickhouse'
echo "== cilium status =="; cilium status --namespace "$CILIUM_NS" | grep -E 'Cilium|Operator|Hubble|ClusterMesh|OK'
echo "== datapath =="; oc -n "$CILIUM_NS" exec ds/cilium -c cilium-agent -- cilium-dbg status | grep -E 'KubeProxyReplacement|Encryption|Cluster health'
echo "== tracing policies =="; oc get tracingpolicies
echo "== tetragon ds =="; oc -n "$TETRA_NS" get ds tetragon
echo "== timescape pods =="; oc -n "$TS_NS" get pods
```

---

## Section 8 — Acceptance criteria (sign-off checklist)

- [ ] `oc get network.config/cluster` → `networkType: Cilium`
- [ ] `oc get co` → all ClusterOperators Available, none Degraded
- [ ] `cilium status` → Cilium / Operator / Hubble Relay all `OK`; DaemonSet N/N ready
- [ ] `cilium connectivity test` → all tests successful
- [ ] `cilium-dbg status` → `KubeProxyReplacement: True` (and `Encryption: Enabled` if used)
- [ ] `hubble observe` → live flows visible; Hubble UI service map renders
- [ ] Tetragon → agent Running on every node; tracing policies loaded; `tetra getevents`
      shows events; (enforcement, if configured, kills the test action with exit 137)
- [ ] Timescape → ingester/server/ClickHouse Running; ingester logs show writes (no storage
      errors); UI returns **historical** flows for a past time range
- [ ] Closed-loop test (6.7) → newly generated traffic appears in Timescape after the ingest delay

---

## Section 9 — Troubleshooting

| Symptom | Likely cause | Action |
|---|---|---|
| `networkType` is not `Cilium` | Cluster still on OVN-Kubernetes | Either reinstall greenfield (Section M, Option A) or run the in-place OVN→Cilium migration (Section M, Option B). In-place is disruptive and unsupported by Red Hat — engage Isovalent/Red Hat first |
| `network` ClusterOperator `Degraded` | Cilium operator/agent failing to roll out | `oc -n $CILIUM_NS describe pod <cilium-pod>`; check SCC/SELinux denials in events |
| cilium pods `CrashLoopBackOff` on OCP | Missing/!applied SecurityContextConstraints | Confirm the certified operator created its SCCs: `oc get scc | grep -i cilium`; reinstall operator if absent |
| `cilium connectivity test` fails to create namespace | SCC blocks test pods | Grant the test namespace the needed SCC, or run with `--namespace $CILIUM_NS` |
| Tetragon pods not present | Tetragon component not enabled in the install/operator | Enable Tetragon in the Isovalent Enterprise config and re-apply |
| `tetra getevents` shows nothing | No tracing policy loaded, or only base policy | `oc get tracingpolicies`; apply a policy that matches your test action |
| Timescape pods missing entirely | Timescape values/operator not configured (images are public — no pull secret needed) | Verify the Timescape Helm/operator values were set during install |
| Ingester logs: `access denied` / `NoSuchBucket` | Object storage (S3/Blob/GCS/MinIO) creds or bucket wrong/unreachable | Fix the storage secret/endpoint; confirm the bucket exists and network egress is allowed |
| Timescape UI shows no historical data | Ingest delay, or ingester not writing | Wait the ingest interval (a few minutes); re-check 6.3 ingester logs; verify ClickHouse PVC is Bound |
| `oc` commands `Forbidden` | Not cluster-admin | Re-login with an admin account / token |

---

### References
- Isovalent Enterprise for OpenShift docs (operator install, SCCs): https://docs.isovalent.com
- Cilium docs: https://docs.cilium.io
- Tetragon docs: https://tetragon.io
- Hubble Timescape (Enterprise): https://isovalent.com/products
