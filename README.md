# CiliumOSS-EKS

Provision an **Amazon EKS** cluster in **AWS Sydney (`ap-southeast-2`)** and run the
**free / open-source Isovalent stack** — **Cilium** (as a full replacement for the AWS
VPC CNI) plus **Tetragon** for runtime security — entirely with **Terraform**.

> No Isovalent Enterprise license required. This installs the upstream `cilium/cilium`
> and `cilium/tetragon` Helm charts, the OSS foundation of the Isovalent platform.

> **Course map:** **Part 0 · Orientation (this page)** → [Part 1 · Build & Verify](FULL_DEPLOYMENT.md) → [Part 2 · Operate & Explore](ISOVALENT_FEATURES.md)
>
> New here? Read this page, then follow the parts in order. Each builds on the last.

---

## What you get

| Area | Detail |
|------|--------|
| Region | `ap-southeast-2` (Sydney) |
| Control plane | Amazon EKS, Kubernetes `1.30` |
| Compute | Managed node group, 2 × `m5.large` |
| CNI | **Cilium in ENI mode**, replacing `aws-node` (AWS VPC CNI) |
| Service routing | **kube-proxy replacement** (no `kube-proxy`) |
| Encryption | **WireGuard** node-to-node |
| Observability | **Hubble** + **Hubble UI** |
| Runtime security | **Tetragon** + a sample `TracingPolicy` |
| Multi-cluster | **ClusterMesh** API server (ready to pair) |
| Lab apps | Google Online Boutique, Cilium Star Wars L7 demo |

## Architecture

This is the **canonical topology** used throughout the course (the same diagram appears in
[Part 1, Section 0.2](FULL_DEPLOYMENT.md#02-the-layers-from-the-metal-up)). Both worker nodes
are identical: every node runs a **Cilium agent** and a **Tetragon agent** (they are
DaemonSets — one pod per node). Hubble, ClusterMesh and CoreDNS run once per cluster.

```mermaid
flowchart TB
    YOU["Your Mac<br/>terraform · kubectl · cilium · hubble"]
    subgraph AWS["AWS · ap-southeast-2 (Sydney)"]
        subgraph VPC["VPC 10.42.0.0/16 · 3 AZs · NAT gateway"]
            subgraph EKS["EKS cluster: isovalent-syd (k8s 1.30)"]
                CP["Control plane (AWS-managed)<br/>API server · etcd · scheduler"]
                subgraph NG["Managed node group · 2 × m5.large"]
                    subgraph N1["Worker node 1"]
                        A1["Cilium agent (eBPF)"]
                        T1["Tetragon agent"]
                        P1["app pods"]
                    end
                    subgraph N2["Worker node 2"]
                        A2["Cilium agent (eBPF)"]
                        T2["Tetragon agent"]
                        P2["app pods"]
                    end
                end
                ADDON["Cluster services:<br/>Hubble Relay + UI · ClusterMesh API · CoreDNS"]
            end
        end
    end
    YOU -->|aws / kubectl| CP
    CP --- N1
    CP --- N2
    N1 <-->|WireGuard encrypted| N2
    A1 -.-> ADDON
    A2 -.-> ADDON
```

## Repository layout

```
.
├── README.md                     # Part 0 — orientation + repo map (this file)
├── FULL_DEPLOYMENT.md            # Part 1 — keystroke-level build & verify guide
├── ISOVALENT_FEATURES.md         # Part 2 — hands-on feature labs (essential → advanced)
├── .gitignore
├── terraform/                    # all infrastructure as code
│   ├── versions.tf               # provider/version pins
│   ├── variables.tf              # tunables (region, sizes, versions)
│   ├── terraform.tfvars          # default values (no secrets)
│   ├── providers.tf              # aws / kubernetes / helm providers
│   ├── vpc.tf                    # VPC, subnets, NAT gateway
│   ├── eks.tf                    # EKS cluster + managed node group
│   ├── cilium.tf                 # bootstrap (strip VPC CNI) + Cilium Helm release
│   ├── tetragon.tf               # Tetragon Helm release
│   └── outputs.tf                # cluster name/endpoint/kubeconfig command
├── cilium/
│   └── values.yaml.tftpl         # templated Cilium Helm values
├── lab/
│   ├── deploy.sh                 # deploys all lab workloads
│   ├── starwars-l7-policy.yaml   # L7 CiliumNetworkPolicy
│   └── tetragon-tracingpolicy.yaml
└── sidenote/                     # side notes, not part of the course
    ├── OCP_Only.md
    └── SG_Audit_Notes.md
```

## Learning path — start here

New to EKS, Kubernetes, or Cilium? Work through the three parts in order. Together they
form a self-contained course that takes you from a blank laptop to confidently operating an
observable, encrypted, policy-secured cluster.

```mermaid
flowchart LR
    R["Part 0 · Orientation<br/>README.md<br/><i>(you are here)</i>"] --> F["Part 1 · Build & Verify<br/>FULL_DEPLOYMENT.md"]
    F --> I["Part 2 · Operate & Explore<br/>ISOVALENT_FEATURES.md"]
```

| Part | Document | What you'll do | Start at |
|------|----------|----------------|----------|
| **0** | **README.md** (this page) | Get the big picture: what's built, the topology, and the repo map. | You're here — then go to Part 1. |
| **1** | **[FULL_DEPLOYMENT.md](FULL_DEPLOYMENT.md)** | Learn the core concepts, then build the cluster keystroke-by-keystroke and verify the Cilium/Hubble/Tetragon stack is healthy. | [Section 0 — Concepts you need first](FULL_DEPLOYMENT.md#0-concepts-you-need-first) |
| **2** | **[ISOVALENT_FEATURES.md](ISOVALENT_FEATURES.md)** | Exercise every feature — Hubble observability, L3/L4/L7 & DNS policy, WireGuard, Tetragon enforcement, ClusterMesh and more. | [Section 0 — Core concepts](ISOVALENT_FEATURES.md#0-core-concepts-the-mental-model) |
| **↺** | **[FULL_DEPLOYMENT.md › Teardown](FULL_DEPLOYMENT.md#11-teardown)** | Destroy the lab to stop billing (it rebuilds in ~20 min whenever you want it back). | When you're done for the day. |

> **In a hurry and already know the stack?** Skip to [Quick start](#quick-start) below.
> Otherwise, begin with **Part 1** — every later part assumes the vocabulary it teaches.

## Quick start

```bash
cd terraform
terraform init
terraform apply
aws eks update-kubeconfig --region ap-southeast-2 --name isovalent-syd
../lab/deploy.sh
```

> **New here, or want every command, gotcha and verification step?**
> Read **[FULL_DEPLOYMENT.md](FULL_DEPLOYMENT.md)** — a complete, manual, copy-paste
> walkthrough from an empty laptop to a working, observable, encrypted cluster,
> including every error we hit in the real world and how to fix it.
>
> **Want to actually use the platform?**
> See **[ISOVALENT_FEATURES.md](ISOVALENT_FEATURES.md)** — hands-on labs from essential to
> advanced: Hubble observability, L3/L4/L7 & DNS policy, WireGuard, Tetragon enforcement,
> egress gateway, ClusterMesh, Gateway API, mutual auth, and more.

## Cost & cleanup

This creates billable resources (EKS control plane, 2 EC2 nodes, NAT gateway, 2 load
balancers). Tear everything down with:

```bash
cd terraform
terraform destroy
```

## Security

- **Never commit AWS keys.** Credentials live in `~/.aws/credentials` (created by
  `aws configure`), which is outside this repo and ignored by Git.
- Terraform state can contain sensitive values — `*.tfstate*` is git-ignored. Use a
  remote backend (e.g. S3 + DynamoDB) for real/shared environments.
- Rotate any access key the moment it is exposed.

## License

OSS components are under their respective upstream licenses (Cilium & Tetragon: Apache-2.0).
