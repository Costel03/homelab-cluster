# homelab-cluster

Builds the homelab from nothing: three VirtualBox VMs, a kubeadm cluster on
them, and a local image cache. All Ansible, no Vagrant.

What runs *in* the cluster lives in [homelab-gitops](https://github.com/Costel03/homelab-gitops)
and is reconciled by ArgoCD.

## Run it

```bash
make deps        # once — installs the kubernetes.core collection
make all         # registry, VMs, Kubernetes, ArgoCD
```

Stages are independent:

| Target | Does |
|---|---|
| `make registry` | Zot pull-through cache in WSL + the Windows port proxy |
| `make vms` | Creates and boots the VMs, waits for SSH |
| `make cluster` | containerd, kubeadm init/join, Calico, fetches the kubeconfig |
| `make apps` | MetalLB, ArgoCD, applies the app-of-apps |
| `make destroy` | Deletes the VMs and their disks |
| `make check` | Syntax-checks every playbook |

> Use `make`, or export `ANSIBLE_CONFIG=$PWD/ansible.cfg` first. Ansible ignores
> an `ansible.cfg` in a world-writable directory, and everything under `/mnt/c`
> is world-writable from WSL — without it the playbooks silently run against
> whatever `~/.ansible.cfg` points at.

## Changing the VMs

Sizing is per group, so both workers stay identical:

| File | Sets |
|---|---|
| `inventory/group_vars/masters.yml` | control-plane CPU / memory / disk |
| `inventory/group_vars/workers.yml` | worker CPU / memory / disk |
| `inventory/group_vars/all.yml` | network, versions, registry, GitOps repo |
| `inventory/hosts.yml` | which nodes exist and their addresses |

Current allocation is 12 vCPU and 20 GB of the host's 22 / 32.

Adding a worker is an entry in `hosts.yml` under `workers:` plus `make vms` —
it inherits the group sizing, and only the new VM is created.

Per-node overrides go in `inventory/host_vars/<name>.yml`.

## How a VM is built

1. `vm_image` downloads the Ubuntu 26.04 cloud image once, checks its SHA256,
   converts it to a VDI and stages it for VirtualBox.
2. `virtualbox_vm` full-clones that VDI per node, resizes it, and attaches a
   cloud-init seed ISO carrying the hostname, SSH key and static IP.
3. The NIC's MAC is derived from the node's IP, and netplan inside the guest
   matches on **that MAC** rather than an interface name — VirtualBox NIC
   naming varies by chipset, MACs do not.
4. `k8s_common` / `k8s_master` / `k8s_worker` install containerd and Kubernetes
   and run `kubeadm`.

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

## Registry

Zot runs as a systemd service in WSL, not in the cluster — an in-cluster
registry cannot serve the images needed to start itself, so it never helped a
cold rebuild. It is an on-demand pull-through cache: nothing needs pushing
into it, and containerd falls back to the upstreams if it is down.

WSL is NAT'd, so `make registry` also forwards `192.168.56.1:5000` to it. That
**triggers a UAC prompt** — `netsh portproxy` and the firewall rule need
Administrator. WSL changes address on every restart, so re-run `make registry`
after `wsl --shutdown`.

## Requirements

WSL Ubuntu with systemd, plus:

```bash
sudo apt-get install -y qemu-utils cloud-image-utils make
ansible-galaxy collection install -r requirements.yml
```

VirtualBox 7.x on Windows with a host-only adapter holding `192.168.56.1`.
Confirm which one that is and set `vbox_hostonly_adapter` in
`inventory/group_vars/all.yml`:

```bash
'/mnt/c/Program Files/Oracle/VirtualBox/VBoxManage.exe' list hostonlyifs
```
