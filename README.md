# Talos Kubernetes lab

This lab grows one Kubernetes cluster in three stages: bootstrap CP1 once, join CP2 and CP3, then add workers. The lab's Talos version target is **v1.14.1**, and all five nodes were reported `Ready` on Kubernetes **v1.36.0** after worker 02 joined.

| Node | Role | IP | Render target | Generated config |
| --- | --- | --- | --- | --- |
| `srvcp1ab01` | Control plane | `10.87.44.20` | `cp1` | `_out/controlplane.yaml` |
| `srvcp1ab02` | Control plane | `10.87.44.221` | `cp2` | `_out/controlplane-cp2.yaml` |
| `srvcp1ab03` | Control plane | `10.87.44.34` | `cp3` | `_out/controlplane-cp3.yaml` |
| `srvwrk1ab01` | Worker | `10.87.44.248` | `w1` | `_out/worker.yaml` |
| `srvwrk1ab02` | Worker | `10.87.44.60` | `w2` | `_out/worker-w2.yaml` |

**If you are using this existing cluster, do not run bootstrap or reapply the installation configs in this guide.** The commands below document the build sequence and are for fresh, unconfigured nodes. Check live state before changing anything.

## The configuration pattern

`scripts/render.sh` generates a Talos machine config; it does **not** install or change a node. The script reuses the cluster settings and `secrets.yaml`, then applies a hostname patch for the selected node. The IP is passed through a command's `--nodes` flag when applying or checking that config; it is not a substitute for the hostname.

Use one generated file per node. In particular, `_out/worker.yaml` is **worker 01's finished config**, with hostname `srvwrk1ab01`; do not apply that exact file to worker 02. For a later worker, the generic target accepts a node ID and unique hostname:

```bash
bash scripts/render.sh worker w3 srvwrk1ab03
# Creates _out/worker-w3.yaml
```

The script currently has fixed targets for CP1–CP3 and workers 01–02. Adding CP4 requires a new control-plane target and hostname patch. Use the [Talos scale-up guide](https://docs.siderolabs.com/talos/v1.14/deploy-and-manage-workloads/scaling-up) for the underlying join behavior: a new node joins after its role-appropriate config is applied; it does not get another etcd bootstrap.

## Prepare a fresh lab

1. Copy `.env.example` to `.env` and review the cluster name, API endpoint, Talos installer image/version, Kubernetes version, and `INSTALL_DISK`. VM CPU, RAM, and disk **size** are configured in the hypervisor; `INSTALL_DISK` selects the device Talos will install onto.
2. Ensure `k8s-lab.internal` resolves from the controller **and every Talos node**. In this lab it currently resolves to CP1 (`10.87.44.20`); the DNS name alone does not make the Kubernetes API highly available. For production-like API failover, place a suitable load balancer or VIP behind that name.
3. Choose the cluster secrets deliberately. For a brand-new cluster, generate a new bundle with `talosctl gen secrets -o secrets-new.yaml` and set `SECRETS_FILE=secrets-new.yaml`. For an existing cluster, keep using its original `secrets.yaml`; changing secrets creates a different cluster identity. Never commit these files.
4. If the nodes need a particular DNS resolver, create `patches/resolver.yaml` with a Talos `ResolverConfig`, set `COMMON_PATCH=patches/resolver.yaml` in `.env`, then render. The resolver must answer `k8s-lab.internal` and public registry names.

Before **each** new node is configured, check its maintenance-mode version and actual writable disk:

```bash
talosctl version --insecure --nodes <NEW_NODE_IP>
talosctl get disks --insecure --nodes <NEW_NODE_IP>
```

Confirm the Talos version matches the intended installer image and that `INSTALL_DISK` selects the correct disk. Applying a config can install to that disk. Do not apply a file if its hostname, disk, cluster endpoint, or version is wrong.

`_out/`, `.env`, and secrets files are ignored by Git. Generated machine configs and `talosconfig` contain credentials; store backups securely off-cluster. `/docs/` is also intentionally local and ignored.

## Stage 1: bootstrap CP1 once

For a **new CP1 in maintenance mode**, render, inspect, and apply its config:

```bash
bash scripts/render.sh cp1
talosctl apply-config --insecure --nodes 10.87.44.20 --file _out/controlplane.yaml
```

Wait until the authenticated Talos API responds. Then bootstrap etcd **one time for the entire cluster** and obtain a separate Kubernetes client config:

```bash
export TALOSCONFIG="$PWD/_out/talosconfig"
talosctl config endpoint 10.87.44.20
talosctl config node 10.87.44.20
talosctl version --nodes 10.87.44.20
talosctl bootstrap --nodes 10.87.44.20
talosctl etcd members --nodes 10.87.44.20
talosctl kubeconfig _out/kubeconfig --merge=false --nodes 10.87.44.20
export KUBECONFIG="$PWD/_out/kubeconfig"
kubectl get nodes -o wide
```

Do not run `bootstrap` again when adding any other node. If CP1 already has a machine config or Kubernetes is running, these installation commands are **not** a repair procedure.

## Stage 2: join CP2, then CP3

For each new CP, perform the version/disk preflight above, render its own config, inspect the hostname and disk, and apply it. Complete CP2's checks before starting CP3:

```bash
bash scripts/render.sh cp2
talosctl apply-config --insecure --nodes 10.87.44.221 --file _out/controlplane-cp2.yaml
kubectl get nodes -o wide
talosctl etcd members --nodes 10.87.44.20
```

Confirm CP2 is `Ready` **and** appears as a non-learner etcd member. Then repeat for CP3:

```bash
bash scripts/render.sh cp3
talosctl apply-config --insecure --nodes 10.87.44.34 --file _out/controlplane-cp3.yaml
kubectl get nodes -o wide
talosctl etcd members --nodes 10.87.44.20
```

Two etcd members are only an intermediate stage: both are required for quorum. With three healthy CPs, Talos API access can use all three endpoints:

```bash
talosctl config endpoint 10.87.44.20 10.87.44.221 10.87.44.34
```

This improves **Talos API** access. Separately, `k8s-lab.internal:6443` still needs a load balancer or VIP for **Kubernetes API** failover.

## Stage 3: join workers

The same preflight/render/inspect/apply/check loop applies to workers. Worker 01 used `w1` and `_out/worker.yaml`; worker 02 used `w2` and `_out/worker-w2.yaml`. For a **new worker 02 in maintenance mode**, the commands are:

```bash
bash scripts/render.sh w2
talosctl apply-config --insecure --nodes 10.87.44.60 --file _out/worker-w2.yaml
kubectl get nodes -o wide
```

Worker registration may take a few minutes after `apply-config` reports success. Do not reapply or bootstrap just because an immediate `kubectl get nodes` does not yet list it. Confirm the expected unique hostname is `Ready` and inspect `kubectl get pods -A -o wide` for system pods.

For worker 03 and later, use `bash scripts/render.sh worker <node-id> <unique-hostname>`, then apply the generated `_out/worker-<node-id>.yaml` to that node's IP. If its disk or network needs different settings, adjust the generation inputs or patch before applying.

## After the cluster is up

- Use `kubectl get nodes -o wide`, `kubectl get pods -A -o wide`, and `talosctl etcd members --nodes 10.87.44.20` to check node, system-pod, and etcd health.
- `CP_WORKLOADS=true` in `.env` generated configs that permit workloads on CPs for the early CP-only lab. Now that workers exist, decide whether to keep that behavior. Changing `.env` affects **future renders only**; it does not change live CPs. To restore control-plane `NoSchedule`, plan pod migration/draining, review `talosctl patch mc --patch @cluster.yaml --nodes <CP_IP> --dry-run`, and patch live CPs one at a time.
- If a generated output already exists, `render.sh` refuses to replace it. After deliberately changing `.env` or a patch, use `TALOS_LAB_OVERWRITE=1 bash scripts/render.sh <target>`, inspect the new file, and do **not** automatically reapply it to a running node. The script preserves `_out/talosconfig` unless `TALOS_LAB_REGENERATE_CLIENT=1` is explicitly set.
- Keep Talos and Kubernetes versions aligned with the running cluster. After an upgrade, old generated configs may be stale; regenerate from the **same cluster secrets** before adding nodes. See the [Talos reproducible configuration guide](https://docs.siderolabs.com/talos/v1.14/configure-your-talos-cluster/system-configuration/reproducible-machine-configuration).
- Record VM vCPU/RAM/disk capacity and test changes one node at a time. Three healthy CPs protect etcd quorum; workload resilience also needs replicas spread across workers, reliable API access, and backups. Take an etcd snapshot to off-cluster storage before disruptive maintenance.
