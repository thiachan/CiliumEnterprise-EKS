# FULL DEPLOYMENT — End-to-End, Step by Step

This is the complete, manual walkthrough for standing up an **Amazon EKS** cluster in
**Sydney (`ap-southeast-2`)** running the **open-source Isovalent stack** — **Cilium**
replacing the AWS VPC CNI, **Tetragon** for runtime security, **Hubble** for observability,
**WireGuard** encryption, and **ClusterMesh** ready to pair — then deploying lab apps on top.

It is written as if you are sitting at a fresh macOS laptop and typing every command
yourself. Every step includes the command, what to expect, and how to recover when it
goes wrong. **Every real-world error encountered during the original build is captured in
the [Troubleshooting](#10-troubleshooting--real-world-errors-and-fixes) section** — read it,
because you will probably hit at least one of them.

> Conventions
> - `$` lines are commands you type.
> - Replace anything in `<ANGLE_BRACKETS>` with your own value.
> - **Never paste real AWS keys into chats, tickets, or commits.** Use `aws configure`.

---

## Table of contents

1. [Prerequisites and tool installation](#1-prerequisites-and-tool-installation)
2. [AWS account and IAM preparation](#2-aws-account-and-iam-preparation)
3. [Configure AWS credentials locally](#3-configure-aws-credentials-locally)
4. [Get the code](#4-get-the-code)
5. [Understand what Terraform will build](#5-understand-what-terraform-will-build)
6. [Initialize, plan, apply](#6-initialize-plan-apply)
7. [Connect kubectl and verify the cluster](#7-connect-kubectl-and-verify-the-cluster)
8. [Verify the Isovalent stack](#8-verify-the-isovalent-stack)
9. [Deploy and exercise the lab apps](#9-deploy-and-exercise-the-lab-apps)
10. [Troubleshooting — real-world errors and fixes](#10-troubleshooting--real-world-errors-and-fixes)
11. [Teardown](#11-teardown)
12. [Security checklist](#12-security-checklist)

---

## 1. Prerequisites and tool installation

You need a Mac (these notes assume **Apple Silicon / arm64**, e.g. M1/M2/M3) with
[Homebrew](https://brew.sh) installed. Verify Homebrew first:

```bash
$ brew --version
Homebrew 4.x.x
```

Install every CLI tool you will use:

```bash
$ brew install terraform awscli kubernetes-cli helm cilium-cli hubble
```

> **Apple Silicon gotcha (this bit us):** if `kubectl` was previously installed by copying
> a Linux binary into `/usr/local/bin`, it will be the **wrong architecture** and fail with
> `cannot execute binary file`. Always install it via Homebrew so you get the native
> `arm64` Mach-O build. See [Troubleshooting 10.3](#103-kubectl-cannot-execute-binary-file).

Confirm versions and architecture:

```bash
$ terraform version          # want >= 1.6
$ aws --version              # want aws-cli/2.x
$ kubectl version --client   # want >= 1.30
$ helm version
$ cilium version             # client
$ file "$(brew --prefix)/bin/kubectl"
.../bin/kubectl: Mach-O 64-bit executable arm64        # <-- must say arm64, not x86-64/ELF
```

If `which -a kubectl` shows a second copy under `/usr/local/bin`, make sure the Homebrew
one (`/opt/homebrew/bin/kubectl`) wins in your `PATH`, or remove the broken one:

```bash
$ which -a kubectl
/opt/homebrew/bin/kubectl     # good, should be first
/usr/local/bin/kubectl        # broken Linux binary — remove if present
$ sudo rm -f /usr/local/bin/kubectl
```

---

## 2. AWS account and IAM preparation

You need an AWS account and an IAM principal (user or role) with enough permissions to
create networking, EKS, **IAM roles**, and CloudWatch log groups. EKS *cannot* be created
without permission to make IAM roles, so do not skip this.

### Minimum IAM permissions

At a minimum the principal needs:

- **EC2 / VPC:** create VPC, subnets, route tables, NAT gateway, EIP, security groups.
- **EKS:** create/describe clusters, node groups, add-ons, access entries.
- **IAM:** the following actions (this is exactly what the EKS Terraform module needs):

```
iam:CreateRole, iam:CreatePolicy, iam:CreatePolicyVersion, iam:AttachRolePolicy,
iam:DetachRolePolicy, iam:PutRolePolicy, iam:DeleteRolePolicy, iam:PassRole,
iam:GetRole, iam:GetPolicy, iam:ListAttachedRolePolicies, iam:ListRolePolicies,
iam:TagRole, iam:TagPolicy, iam:CreateInstanceProfile, iam:AddRoleToInstanceProfile,
iam:CreateOpenIDConnectProvider, iam:TagOpenIDConnectProvider
```

- **CloudWatch Logs:** `logs:CreateLogGroup`, `logs:PutRetentionPolicy`, `logs:TagResource`
  (for EKS control-plane logging).

> **For a throwaway lab**, the simplest path is to attach the AWS-managed
> **`AdministratorAccess`** policy to your IAM user. For anything shared or long-lived,
> use the least-privilege list above. **We hit `AccessDenied` on `iam:CreateRole`,
> `iam:CreatePolicy`, and `logs:CreateLogGroup` on the first apply** because the user only
> had EC2/EKS rights — see [Troubleshooting 10.2](#102-accessdenied-on-iam-and-cloudwatch-logs).

### vCPU service quota

A brand-new account often has a **5 vCPU** limit for *Running On-Demand Standard instances*
in a region. Each `m5.large` is **2 vCPU**, so:

- 2 nodes = 4 vCPU → fits under the default.
- 3+ nodes = 6+ vCPU → you must request a quota increase.

This is why the default config caps the node group at **2 nodes**. Check (or request) your
quota in **Service Quotas → Amazon EC2 → "Running On-Demand Standard … instances"** (code
`L-1216C47A`).

> If your IAM user lacks `servicequotas:GetServiceQuota` you simply won't be able to read it
> from the CLI; you can still proceed and you'll find out at apply time.

---

## 3. Configure AWS credentials locally

Create an access key for your IAM user in the AWS console
(**IAM → Users → your user → Security credentials → Create access key**), then store it
locally with `aws configure`. **Do not** export keys inline in shared transcripts and do
**not** commit them.

```bash
$ aws configure
AWS Access Key ID [None]: <YOUR_ACCESS_KEY_ID>
AWS Secret Access Key [None]: <YOUR_SECRET_ACCESS_KEY>
Default region name [None]: ap-southeast-2
Default output format [None]: json
```

This writes `~/.aws/credentials` and `~/.aws/config` — both **outside** this repository.

Verify you are who you think you are:

```bash
$ aws sts get-caller-identity
{
    "UserId": "AIDA...",
    "Account": "<YOUR_ACCOUNT_ID>",
    "Arn": "arn:aws:iam::<YOUR_ACCOUNT_ID>:user/<your-user>"
}
```

> **Why this matters for kubectl:** the kubeconfig this project generates authenticates to
> EKS by running `aws eks get-token` under the hood. If your shell has no AWS credentials,
> `kubectl` returns `error: You must be logged in to the server (Unauthorized)`. Storing
> creds with `aws configure` makes every future shell work without manual exports — see
> [Troubleshooting 10.5](#105-kubectl-unauthorized).

---

## 4. Get the code

```bash
$ git clone https://github.com/thiachan/CiliumOSS-EKS.git
$ cd CiliumOSS-EKS
```

Take a look at the layout:

```bash
$ ls -R
README.md  FULL_DEPLOYMENT.md  .gitignore
cilium/    lab/    terraform/
...
```

---

## 5. Understand what Terraform will build

Before applying, know the moving parts (all under `terraform/`):

| File | Creates |
|------|---------|
| `vpc.tf` | VPC `10.42.0.0/16`, 3 AZs, public + private subnets, single NAT gateway |
| `eks.tf` | EKS control plane (k8s 1.30), one managed node group (2 × `m5.large`), CoreDNS add-on. **The `vpc-cni` add-on is deliberately NOT installed.** |
| `cilium.tf` | A bootstrap step that **deletes `aws-node` and `kube-proxy`**, then a Helm release installing Cilium |
| `tetragon.tf` | Helm release installing Tetragon |
| `cilium/values.yaml.tftpl` | Cilium config: ENI mode, kube-proxy replacement, WireGuard, Hubble + UI, ClusterMesh |

### Key design choices

- **Cilium replaces the AWS VPC CNI.** Because `vpc-cni` is never installed and the
  bootstrap removes the default `aws-node` DaemonSet, Cilium owns pod networking. It runs in
  **ENI mode** (`ipam.mode=eni`) so pods get real VPC IPs from ENIs.
- **kube-proxy replacement.** Cilium is configured with `kubeProxyReplacement: true` and the
  bootstrap deletes the `kube-proxy` DaemonSet. The Cilium values inject the EKS API
  endpoint so the agent can reach the control plane directly.
- **`NotReady` is expected, briefly.** Fresh managed nodes report `NotReady` until the
  Cilium agent DaemonSet lands and provides a CNI. Cilium DaemonSets tolerate this state,
  so it resolves itself within a minute or two.
- **Two-phase apply is normal.** EKS provisioning (~10–15 min) happens first; only then can
  the Helm/Kubernetes providers talk to the cluster. If the very first apply errors out
  partway (e.g. an IAM permission gap), fix the cause and simply run `terraform apply`
  again — it is idempotent and resumes where it left off.

Tunables live in `terraform/terraform.tfvars`:

```hcl
region            = "ap-southeast-2"
cluster_name      = "isovalent-syd"
cluster_version   = "1.30"
instance_type     = "m5.large"
node_desired_size = 2
node_min_size     = 2
node_max_size     = 2     # capped at 2 to stay under a default 5-vCPU quota
cilium_version    = "1.15.6"
tetragon_version  = "1.1.2"
```

---

## 6. Initialize, plan, apply

```bash
$ cd terraform
$ terraform init
...
Terraform has been successfully initialized!
```

Review the plan (read-only, nothing is created yet):

```bash
$ terraform plan -out=tfplan
...
Plan: 66 to add, 0 to change, 0 to destroy.
Saved the plan to: tfplan
```

Apply it. This is the billable step and takes roughly **15–20 minutes**:

```bash
$ terraform apply tfplan
...
module.eks.aws_eks_cluster.this[0]: Still creating... [08m00s elapsed]
module.eks.aws_eks_cluster.this[0]: Creation complete after 8m23s
...
null_resource.remove_default_cni (local-exec): daemonset.apps "aws-node" deleted
null_resource.remove_default_cni (local-exec): daemonset.apps "kube-proxy" deleted
helm_release.cilium: Creation complete after 30s
helm_release.tetragon: Creation complete after 44s

Apply complete! Resources: 66 added, 0 changed, 0 destroyed.

Outputs:
cluster_endpoint = "https://XXXXXXXX.sk1.ap-southeast-2.eks.amazonaws.com"
cluster_name = "isovalent-syd"
cluster_version = "1.30"
region = "ap-southeast-2"
update_kubeconfig_command = "aws eks update-kubeconfig --region ap-southeast-2 --name isovalent-syd"
```

> If the first apply stops with `AccessDenied` (IAM/logs) or a `kubectl ... cannot execute
> binary file` error, jump to [Troubleshooting](#10-troubleshooting--real-world-errors-and-fixes),
> fix it, and re-run `terraform apply`. Resources already created are preserved.

---

## 7. Connect kubectl and verify the cluster

Point `kubectl` at the new cluster (uses your `~/.aws` credentials automatically):

```bash
$ aws eks update-kubeconfig --region ap-southeast-2 --name isovalent-syd
Added new context arn:aws:eks:ap-southeast-2:<acct>:cluster/isovalent-syd to ~/.kube/config
```

Check the nodes — both should be `Ready`:

```bash
$ kubectl get nodes -o wide
NAME                                              STATUS   ROLES    AGE   VERSION
ip-10-42-47-112.ap-southeast-2.compute.internal   Ready    <none>   5m    v1.30.x
ip-10-42-5-120.ap-southeast-2.compute.internal    Ready    <none>   5m    v1.30.x
```

Confirm the **AWS VPC CNI is gone** — only `cilium` and `tetragon` DaemonSets should exist,
with **no `aws-node` and no `kube-proxy`**:

```bash
$ kubectl -n kube-system get ds
NAME       DESIRED   CURRENT   READY   AGE
cilium     2         2         2       2m
tetragon   2         2         2       1m
```

Check Cilium and Tetragon pods are running:

```bash
$ kubectl -n kube-system get pods -l k8s-app=cilium
$ kubectl -n kube-system get pods -l app.kubernetes.io/name=tetragon
```

---

## 8. Verify the Isovalent stack

Use the Cilium CLI to confirm everything is healthy:

```bash
$ cilium status
    /¯¯\
 /¯¯\__/¯¯\    Cilium:             OK
 \__/¯¯\__/    Operator:           OK
 /¯¯\__/¯¯\    Hubble Relay:       OK
 \__/¯¯\__/    ClusterMesh:        OK
    \__/
DaemonSet cilium      Desired: 2, Ready: 2/2
Deployment hubble-ui  Desired: 1, Ready: 1/1
...
```

Confirm the three headline features are actually on:

```bash
$ kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg status \
    | grep -E 'KubeProxyReplacement|Encryption|Cluster health'
KubeProxyReplacement:   True   [eth0 ... (Direct Routing), eth1 ...]
Encryption:             Wireguard   [NodeEncryption: Enabled, cilium_wg0 ...]
Cluster health:         2/2 reachable
```

- `KubeProxyReplacement: True` → Cilium replaced kube-proxy.
- `Encryption: Wireguard … NodeEncryption: Enabled` → node-to-node traffic is encrypted.
- `2/2 reachable` → the data path is healthy.

Optional, deeper connectivity test (creates and cleans up test pods):

```bash
$ cilium connectivity test
```

---

## 9. Deploy and exercise the lab apps

The `lab/` folder deploys three things: the **Online Boutique** microservices demo, the
**Star Wars** L7 policy demo, and a **Tetragon TracingPolicy**.

```bash
$ cd ..          # back to repo root
$ ./lab/deploy.sh
==> 1/3  Online Boutique (namespace: boutique)
==> 2/3  Star Wars demo (default namespace)
==> 3/3  Tetragon TracingPolicy (runtime visibility)
Done.
```

### 9.1 Watch Online Boutique come up

```bash
$ kubectl -n boutique get pods
$ kubectl -n boutique get svc frontend-external -o wide
# Open the EXTERNAL-IP (an ELB hostname) in your browser once it's provisioned:
# http://<elb-hostname>.ap-southeast-2.elb.amazonaws.com
```

> The first request may take a couple of minutes while images pull and the ELB passes
> health checks.

### 9.2 Prove the L7 network policy (Star Wars)

#### 9.2.1 What this demo actually is

The "Star Wars" demo is Cilium's official, tiny example for showing **Layer-7 (HTTP-aware)
network policy**. It deploys three things into the `default` namespace:

| Workload | Labels | Role |
|----------|--------|------|
| `deathstar` (Deployment, 2 pods, behind a Service) | `org=empire, class=deathstar` | An HTTP API server. It exposes `POST /v1/request-landing` (let a ship land) and a sensitive `PUT /v1/exhaust-port` (the one that blows it up). |
| `tiefighter` (pod) | `org=empire, class=tiefighter` | An "empire" client. |
| `xwing` (pod) | `org=alliance, class=xwing` | A "rebel/alliance" client. |

The story: we want to allow ships to **request landing** but make sure nobody can hit the
dangerous **exhaust-port** endpoint. A normal L3/L4 firewall can't tell those apart — they
are both HTTP on port 80. Cilium's L7 policy can, because it inspects the HTTP method + path.

#### 9.2.2 Where the files live and where the policy is applied

Two separate sources are used, both wired up by [`lab/deploy.sh`](lab/deploy.sh):

1. **The app manifest** is pulled from the upstream Cilium repo at deploy time (not stored in
   this repo). `deploy.sh` runs, in step 2/3:
   ```bash
   kubectl apply -f \
     https://raw.githubusercontent.com/cilium/cilium/v1.15.6/examples/minikube/http-sw-app.yaml
   ```
   That creates the `deathstar` Service + Deployment and the `xwing` / `tiefighter` pods in
   the **`default`** namespace.

2. **The L7 policy** is stored **in this repo** at
   [`lab/starwars-l7-policy.yaml`](lab/starwars-l7-policy.yaml) and is applied right after,
   also by `deploy.sh`:
   ```bash
   kubectl apply -f "${SCRIPT_DIR}/starwars-l7-policy.yaml"
   ```
   It is a `CiliumNetworkPolicy` named `rule-deathstar`, applied into the **`default`**
   namespace (a `CiliumNetworkPolicy` is namespaced; with no `namespace:` field it lands in
   whatever namespace `kubectl` targets — here, `default`). The rule says: *only pods labelled
   `org=alliance` may reach the deathstar, and only via `POST /v1/request-landing` on port 80.*
   Everything else is denied.

So after `./lab/deploy.sh`, both the app and the policy already exist — you do **not** need
to apply anything manually. (If you ever want to apply just the policy by hand:
`kubectl apply -f lab/starwars-l7-policy.yaml`.)

#### 9.2.3 See that the policy is installed and where it is attached

```bash
# List Cilium network policies in the default namespace — you should see "rule-deathstar"
$ kubectl -n default get ciliumnetworkpolicies
NAME            AGE
rule-deathstar  3m

# 'cnp' is the short name; this works too
$ kubectl -n default get cnp

# Inspect the policy in full (selectors + the L7 HTTP rule)
$ kubectl -n default describe cnp rule-deathstar
$ kubectl -n default get cnp rule-deathstar -o yaml

# See WHICH pods the policy is enforced on (the deathstar endpoints).
# 'Policy (ingress) Enabled' on the deathstar endpoints confirms enforcement is active.
$ kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg endpoint list \
    | grep -E 'deathstar|xwing|tiefighter'
```

#### 9.2.4 Verify the policy actually works (allowed vs denied)

First wait for the deathstar to be ready, then grab the X-wing pod name into a variable:

```bash
$ kubectl -n default wait --for=condition=ready pod -l class=deathstar --timeout=120s
$ XWING=$(kubectl get pod -l class=xwing -o jsonpath='{.items[0].metadata.name}')
$ echo "$XWING"          # sanity check: prints the xwing pod name
```

Allowed call — the policy permits `POST /v1/request-landing`:

```bash
$ kubectl exec "$XWING" -- curl -s -XPOST deathstar.default.svc.cluster.local/v1/request-landing
Ship landed
```

Denied call — same pod, same port, but a different HTTP method/path the policy does not allow:

```bash
$ kubectl exec "$XWING" -- curl -s -XPUT deathstar.default.svc.cluster.local/v1/exhaust-port
Access denied
```

- `Ship landed` → the request was **allowed** by the L7 rule.
- `Access denied` → Cilium **blocked it at Layer 7** (the connection still reached port 80,
  but the embedded Envoy proxy rejected the method/path). This is the whole point: an L3/L4
  firewall could not have distinguished these two HTTP calls.

#### 9.2.5 Watch the enforcement happen live in Hubble

In a second terminal, stream HTTP flows for the `default` namespace, then re-run the two
curls from 9.2.4:

```bash
$ cilium hubble port-forward &
$ hubble observe --namespace default --protocol http --follow
```

You will see two L7 entries — the `POST /v1/request-landing` as `FORWARDED` and the
`PUT /v1/exhaust-port` as `DROPPED` with an `http` verdict. That dropped line is the policy
doing its job.

#### 9.2.6 (Optional) Prove it's the policy by removing it

```bash
# Delete the policy → the previously denied call now succeeds
$ kubectl -n default delete cnp rule-deathstar
$ kubectl exec "$XWING" -- curl -s -XPUT deathstar.default.svc.cluster.local/v1/exhaust-port
Panic: deathstar exploded          # no longer blocked!

# Re-apply to restore enforcement
$ kubectl apply -f lab/starwars-l7-policy.yaml
$ kubectl exec "$XWING" -- curl -s -XPUT deathstar.default.svc.cluster.local/v1/exhaust-port
Access denied
```

### 9.3 Observe flows with Hubble

Open the graphical Hubble UI (port-forwards; leave it running, Ctrl-C to stop):

```bash
$ cilium hubble ui
```

Or stream flows in the terminal:

```bash
$ cilium hubble port-forward &
$ hubble observe --follow
$ hubble observe --namespace boutique --protocol http     # L7 HTTP visibility
```

### 9.4 Watch Tetragon runtime events

```bash
$ kubectl -n kube-system exec -it ds/tetragon -c tetragon -- tetra getevents -o compact
```

You will see process exec, file access (e.g. to `/etc/passwd`), and network-connect events
as defined by `lab/tetragon-tracingpolicy.yaml`.

---

## 10. Troubleshooting — real-world errors and fixes

These are the exact problems hit while building this, and the fix for each.

### 10.1 `servicequotas:GetServiceQuota` AccessDenied

```
AccessDeniedException ... not authorized to perform: servicequotas:GetServiceQuota
```

**Cause:** your IAM user can't read service quotas. **Fix:** harmless — either add
`servicequotas:GetServiceQuota` to the user, or check the quota in the AWS console, or just
proceed and discover any vCPU limit at apply time.

### 10.2 AccessDenied on IAM and CloudWatch Logs

```
AccessDenied ... not authorized to perform: iam:CreateRole on resource: .../isovalent-syd-cluster-...
AccessDenied ... not authorized to perform: iam:CreatePolicy ...
AccessDeniedException ... not authorized to perform: logs:CreateLogGroup ...
```

**Cause:** the IAM principal lacks IAM-role/policy and CloudWatch-Logs permissions, which
EKS needs. The VPC/NAT/security groups may already be created at this point (and start
billing). **Fix:** attach the permissions from [section 2](#2-aws-account-and-iam-preparation)
(or `AdministratorAccess` for a lab), then **re-run `terraform apply`** — it resumes and
creates the IAM roles, control plane, etc. To stop charges while you sort permissions, you
can `terraform destroy` the partial stack first.

### 10.3 `kubectl: cannot execute binary file`

```
/usr/local/bin/kubectl: cannot execute binary file
Error: local-exec provisioner error ... exit status 126
```

**Cause:** the `kubectl` found first in `PATH` is a **Linux x86-64 binary on an arm64 Mac**
(verify with `file /usr/local/bin/kubectl` → it says `ELF ... x86-64`). The Terraform
bootstrap calls `kubectl` to delete `aws-node`/`kube-proxy` and fails. **Fix:**

```bash
$ brew install kubernetes-cli         # installs native arm64 kubectl to /opt/homebrew/bin
$ file /opt/homebrew/bin/kubectl      # should say: Mach-O 64-bit executable arm64
```

Then ensure the good binary wins. Either remove the broken one (`sudo rm -f
/usr/local/bin/kubectl`) or make sure `/opt/homebrew/bin` precedes `/usr/local/bin` in
`PATH`. In this repo, `cilium.tf` already prepends `/opt/homebrew/bin` to the bootstrap
script's `PATH` for exactly this reason. Re-run `terraform apply`.

### 10.4 Nodes stuck `NotReady`

**Cause:** there is no CNI until Cilium is installed; freshly joined nodes are `NotReady`.
**Fix:** none needed — wait. Once the `cilium` DaemonSet is `Ready: 2/2`, nodes flip to
`Ready` within a minute. If they never recover, check `kubectl -n kube-system logs ds/cilium`
and confirm the bootstrap actually deleted `aws-node`.

### 10.5 `kubectl` Unauthorized

```
error: You must be logged in to the server (Unauthorized)
```

**Cause:** the shell has no AWS credentials, so `aws eks get-token` (used by the kubeconfig)
can't mint a token. This happens if you only ever exported keys inline in a previous shell.
**Fix:** store credentials permanently with `aws configure` (see
[section 3](#3-configure-aws-credentials-locally)). Re-running `aws eks update-kubeconfig`
is **not** required after that; just retry your `kubectl` command.

### 10.6 `command not found: cilium` / `hubble`

**Cause:** the CLIs aren't installed. **Fix:**

```bash
$ brew install cilium-cli hubble
```

---

## 11. Teardown

Remove **everything** to stop charges (control plane, nodes, NAT gateway, both load
balancers, IAM roles, VPC):

```bash
$ cd terraform
$ terraform destroy
...
Destroy complete! Resources: NN destroyed.
```

If `destroy` stalls on the VPC because a load balancer is still being deleted, wait a minute
and run it again — Kubernetes-created ELBs sometimes lag behind Terraform.

---

## 12. Security checklist

- [ ] AWS keys are stored only in `~/.aws/credentials`, never in this repo or any chat.
- [ ] `.gitignore` excludes `*.tfstate*`, `.terraform/`, kubeconfig files, and the bootstrap
      kubeconfig. Confirm `git status` shows none of these as tracked.
- [ ] **Rotate/delete any access key that was ever exposed** (console → IAM → Users →
      Security credentials), e.g.:
      ```bash
      $ aws iam update-access-key --access-key-id <KEY_ID> --status Inactive
      $ aws iam delete-access-key  --access-key-id <KEY_ID>
      ```
- [ ] For shared/long-lived use, switch Terraform to a **remote backend** (S3 + DynamoDB
      lock) and use **least-privilege IAM** rather than `AdministratorAccess`.
- [ ] Tear the cluster down when you're finished (section 11) — it bills by the hour.