# homelab-cluster

Builds the homelab from nothing: three VirtualBox VMs, a kubeadm cluster on
them, the Zot registry and a GitHub Actions runner in WSL. All Ansible, no
Vagrant.

What runs *in* the cluster lives in [homelab-gitops](https://github.com/Costel03/homelab-gitops),
is verified and published to Zot by its CI, and is reconciled by ArgoCD.

## Run it

```bash
make deps        # once — installs the Ansible collections
make all         # registry, runner, VMs, Kubernetes, ArgoCD, Vault
```

Stages are independent:

| Target | Does |
|---|---|
| `make registry` | Zot in WSL (pull-through cache + CI's registry) and the Windows port proxy |
| `make runner` | GitHub Actions runner in WSL; first time needs `RUNNER_TOKEN=...` |
| `make vms` | Creates and boots the VMs, waits for SSH |
| `make cluster` | containerd, kubeadm init/join, Calico, fetches the kubeconfig |
| `make apps` | MetalLB, ArgoCD, applies the app-of-apps |
| `make vault` | Initialises and unseals Vault, then trusts the homelab CA |
| `make trust-ca` | Just the CA step, after cert-manager has issued it |
| `make destroy` | Deletes the VMs and their disks |
| `make check` | Syntax-checks every playbook |

> Use `make`, or export `ANSIBLE_CONFIG=$PWD/ansible.cfg` first. Ansible ignores
> an `ansible.cfg` in a world-writable directory, and everything under `/mnt/c`
> is world-writable from WSL — without it the playbooks silently run against
> whatever `~/.ansible.cfg` points at.

Every stage is safe to re-run. `make cluster` on a healthy cluster changes
nothing: workers only join when the control plane does not know them, and the
control plane is only rebuilt with `-e force_reinit=true`.

## First build

ArgoCD follows homelab-gitops' `deployed` branch, which CI creates the first
time it publishes. So the very first time, the order is:

| Step | Command |
|---|---|
| 1. Zot and the runner | `make registry runner RUNNER_TOKEN=<token>` — token from homelab-gitops > Settings > Actions > Runners > New self-hosted runner (single use, 1 h) |
| 2. Fill Zot | homelab-gitops > Actions > publish > Run workflow, tick *all* |
| 3. The cluster | `make vms cluster apps vault` |
| 4. Admin passwords | homelab-gitops' `scripts/seed-vault-secrets.sh` |

After that, `make all` rebuilds everything in one go: Zot and `deployed`
outlive the VMs.

## Changing the VMs

Sizing is per group, so both workers stay identical:

| File | Sets |
|---|---|
| `inventory/group_vars/masters.yml` | control-plane CPU / memory / disk |
| `inventory/group_vars/workers.yml` | worker CPU / memory / disk |
| `inventory/group_vars/all.yml` | network, versions, registry, runner, GitOps repo |
| `inventory/hosts.yml` | which nodes exist and their addresses |

Current allocation is 12 vCPU and 18 GB of the host's 22 / 32.

Adding a worker is an entry in `hosts.yml` under `workers:` plus `make vms` —
it inherits the group sizing, and only the new VM is created.

Per-node overrides go in `inventory/host_vars/<name>.yml`.

## How a VM is built

1. `vm_image` downloads the Ubuntu 24.04 cloud image once, checks its SHA256,
   converts it to a VDI and stages it for VirtualBox.
2. `virtualbox_vm` full-clones that VDI per node, resizes it, and attaches a
   cloud-init seed ISO carrying the hostname, SSH key and static IP.
3. The NIC's MAC is derived from the node's IP, and netplan inside the guest
   matches on **that MAC** rather than an interface name — VirtualBox NIC
   naming varies by chipset, MACs do not.
4. The VMs boot **one at a time**: each must answer on SSH and finish
   cloud-init before the next starts, and one that stalls is powered off and
   started again (up to `vm_boot_attempts`).
5. `k8s_common` / `k8s_master` / `k8s_worker` install containerd and Kubernetes
   and run `kubeadm`.

Why one at a time: WSL2 keeps Hyper-V on, so VirtualBox cannot use VT-x and
runs on the Windows Hypervisor Platform instead (the green turtle;
`VBox.log` says `fall back to NEM`). In that mode the timer VirtualBox
emulates for the guest stops firing when several Linux guests boot together —
the kernel hangs in its RAID6 benchmark or prints RCU stalls, and `VBox.log`
shows `TM: Giving up catch-up attempt`. A reset does not clear it; a fresh
start does.

VirtualBox is a Windows binary driven from WSL, so the VM plays use
`connection: local` and translate `/mnt/c/...` paths to `c:/...`.

## SSH

One ed25519 keypair at `~/.ssh/homelab`, copied to `C:\Users\iacob\.ssh\` with
its ACL tightened — `ssh.exe` refuses a private key other accounts can read.
Host entries are added to the Windows SSH config, so this works from
PowerShell and VS Code:

```powershell
ssh master
```

## Certificates

cert-manager (declared in homelab-gitops) mints a `homelab-ca` and signs a
90-day certificate per service, renewing 15 days before expiry. `make vault`
pulls that CA back out of the cluster and trusts it in WSL and on Windows —
the Windows import raises a **UAC prompt**.

Hostnames are `*.homelab` and still need hosts-file entries; the playbook
prints them at the end.

## Registry

Zot runs as a systemd service in WSL, not in the cluster — an in-cluster
registry cannot serve the images needed to start itself, so it never helped a
cold rebuild. It does two jobs:

| Job | How |
|---|---|
| CI's registry | homelab-gitops' publish workflow pushes scanned images to `scanned/<registry>/...` and Helm charts to `charts/`. |
| Pull-through cache | Each upstream is cached under its own prefix: `docker.io/...`, `quay.io/...`, `registry.k8s.io/...`, `ghcr.io/...`, ECR Public. |

containerd on every node routes those registries through Zot
(`override_path` in `certs.d/<registry>/hosts.toml`): the scanned copy first,
then the cache, then the upstream itself if Zot is down. So a node pulling
`quay.io/x:1.0` runs the digest CI scanned when there is one.

Pulls are anonymous. Pushing needs the `ci` user, whose password is generated
on the first run into `~/.config/homelab/zot-ci.password` and handed to the
runner. Zot also scans everything it stores for CVEs, including bootstrap
images CI never sees — browse `http://192.168.56.1:5000`.

WSL is NAT'd, so `make registry` also sets up the Windows side, once, behind
a **UAC prompt** (`netsh portproxy` and the firewall rule need Administrator):

| Piece | Why |
|---|---|
| `192.168.56.1:5000` forwarded to `[::1]:5000` | That is WSL's localhost relay, which survives WSL restarts; WSL's own IP changes on every one |
| `homelab-wsl` logon task | Keeps the distro running with a hidden `sleep infinity`, so Zot is up whenever you are logged in. WSL otherwise stops a distro soon after its last terminal closes, and with Zot down ArgoCD cannot render any app |

Later runs check both and skip the prompt.

## CI runner

A GitHub Actions runner for homelab-gitops runs as the unprivileged
`gh-runner` user in WSL (no sudo, no docker group), next to Zot, so the publish
workflow can push to `localhost:5000` without the registry ever being exposed.
Only that workflow uses it; pull-request checks run on GitHub-hosted runners.

The runner and Zot only run while WSL does; the `homelab-wsl` logon task
above keeps it running.

## Requirements

WSL Ubuntu with systemd, plus:

```bash
sudo apt-get install -y qemu-utils cloud-image-utils make python3-passlib python3-bcrypt
make deps
```

passlib and bcrypt hash Zot's htpasswd entry. The Kubernetes steps call
`kubectl` and `helm` directly, so the Python `kubernetes` client is not needed
(Ubuntu 24.04 packages 22.6, older than `kubernetes.core` accepts).

VirtualBox 7.x on Windows with a host-only adapter holding `192.168.56.1`.
Confirm which one that is and set `vbox_hostonly_adapter` in
`inventory/group_vars/all.yml`:

```bash
'/mnt/c/Program Files/Oracle/VirtualBox/VBoxManage.exe' list hostonlyifs
```
