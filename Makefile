# Ansible ignores an ansible.cfg that sits in a world-writable directory, and
# everything under /mnt/c is world-writable from WSL. Without ANSIBLE_CONFIG it
# silently falls back to ~/.ansible.cfg or /etc/ansible/hosts — which means the
# playbooks would run against whatever inventory that points at. Always go
# through these targets, or export ANSIBLE_CONFIG yourself.
export ANSIBLE_CONFIG := $(CURDIR)/ansible.cfg

PLAYBOOK := ansible-playbook
EXTRA    ?=

.PHONY: all registry runner vms cluster apps vault trust-ca destroy check deps inventory

all: ## Registry, runner, VMs, Kubernetes, ArgoCD, Vault
	$(PLAYBOOK) playbooks/site.yml -e runner_token=$(RUNNER_TOKEN) $(EXTRA)

registry: ## Zot pull-through cache in WSL
	$(PLAYBOOK) playbooks/registry.yml $(EXTRA)

# RUNNER_TOKEN is only needed the first time; it is single-use and expires
# after an hour. Get one from the repo's Settings > Actions > Runners.
RUNNER_TOKEN ?=
runner: ## GitHub Actions runner in WSL (first run: RUNNER_TOKEN=...)
	$(PLAYBOOK) playbooks/runner.yml -e runner_token=$(RUNNER_TOKEN) $(EXTRA)

vms: ## Create and boot the VirtualBox VMs
	$(PLAYBOOK) playbooks/vms.yml $(EXTRA)

cluster: ## kubeadm init/join across the nodes
	$(PLAYBOOK) playbooks/cluster.yml $(EXTRA)

apps: ## MetalLB, ArgoCD, app-of-apps
	$(PLAYBOOK) playbooks/apps.yml $(EXTRA)

vault: ## Initialise/unseal Vault and trust the homelab CA
	$(PLAYBOOK) playbooks/vault.yml $(EXTRA)

trust-ca: ## Export cert-manager's CA and trust it on Windows and WSL
	$(PLAYBOOK) playbooks/vault.yml --tags trust-ca $(EXTRA)

destroy: ## Delete the VMs and their disks
	$(PLAYBOOK) playbooks/destroy.yml -e confirm_destroy=yes $(EXTRA)

check: ## Syntax-check every playbook
	@for p in playbooks/*.yml; do \
	  printf '%-28s ' "$$p"; \
	  $(PLAYBOOK) --syntax-check "$$p" >/dev/null 2>&1 && echo OK || echo FAIL; \
	done

deps: ## Install the required Ansible collections
	ansible-galaxy collection install -r requirements.yml

inventory: ## Show the resolved inventory
	ansible-inventory --graph
