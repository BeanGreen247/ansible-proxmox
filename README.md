# ansible-proxmox

A consolidated Ansible workspace for managing Proxmox VE infrastructure — from provisioning new VMs to keeping every guest up to date and monitoring live resource usage from a single repo.

---

## What's Inside

| Playbook | Purpose |
|---|---|
| `create-vm-from-iso-proxmox.yml` | Create VM shells on Proxmox via API |
| `fetch-iso.yml` | Download a boot ISO onto the Proxmox node |
| `build-debian-preseed-iso.yml` | Remaster a Debian ISO with a preseed config for unattended install |
| `auto-install-debian.yml` | Boot VMs from the preseed ISO and wait for install + SSH |
| `setup-debian-base.yml` | Install base packages and harden newly provisioned Debian VMs |
| `setup-base-ansible-proxmox.yml` | Bootstrap Python + pip + proxmoxer on the Proxmox node |
| `pve_vm_status.yml` | Report live CPU & RAM usage for all VMs/LXCs via API (read-only) |
| `update_upgrade.yml` | Mass-upgrade all LXC containers and VMs (apt/apk/dnf/pacman) |
| `setup-ansibleuser.yml` | One-time bootstrap: create `ansibleuser` with sudo + SSH key on hosts |
| `deploy-root-key.sh` | Push your SSH public key to root on all hosts (run before setup-ansibleuser) |

---

## Project Structure

```tree
.
├── ansible.cfg
├── collections
│   └── requirements.yml
├── deploy-root-key.sh
├── docs/
│   └── pipeline-walkthrough.md
├── group_vars
│   ├── proxmox-bms.yml
│   └── all/
│       ├── example_of_main.yml   ← copy to main.yml and fill in
│       ├── main.yml              ← gitignored, holds vault secrets
│       ├── preseed_vars.yml      ← Debian preseed / base-setup variables
│       └── vms.yml               ← VM definitions for provisioning
├── host_vars
│   ├── localhost.yml
│   └── <hostname>/
│       ├── .gitkeep
│       └── vault.yml             ← gitignored, per-host root password
├── inventory
│   └── hosts.ini
├── preseed
│   └── debian-preseed.cfg.j2
├── auto-install-debian.yml
├── build-debian-preseed-iso.yml
├── create-vm-from-iso-proxmox.yml
├── fetch-iso.yml
├── pve_vm_status.yml
├── setup-ansibleuser.yml
├── setup-base-ansible-proxmox.yml
├── setup-debian-base.yml
└── update_upgrade.yml
```

---

## Requirements

- Ansible 2.12+
- `~/.vault_pass.txt` with your Ansible Vault master password
- SSH key pair at `~/.ssh/id_rsa` / `~/.ssh/id_rsa.pub`
- Proxmox API token with VM/node read+write privileges

Install required collections:

```bash
ansible-galaxy collection install -r collections/requirements.yml -p ./collections
```

Install Python dependencies on the control node:

```bash
python3 -m pip install --user proxmoxer requests --break-system-packages
```

---

## First-Time Setup

### 1 — Configure credentials

```bash
cp group_vars/all/example_of_main.yml group_vars/all/main.yml
# Edit main.yml and fill in your Proxmox API token, vault passwords, node info, etc.
```

### 2 — Configure inventory

Edit `inventory/hosts.ini`:
- `[proxmox-bms]` — your Proxmox bare-metal node
- `[lxcs]` / `[vms]` — guest LXC containers and VMs you manage
- `[new-debian-vms]` — freshly provisioned VMs (added after `auto-install-debian.yml`)

### 3 — Bootstrap the Proxmox node (once)

```bash
ansible-playbook -i inventory/hosts.ini setup-base-ansible-proxmox.yml
```

### 4 — Bootstrap `ansibleuser` on guests (once per host)

```bash
# Push your SSH key to root on all hosts first
bash deploy-root-key.sh

# Then create the ansibleuser with sudo + key auth
ansible-playbook -i inventory/hosts.ini setup-ansibleuser.yml -u root --ask-pass
```

---

## VM Provisioning Pipeline

Full walkthrough: [`docs/pipeline-walkthrough.md`](docs/pipeline-walkthrough.md)

```
fetch-iso.yml
  → build-debian-preseed-iso.yml
    → create-vm-from-iso-proxmox.yml
      → auto-install-debian.yml
        → setup-debian-base.yml
```

### Step-by-step

**1. Download the Debian netinst ISO onto the Proxmox node:**

```bash
ansible-playbook -i inventory/hosts.ini fetch-iso.yml \
  --extra-vars '{"iso_url":"https://cdimage.debian.org/debian-cd/current/amd64/iso-cd/debian-13.1.0-amd64-netinst.iso",
                 "iso_file":"debian-13.1.0-amd64-netinst.iso"}'
```

**2. Build the preseed-injected ISO:**

```bash
ansible-playbook -i inventory/hosts.ini build-debian-preseed-iso.yml
```

**3. Create VM shells (define VMs in `group_vars/all/vms.yml` first):**

```bash
ansible-playbook -i inventory/hosts.ini create-vm-from-iso-proxmox.yml \
  --tags "createVMs,createDisks,mountIso,bootOrder"
```

**4. Boot VMs and run unattended Debian install:**

```bash
ansible-playbook -i inventory/hosts.ini auto-install-debian.yml
```

**5. Install base packages on freshly installed VMs:**

```bash
# Add the VM IP to [new-debian-vms] in inventory/hosts.ini, then:
ansible-playbook -i inventory/hosts.ini setup-debian-base.yml
```

---

## Monitor VM Resource Usage

Query live CPU and RAM for all VMs/LXCs via the Proxmox REST API (read-only, no SSH to nodes):

```bash
ansible-playbook -i inventory/hosts.ini pve_vm_status.yml
```

Output: one line per VM/LXC with CPU%, RAM used/allocated, plus running totals and headroom.

---

## Update & Upgrade All Guests

Detect the package manager on every LXC/VM and run the appropriate upgrade automatically:

```bash
ansible-playbook -i inventory/hosts.ini update_upgrade.yml
```

Target a subset:

```bash
ansible-playbook -i inventory/hosts.ini update_upgrade.yml --limit lxcs
ansible-playbook -i inventory/hosts.ini update_upgrade.yml --limit lxc-prometheus
```

Supported package managers: `apt` (Debian/Ubuntu), `apk` (Alpine Linux), `dnf` (RHEL/Fedora/CentOS), `pacman` (Arch Linux).

Hosts that require a reboot are rebooted automatically (or scheduled, for designated hosts like remote-desktop VMs).

---

## Vault Secrets

All secrets are encrypted with Ansible Vault and loaded automatically via `~/.vault_pass.txt`.

- `group_vars/all/main.yml` — API token secret, become password, VM end-user password hash
- `host_vars/<hostname>/vault.yml` — per-host root password (used by `deploy-root-key.sh`)

To encrypt a string:

```bash
ansible-vault encrypt_string --name 'variable_name' --vault-id default@prompt 'plaintext_value'
```

---

## Performance Tuning

`ansible.cfg` is pre-configured for fast parallel runs:
- `forks = 20` — 20 parallel host connections
- `pipelining = True` — reduces SSH round-trips
- SSH `ControlMaster/ControlPersist` — reuses connections

---

## Credit

Thomas Mozdren, 2026
