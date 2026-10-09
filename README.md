# Talos lab: one control plane to three, then workers

This repository prepares machine configurations for a staged Talos cluster. Rendering a file does not apply it to a node. The current lab plan uses CP1 at `10.87.44.20`, Kubernetes 1.36, and the stable Kubernetes API name `k8s-lab.internal`.

Talos 1.14 supports Kubernetes 1.36 ([support matrix](https://docs.siderolabs.com/talos/v1.14/getting-started/support-matrix)). Confirm the exact version booted on CP1 and use its matching installer image. The example image in `.env.example` is for the locally installed `talosctl` v1.14.1; a custom Image Factory build needs its own installer image. Confirm the target Kubernetes patch version too.

## Prepare once

1. Review `.env` (or copy `.env.example` to `.env` on a fresh checkout) and confirm the API endpoint, Talos version contract, installer image, Kubernetes version, disk, and DNS. Check the booted version with `talosctl version --insecure --nodes 10.87.44.20`. Keep `TALOS_VERSION_CONTRACT` fixed for repeatable generation until you intentionally upgrade Talos. `_out/` is the only generated-output directory used by this workflow; the root `talosconfig` is from the previous attempt.
2. Make `k8s-lab.internal` resolve to CP1's IP for stage 1 **from every Talos node and your workstation**. This requires an internal DNS record and DNS service reachable by the VMs. The previous public DNS addresses may not resolve `.internal`. If DHCP does not supply suitable DNS, create `patches/resolver.yaml` with a `ResolverConfig` document, set `COMMON_PATCH=patches/resolver.yaml` in `.env`, then render. Before calling the cluster highly available, move that name to a TCP load balancer or a Talos VIP backed by all three CPs. Keep the endpoint name unchanged in machine configurations.
3. Decide whether this is the old cluster identity. If it is, retain `secrets.yaml`. If this is a fresh cluster, generate a new bundle with `talosctl gen secrets -o secrets-new.yaml` and set `SECRETS_FILE=secrets-new.yaml` in `.env`. Never overwrite the old bundle. If CP1 was already configured, use the exact secrets from that running cluster; creating new secrets will produce a different cluster.
4. Check the actual install disk on each node in maintenance mode: `talosctl get disks --insecure --nodes <IP>`. `INSTALL_DISK=/dev/vda` is only the previous lab assumption. Set VM CPU, RAM, and disk **size** in the hypervisor; these YAML files set the install disk **device**.
5. The render script uses current Talos defaults for DNS; add a current `ResolverConfig` document before rendering if these VMs need specific DNS servers.

If internal DNS is needed, the contents of `patches/resolver.yaml` should be:

```yaml
apiVersion: v1alpha1
kind: ResolverConfig
nameservers:
  - address: <INTERNAL_DNS_SERVER_IP>
```

Replace the placeholder with the real DNS server address. This server must answer `k8s-lab.internal` and resolve image registry names needed during installation.

Machine configurations, `talosconfig`, and the secrets bundle contain credentials. `_out/`, `.env`, and `secrets-*.yaml` are ignored by Git. Keep backups of the secrets bundle and generated client config outside the cluster.

The fixed render targets map to these hostname patches and outputs:

| Target | Hostname patch | Generated file |
| --- | --- | --- |
| `cp1` | `patches/srvcp1ab01.yaml` | `_out/controlplane.yaml` |
| `cp2` | `patches/srvcp1ab02.yaml` | `_out/controlplane-cp2.yaml` |
| `cp3` | `patches/srvcp1ab03.yaml` | `_out/controlplane-cp3.yaml` |
| `w1` | `patches/srvwrk1ab01.yaml` | `_out/worker.yaml` |
| `w2` | `patches/srvwrk1ab02.yaml` | `_out/worker-w2.yaml` |

## Stage 1: CP1

Run `bash scripts/render.sh cp1`. Inspect `_out/controlplane.yaml`, especially the endpoint, `UnattendedInstallConfig` disk selector and installer image, and Kubernetes component versions. The CP1 hostname comes from `patches/srvcp1ab01.yaml`. To regenerate an existing output after changing `.env` or a patch, run `TALOS_LAB_OVERWRITE=1 bash scripts/render.sh cp1`. The script preserves `_out/talosconfig` when rerendering; set `TALOS_LAB_REGENERATE_CLIENT=1` only when you intentionally need a new client config. **Always inspect the generated hostname before applying the file**; changing a patch does not automatically update an existing `_out/` file.

If CP1 is only in Talos maintenance mode and belongs to this new cluster:

```sh
talosctl apply-config --insecure --nodes 10.87.44.20 --file _out/controlplane.yaml
export TALOSCONFIG="$PWD/_out/talosconfig"
talosctl config endpoint 10.87.44.20
talosctl config node 10.87.44.20
talosctl --nodes 10.87.44.20 version
talosctl --nodes 10.87.44.20 bootstrap
talosctl --nodes 10.87.44.20 health
talosctl --nodes 10.87.44.20 kubeconfig _out/kubeconfig
kubectl --kubeconfig _out/kubeconfig get nodes -o wide
```

Wait for CP1 to reboot and for authenticated `talosctl version` to work before bootstrapping. Run `bootstrap` **once per cluster**, only after applying CP1's config. If CP1 already has a machine config or Kubernetes is already running, do not apply this newly rendered file and do not bootstrap again until you compare its live cluster identity and configuration. The sequence above is for a fresh maintenance-mode node.

`CP_WORKLOADS=true` removes the default control-plane taint so application pods can run in the CP-only lab. It is optional if you only want to bring up Kubernetes system components. `patches/allow-scheduling.yaml` records that stage-1 choice. Talos 1.14 expresses this with `KubeNodeConfig`, rather than the old `cluster.allowSchedulingOnControlPlanes` field.

## Stage 2: CP2 and CP3

Fill `CP2_IP` and `CP3_IP` in `.env` when the VMs exist. Give each VM the same Talos minor version and a unique stable IP/hostname. The hostname patches are `patches/srvcp1ab02.yaml` and `patches/srvcp1ab03.yaml`. Generate one config at a time:

```sh
bash scripts/render.sh cp2
talosctl apply-config --insecure --nodes <CP2_IP> --file _out/controlplane-cp2.yaml
talosctl --nodes 10.87.44.20 etcd members
kubectl --kubeconfig _out/kubeconfig get nodes -o wide

bash scripts/render.sh cp3
talosctl apply-config --insecure --nodes <CP3_IP> --file _out/controlplane-cp3.yaml
talosctl --nodes 10.87.44.20 etcd members
kubectl --kubeconfig _out/kubeconfig get nodes -o wide
```

There is no second bootstrap. Wait for CP2 to join before applying CP3. Two CPs are only a transition: both are needed for etcd quorum. After three CPs are healthy, configure the API endpoint across all three and set `talosctl config endpoint <CP1_IP> <CP2_IP> <CP3_IP>` so Talos API access can fail over. The Talos API uses CP addresses, not the Kubernetes VIP.

To study resource scaling, record each VM's vCPU, RAM, and system disk size before and after a resize. With one CP, a resize requiring reboot interrupts the API. With three healthy CPs, resize or replace only one CP at a time, and verify etcd membership and Kubernetes readiness before touching the next. Workload capacity grows by adding workers; schedule replicas across separate workers to test application availability.

## Stage 3: workers

For worker 01, `bash scripts/render.sh w1` produces `_out/worker.yaml` using `patches/srvwrk1ab01.yaml`. For worker 02, `bash scripts/render.sh w2` produces `_out/worker-w2.yaml` using `patches/srvwrk1ab02.yaml`. For later workers, run `bash scripts/render.sh worker w3 srvwrk1ab03` to produce `_out/worker-w3.yaml` (choose a unique ID and hostname). If a generated file already exists, set `TALOS_LAB_OVERWRITE=1` to regenerate it after changing a patch. Inspect its hostname and install disk before applying it to a fresh maintenance-mode worker:

```sh
talosctl apply-config --insecure --nodes <WORKER_IP> --file _out/worker.yaml
kubectl --kubeconfig _out/kubeconfig get nodes -o wide
```

For worker 02, use `_out/worker-w2.yaml` and its own IP instead. Never apply the same hostname config to two live nodes.

Once workers can host your applications, set `CP_WORKLOADS=false` for future configs and patch **each live CP** with `cluster.yaml` using authenticated `talosctl patch mc --patch @cluster.yaml --nodes <CP_IP>`. First inspect the proposed change with `--dry-run`. Move or drain any application pods already running on CPs; changing the scheduling setting does not by itself migrate existing pods.

## Repeatable checks and article notes

At each stage, record the Talos version (`talosctl --nodes <IP> version`), Kubernetes nodes (`kubectl get nodes -o wide`), etcd members (`talosctl --nodes <CP_IP> etcd members`), endpoint target, VM CPU/RAM/disk, and what happened during a controlled node shutdown. Capture an etcd snapshot and keep it off-cluster before maintenance: `talosctl --nodes <CP_IP> etcd snapshot <backup-path>`.

After upgrading Kubernetes, old generated machine configs may contain stale component versions. Regenerate from the same secrets with the new version values before adding more nodes; do not reapply old full configs to live nodes. Talos documents this in its [scale-up](https://docs.siderolabs.com/talos/v1.14/deploy-and-manage-workloads/scaling-up) and [reproducible configuration](https://docs.siderolabs.com/talos/v1.14/configure-your-talos-cluster/system-configuration/reproducible-machine-configuration) guides.
