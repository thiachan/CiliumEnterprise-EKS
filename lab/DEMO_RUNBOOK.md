# Isovalent Enterprise on EKS — Customer Demo Runbook

Cluster: `isovalent-syd` (EKS, `ap-southeast-2`) · Cilium Enterprise 1.18 · Tetragon · Hubble Timescape (lite)

Two demo apps are pre-deployed:
- **Online Boutique** (`boutique` ns) — 12 microservices + a load generator that drives
  constant traffic (keeps Hubble + Timescape lively with zero effort).
- **Star Wars** (`default` ns) — `deathstar`, `tiefighter` (Empire), `xwing` (Alliance),
  plus `mediabot` for the DNS demo.

---

## 0. Pre-flight (run ~20 min before the customer joins)

```bash
export PATH="/opt/homebrew/bin:$PATH"
aws eks update-kubeconfig --region ap-southeast-2 --name isovalent-syd

# Health — expect: cilium x2, tetragon x2, timescape 2/2, boutique 12, starwars 5
kubectl -n kube-system get pods -l k8s-app=cilium
kubectl -n hubble-timescape get pods
kubectl get pods -n boutique
kubectl get pods -n default

# tiefighter/xwing/mediabot are BARE PODS — they vanish on node replacement.
# If any are missing, recreate them:
kubectl apply -f https://raw.githubusercontent.com/cilium/cilium/v1.15.6/examples/minikube/http-sw-app.yaml
kubectl apply -f lab/starwars-l7-policy.yaml
kubectl apply -f lab/dns-egress-policy.yaml
kubectl apply -f lab/tetragon-enforce-shadow.yaml

# Open both UIs and leave the tabs running:
kubectl -n kube-system     port-forward svc/hubble-ui            12000:80 &
kubectl -n hubble-timescape port-forward svc/hubble-timescape-ui  8080:80 &
#   Hubble (live):       http://localhost:12000
#   Timescape (history): http://localhost:8080

# Confirm Timescape is ingesting (expect stream.flows.flushed=NNN/s):
kubectl -n hubble-timescape logs sts/hubble-timescape-lite -c timescape --tail=20 | grep flows.flushed
```

Have **3 terminals** open: (A) app traffic, (B) live observe / events, (C) spare.

> **Timescape retention:** lite stores flows on node ephemeral disk; TTL is set to **6h**
> (`var.timescape_flows_ttl`). Don't promise "last Tuesday" — generate your incident
> traffic during the session and query the last minutes/hours.

---

## Act 1 — See everything, instrument nothing  (~5 min)

**Message:** identity-aware L3–L7 visibility, no sidecars, no app changes.

1. Browser → **http://localhost:12000** (Hubble UI). Select the **`boutique`** namespace.
2. The service map is already live (the load generator drives traffic). Point out
   service-to-service dependencies, protocols (HTTP/gRPC), and that nothing was
   instrumented in the apps.
3. Live flows in a terminal:
   ```bash
   kubectl -n kube-system exec ds/cilium -c cilium-agent -- hubble observe -f --namespace boutique
   ```

---

## Act 2 — Identity-based segmentation + L7 API enforcement  (~8 min)  ← detailed

This is the headline policy demo. Do it **slowly**, in three beats, while the Hubble UI is
open on the **`default`** namespace so the customer SEES allow vs deny in real time.

### Setup the visual (do this first)
- Browser → **http://localhost:12000**, select namespace **`default`**.
- In terminal **B**, stream the Star Wars flows so denials are visible as text too:
  ```bash
  kubectl -n kube-system exec ds/cilium -c cilium-agent -- \
    hubble observe -f --namespace default --to-label class=deathstar
  ```
  Leave this running. `FORWARDED` = allowed, `DROPPED` = L3/L4 deny, `DROPPED (L7)` /
  `403` = L7 deny.

### Beat 1 — Empire ship is allowed to land (baseline, policy already applied)
In terminal **A**:
```bash
kubectl exec tiefighter -- curl -s -XPOST deathstar.default.svc.cluster.local/v1/request-landing
```
- **Expected output:** `Ship landed`
- **Say:** "The policy `rule-deathstar` allows pods with identity `org=empire` to call
  exactly one API — `POST /v1/request-landing`. This is allowed by *workload identity*,
  not IP address."
- In Hubble UI / terminal B you'll see a green **FORWARDED** HTTP flow `tiefighter → deathstar`.

### Beat 2 — The money shot: same ship, forbidden API → blocked at L7
```bash
kubectl exec tiefighter -- curl -s -XPUT deathstar.default.svc.cluster.local/v1/exhaust-port
```
- **Expected output:** `Access denied`
- **Say:** "Same trusted Empire identity, but it tried `PUT /v1/exhaust-port`. Cilium is
  parsing **HTTP method and path** and denies that specific call — an attacker who already
  has a foothold still cannot reach a dangerous API. Traditional firewalls only see
  `tcp/80` and would allow this."
- In Hubble UI / terminal B: a red **DROPPED** flow with the L7/HTTP verdict and the exact
  path `/v1/exhaust-port`. **Click the dropped flow in the UI** to show the method+path —
  this is the visual that lands the L7 story.

### Beat 3 — Rebel ship has no identity grant → dropped at L3/L4
```bash
kubectl exec xwing -- curl -s -m5 -XPOST deathstar.default.svc.cluster.local/v1/request-landing
```
- **Expected output:** hangs ~5s then `command terminated with exit code 28` (timeout).
- **Say:** "The `xwing` is `org=alliance`. No rule grants that identity any access, so its
  packets are dropped at L3/L4 — it never even reaches the HTTP layer. That's why this one
  times out instead of getting a clean 403."
- In Hubble UI / terminal B: red **DROPPED** at L3/L4 (Policy denied), no HTTP parsing.

### One-paragraph wrap
"Three outcomes, one policy: allowed by identity, allowed-but-API-restricted at L7, and
denied by default. The app never changed, and you saw every decision live in Hubble."

> **Reset between runs (optional):** the policy stays applied; just re-run the three
> commands. To show the 'before' state, `kubectl delete -f lab/starwars-l7-policy.yaml`
> (now everything is allowed), then re-apply to re-impose segmentation.

---

## Act 3 — Runtime security with Tetragon (observe → enforce)  (~7 min)

**Message:** kernel-level (eBPF) process/file/network visibility, and inline enforcement.

1. Stream runtime events in terminal **B**:
   ```bash
   kubectl -n kube-system exec -it ds/tetragon -c tetragon -- tetra getevents -o compact
   ```
2. **Observe:** in terminal **A**, run a process inside a pod and watch it appear:
   ```bash
   kubectl exec tiefighter -- id
   kubectl exec tiefighter -- cat /etc/passwd | head -1
   ```
   Point out `process_exec` events with full binary, args, pod, and identity.
3. **Enforce (money shot):** the `block-sensitive-file-reads` TracingPolicyNamespaced
   SIGKILLs any process in `default` that reads `/etc/shadow`:
   ```bash
   kubectl exec tiefighter -- cat /etc/shadow ; echo "exit=$?"
   ```
   - **Expected:** `command terminated with exit code 137` (killed by the kernel before the
     read completes).
   - **Say:** "The policy is enforced in-kernel via eBPF — the process is terminated before
     it can exfiltrate the file. Scoped to the `default` namespace so blast radius is
     controlled."

---

## Act 4 — DNS / FQDN-aware egress  (~5 min)

**Message:** egress policy by DNS name, not brittle IP allowlists.

```bash
# Allowed — the only FQDN the policy permits:
kubectl exec mediabot -- curl -sI -m8 https://api.github.com | head -1     # HTTP/2 200

# Denied — any other destination, even though no IP is hardcoded:
kubectl exec mediabot -- curl -sI -m8 https://www.cisco.com | head -1      # times out
```
- **Say:** "`mediabot` can reach `api.github.com` and nothing else. Cilium's DNS proxy
  resolves and pins the name, so policy follows the FQDN even as its IPs change — no IP
  allowlists to maintain."

---

## Act 5 — Hubble Timescape: historical + correlated  (THE differentiator, ~7 min)

**Message:** OSS Hubble is live-only and already forgot Acts 2–3. Enterprise kept the
history and correlates **network + runtime** in one place.

1. Browser → **http://localhost:8080** (Timescape UI). Pick a window covering the **last
   15–30 min**.
2. Find the artefacts you just generated:
   - The `tiefighter → deathstar` **/v1/exhaust-port** L7 denial (Act 2, beat 2).
   - The `xwing` L3/L4 drops (Act 2, beat 3).
3. CLI alternative (historical query against the Observer API):
   ```bash
   kubectl -n hubble-timescape port-forward sts/hubble-timescape-lite 4245:4244 &
   hubble observe --server localhost:4245 --since 30m --namespace default --to-label class=deathstar --verdict DROPPED
   ```
4. **Say:** "This is the post-incident question every SOC asks — *what happened, and which
   workload/process caused it?* Live Hubble can't answer it; Timescape can, retrospectively,
   with network flows and Tetragon runtime events side by side."

---

## Talking points — Enterprise features (discuss; licence-gated, not live here)

These run on the same Enterprise build but require an Isovalent licence (the chart's
`featureGate` intentionally blocks them in this lab):

- Transparent **node-to-node encryption** (WireGuard/IPsec) and **mutual authentication** (SPIFFE)
- **ClusterMesh** — multi-cluster service discovery and failover
- **BGP control plane**, **SRv6**, **Egress Gateway HA**
- **Hubble Timescape at scale** — object-storage backend, long retention, **RBAC/SSO**
- **Tetragon enterprise** policy library, hardened images, and **24×7 support**

Framing: "Everything you saw runs on the Enterprise build today; these unlock with the licence."

---

## Reset / cleanup

```bash
# Re-impose a clean baseline between audiences:
kubectl apply -f lab/starwars-l7-policy.yaml
kubectl apply -f lab/dns-egress-policy.yaml
kubectl apply -f lab/tetragon-enforce-shadow.yaml

# Remove the demo policies entirely:
kubectl delete -f lab/tetragon-enforce-shadow.yaml --ignore-not-found
kubectl delete -f lab/dns-egress-policy.yaml --ignore-not-found
kubectl delete -f lab/starwars-l7-policy.yaml --ignore-not-found
```
