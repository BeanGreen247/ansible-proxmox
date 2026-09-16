# ansible-proxmox

> Automated Proxmox VE infrastructure management — VM provisioning, unattended OS installation, fleet upgrades, and live resource monitoring — driven entirely from Ansible.

![Ansible](https://img.shields.io/badge/ansible-%231A1918.svg?style=for-the-badge&logo=ansible&logoColor=white) ![Proxmox](https://img.shields.io/badge/proxmox-proxmox?style=for-the-badge&logo=proxmox&logoColor=%23E57000&labelColor=%232b2a33&color=%232b2a33) ![Debian](https://img.shields.io/badge/Debian-D70A53?style=for-the-badge&logo=debian&logoColor=white) ![MIT License](https://img.shields.io/badge/License-MIT-green.svg?style=for-the-badge)

---

## Table of Contents

1. [Overview](#overview)
2. [How It Works](#how-it-works)
3. [Repository Layout](#repository-layout)
4. [Requirements](#requirements)
5. [First-Time Setup](#first-time-setup)
6. [Playbook Reference](#playbook-reference)
7. [Configuration Reference](#configuration-reference)
8. [VM Definitions — `vms.yml`](#vm-definitions--vmsyml)
9. [LXC Definitions — `lxcs.yml`](#lxc-definitions--lxcsyml)
10. [Inventory](#inventory)
11. [Preseed Template](#preseed-template)
12. [Day-to-Day Operations](#day-to-day-operations)
13. [Vault — Managing Secrets](#vault--managing-secrets)
14. [Performance Tuning](#performance-tuning)
15. [User Guide](#user-guide)

---

## Overview

This project automates the full lifecycle of a Proxmox virtual machine:

- **Download** a Linux ISO to the Proxmox node
- **Inject** an unattended installer answer file (Debian preseed)
- **Create** the VM shell via the Proxmox REST API
- **Install** the OS with zero human interaction
- **Configure** the running system with a hardened baseline
- **Maintain** the entire fleet with parallel upgrades across apt, apk, dnf, and pacman

### Concepts at a Glance

| Term | Meaning |
|---|---|
| **Playbook** | A `.yml` file describing a sequence of tasks |
| **Inventory** | The list of machines Ansible manages (`inventory/hosts.ini`) |
| **Group vars** | Variables shared across a group of hosts (`group_vars/`) |
| **Host vars** | Variables specific to one host (`host_vars/<hostname>/`) |
| **Vault** | Ansible's encrypted secret store — keeps passwords out of plaintext |
| **Tags** | Labels that let you run a subset of a playbook (`--tags`) |
| **Collection** | Reusable packaged Ansible modules (we use `community.proxmox`) |
| **Preseed** | Debian's unattended installer answer file format |

---

## How It Works

### Provisioning Pipeline

```
fetch-iso.yml                       Download Debian netinst ISO to Proxmox node
  └─> build-debian-preseed-iso.yml  Inject preseed answer file, repack bootable ISO
        └─> create-vm-from-iso-proxmox.yml  Create VM shell via Proxmox API
              └─> auto-install-debian.yml   Boot VM, wait for unattended install
                    └─> setup-debian-base.yml  Harden SSH, install base packages
```

### Fleet Management

```
pve_vm_status.yml       Live CPU/RAM report for every guest (read-only)
update_upgrade.yml      Parallel upgrades across all guests (apt/apk/dnf/pacman)
wazuh_agent_deploy.yml  Deploy/configure Wazuh agent on all apt-based hosts
```

### LXC Provisioning

```
create-lxc-proxmox.yml  Create and start LXC containers via the Proxmox API
  └─> setup-ansibleuser.yml          Bootstrap ansibleuser on the new container
        └─> setup-lxc-2fa-master.yml (or other service playbook)
```

---

## Repository Layout

```
ansible-proxmox/
│
├── ansible.cfg                          Runtime settings (forks, pipelining, vault)
├── deploy-root-key.sh                   One-time: push SSH key to root on new hosts
│
├── fetch-iso.yml                        Step 1 – Download ISO to Proxmox node
├── build-debian-preseed-iso.yml         Step 2 – Inject preseed, repack ISO
├── create-vm-from-iso-proxmox.yml       Step 3 – Create VM shell via API
├── auto-install-debian.yml              Step 4 – Boot VM, wait for install + SSH
├── setup-debian-base.yml                Step 5 – Install base packages, harden SSH
├── create-lxc-proxmox.yml               Create LXC containers via Proxmox API
├── setup-base-ansible-proxmox.yml       Bootstrap – Install proxmoxer on Proxmox node
├── setup-ansibleuser.yml                Bootstrap – Create ansibleuser on all guests
├── pve_vm_status.yml                    Day-to-day – Live resource report
├── update_upgrade.yml                   Day-to-day – Upgrade all guests
├── wazuh_agent_deploy.yml               Security – Deploy Wazuh agent fleet-wide
├── setup-lxc-2fa-master.yml             Security – Nginx + Authelia TOTP gateway
│
├── inventory/
│   └── hosts.ini                        All managed hosts grouped by type
│
├── group_vars/
│   ├── proxmox-bms.yml                  Overrides for the Proxmox node group
│   └── all/
│       ├── example_of_main.yml          Template – copy to main.yml and fill in secrets
│       ├── main.yml                     (gitignored) API tokens, vault references
│       ├── preseed_vars.yml             All Debian install + preseed settings
│       ├── vms.yml                      VM definitions – single source of truth for VMs
│       └── lxcs.yml                     LXC definitions – single source of truth for containers
│
├── host_vars/
│   └── <hostname>/
│       └── vault.yml                    (gitignored) Encrypted per-host passwords/secrets
│
├── preseed/
│   └── debian-preseed.cfg.j2            Jinja2 template for the Debian answer file
│
├── templates/
│   ├── authelia/
│   │   ├── configuration.yml.j2         Authelia main config (TOTP, access rules)
│   │   └── users_database.yml.j2        Authelia internal user database
│   └── nginx/
│       ├── authelia-auth-portal.conf.j2  Nginx vhost for the Authelia login portal
│       └── authelia-service-vhost.conf.j2 Nginx vhost template per protected service
│
├── collections/
│   └── requirements.yml                 community.proxmox + community.general
│
└── docs/
    ├── pipeline-walkthrough.md          Detailed walkthrough with real output
    └── user-guide.md                    Zero-to-running-VM step-by-step guide
```

---

## Requirements

| Requirement | Notes |
|---|---|
| Ansible 2.12+ | On your control machine |
| `~/.vault_pass.txt` | Contains your Ansible Vault master passphrase |
| SSH key pair | `~/.ssh/id_rsa` / `~/.ssh/id_rsa.pub` |
| Proxmox API token | Needs `VM.Allocate`, `VM.Config.*`, `Datastore.AllocateSpace` |
| `sshpass` | Only required for `deploy-root-key.sh` |
| Python 3 | On the control machine and Proxmox node |

Install required Ansible collections:

```bash
ansible-galaxy collection install -r collections/requirements.yml -p ./collections
```

Install Python dependencies on the control machine:

```bash
pip3 install --user proxmoxer requests
```

---

## First-Time Setup

### 1 — Vault password file

```bash
echo "your_strong_passphrase" > ~/.vault_pass.txt
chmod 600 ~/.vault_pass.txt
```

### 2 — Credentials

```bash
cp group_vars/all/example_of_main.yml group_vars/all/main.yml
```

Edit `group_vars/all/main.yml` and set:

| Variable | Example | Description |
|---|---|---|
| `pm_api_host` | `192.168.0.222` | Proxmox node IP or hostname |
| `pm_api_port` | `8006` | Proxmox API port |
| `pm_node` | `pve` | Node name shown in the Proxmox UI |
| `api_user` | `root@pam` | Proxmox API user |
| `api_token_id` | `ansible-automation` | API token name |
| `pm_api_token_secret` | `!vault \|` block | Token secret — vault-encrypt this |
| `pm_api_validate_certs` | `false` | Set `false` for self-signed certs |

Encrypt a secret with vault:

```bash
ansible-vault encrypt_string --name 'pm_api_token_secret' 'your_token_secret_here'
```

Paste the output block into `main.yml`.

### 3 — Inventory

Edit `inventory/hosts.ini` — replace the example IPs and hostnames with your actual Proxmox node and guests. `[proxmox-bms]` must contain your Proxmox server.

### 4 — Bootstrap the Proxmox node

Run once — installs Python and `proxmoxer` on the node so Ansible API modules work:

```bash
ansible-playbook -i inventory/hosts.ini setup-base-ansible-proxmox.yml
```

### 5 — Bootstrap existing guests

Run once per host — creates the `ansible` automation user with SSH key and sudo:

```bash
# Push your SSH key to root on all hosts
bash deploy-root-key.sh

# Create the ansible user
ansible-playbook -i inventory/hosts.ini setup-ansibleuser.yml -u root --ask-pass
```

---

## Playbook Reference

### `fetch-iso.yml` — Download ISO

Downloads a Debian (or any) ISO to the Proxmox node's ISO storage. Skips if the file already exists.

```bash
ansible-playbook -i inventory/hosts.ini fetch-iso.yml \
  --extra-vars '{"iso_url":"https://cdimage.debian.org/debian-cd/current/amd64/iso-cd/debian-13.1.0-amd64-netinst.iso",
                 "iso_file":"debian-13.1.0-amd64-netinst.iso"}'
```

| Variable | Description |
|---|---|
| `iso_url` | Full download URL |
| `iso_file` | Filename to save on the node |
| `iso_dir` | Target directory (default: `/var/lib/vz/template/iso`) |

---

### `build-debian-preseed-iso.yml` — Repack ISO with Preseed

Takes the raw Debian netinst ISO and produces a fully unattended installer ISO:

1. Renders `preseed/debian-preseed.cfg.j2` with your variables
2. Extracts the source ISO into a temp directory
3. Injects `preseed.cfg` into the ISO root
4. Patches GRUB (EFI) and ISOLINUX (BIOS) boot menus to auto-start the installer
5. Repacks everything with `xorriso` into a new hybrid ISO
6. Moves the result to Proxmox ISO storage and cleans up

The hostname baked into the ISO is resolved in priority order:
1. `preseed_hostname` per VM in `vms.yml` (if non-empty)
2. `name` of the first preseed-flagged VM in `vms.yml`
3. Global `preseed_hostname` in `preseed_vars.yml` (fallback)

```bash
ansible-playbook -i inventory/hosts.ini build-debian-preseed-iso.yml
```

| Variable | Default | Description |
|---|---|---|
| `preseed_iso_src_file` | `debian-13.1.0-amd64-netinst.iso` | Source ISO filename |
| `preseed_iso_dest_file` | `debian-13-amd64-preseed.iso` | Output ISO filename |
| `preseed_hostname` | VM name | Hostname baked into the installer |
| `preseed_ansible_user` | `ansible` | User created during install |
| `preseed_ssh_pub_key` | `~/.ssh/id_rsa.pub` | SSH key injected for that user |
| `preseed_debian_suite` | `trixie` | Debian version codename |
| `preseed_timezone` | `UTC` | System timezone |
| `preseed_locale` | `en_US.UTF-8` | System locale |

---

### `create-vm-from-iso-proxmox.yml` — Create VM Shell

Talks to the Proxmox REST API from your local machine to create VM shells as defined in `vms.yml`. Does not install an OS — creates the hardware configuration only.

```bash
ansible-playbook -i inventory/hosts.ini create-vm-from-iso-proxmox.yml \
  --tags "createVMs,createDisks,mountIso,bootOrder"
```

| Tag | Action |
|---|---|
| `createVMs` | Create the VM (CPU, RAM, network) |
| `createDisks` | Create the system disk on scsi0 |
| `mountIso` | Mount the ISO as CD-ROM on ide2 |
| `bootOrder` | Set boot order and bootdisk |
| `diskResize` | Grow the disk (shrink not supported) |
| `removeVMs` | Delete VMs and their disks |
| `updateVMs` | Sync config changes from `vms.yml` to existing VMs |

---

### `create-lxc-proxmox.yml` — Create LXC Containers

Creates and starts LXC containers via the Proxmox API using definitions from `group_vars/all/lxcs.yml`. Idempotent — existing containers (matched by vmid) are left untouched.

```bash
# Create all containers defined in lxcs.yml
ansible-playbook create-lxc-proxmox.yml --tags createLXCs

# Create and immediately start them
ansible-playbook create-lxc-proxmox.yml --tags createLXCs,startLXCs

# Apply spec changes from lxcs.yml to existing containers (cores, memory, swap, features, etc.)
ansible-playbook create-lxc-proxmox.yml --tags updateLXCs

# Update a single container
ansible-playbook create-lxc-proxmox.yml --limit lxc-grafana --tags updateLXCs

# Start already-created containers
ansible-playbook create-lxc-proxmox.yml --tags startLXCs

# Stop containers (explicit opt-in required)
ansible-playbook create-lxc-proxmox.yml --tags stopLXCs

# Destroy containers + rootfs (DESTRUCTIVE — explicit opt-in required)
ansible-playbook create-lxc-proxmox.yml --tags removeLXCs
```

| Tag | Action |
|---|---|
| `createLXCs` | Create container shells (idempotent — skips existing vmids) |
| `updateLXCs` | Push spec changes from `lxcs.yml` to running containers (cores/memory/swap/features) |
| `startLXCs` | Start containers |
| `stopLXCs` | Stop containers (explicit opt-in) |
| `removeLXCs` | Destroy containers + rootfs (explicit opt-in, DESTRUCTIVE) |

> **Note:** `updateLXCs` does not resize the rootfs or change IP/network config — those require a stop/recreate cycle.

After creating a new container, bootstrap it:

```bash
ansible-playbook setup-ansibleuser.yml --limit lxc-mycontainer -u root --ask-pass
```

---

### `auto-install-debian.yml` — Unattended OS Install

Boots preseed-flagged VMs and waits for the Debian installer to complete and SSH to become available. No human interaction required after this starts.

Three internal plays:
1. **Boot** — starts each VM via the Proxmox API
2. **Discover & wait** — polls the qemu-guest-agent API for the IP, then waits for SSH
3. **Finalize** — verifies SSH access, ejects the install ISO, switches boot order to disk-first, updates `inventory/hosts.ini`

```bash
ansible-playbook -i inventory/hosts.ini auto-install-debian.yml
```

| Variable | Default | Description |
|---|---|---|
| `preseed_boot_wait_seconds` | `30` | Seconds after power-on before checking SSH |
| `preseed_ssh_wait_timeout` | `2400` (40 min) | Max seconds to wait for SSH |
| `preseed_ssh_wait_delay` | `30` | Seconds between SSH check attempts |

---

### `setup-debian-base.yml` — Post-Install Baseline

Runs on hosts in `[new-debian-vms]` to configure a consistent, hardened baseline. Idempotent — safe to re-run.

1. Removes the cdrom APT source left by the installer
2. Updates APT index and runs `safe-upgrade`
3. Installs base packages from `debian_base_packages`
4. Sets `vim` as the system default editor
5. Ensures `qemu-guest-agent` is enabled and running
6. Disables SSH password authentication (key-only enforced)
7. Ensures the `ansible` user has `NOPASSWD` sudo
8. Prints a per-host completion summary

```bash
# All hosts in [new-debian-vms]
ansible-playbook -i inventory/hosts.ini setup-debian-base.yml

# Direct by IP (no inventory entry needed)
ansible-playbook -i inventory/hosts.ini setup-debian-base.yml --limit "192.168.0.50"
```

Default base packages: `htop`, `btop`, `vim`, `curl`, `wget`, `git`, `tmux`, `net-tools`

---

### `setup-base-ansible-proxmox.yml` — Bootstrap Proxmox Node

One-time setup that installs Python 3, pip, and `proxmoxer` on the Proxmox node. Run before any other playbook.

```bash
ansible-playbook -i inventory/hosts.ini setup-base-ansible-proxmox.yml
```

---

### `setup-ansibleuser.yml` — Create Automation User on Guests

Creates the `ansibleuser` on every managed host with:
- Password login disabled — SSH key auth only
- Passwordless sudo (`NOPASSWD: ALL`)
- Your SSH public key pre-installed

Handles Alpine Linux automatically (installs `python3` and `sudo` first via raw shell).

```bash
ansible-playbook -i inventory/hosts.ini setup-ansibleuser.yml -u root --ask-pass

# Target a single host
ansible-playbook -i inventory/hosts.ini setup-ansibleuser.yml \
  -u root --ask-pass --limit lxc-prometheus
```

---

### `pve_vm_status.yml` — Live Resource Report

Queries the Proxmox API and prints a one-line-per-guest resource table. Read-only.

Output per guest: node, VMID, name, status, CPU%, RAM used / allocated (GiB + %).  
Also prints: total running guests, RAM headroom, and average CPU across running guests.

```bash
ansible-playbook -i inventory/hosts.ini pve_vm_status.yml
```

---

### `update_upgrade.yml` — Upgrade All Guests

Detects the package manager on each host and runs the appropriate upgrade. Per-package old→new version reporting. Reboots automatically where required.

**Supported package managers:**

| OS | Package manager | Commands run |
|---|---|---|
| Debian / Ubuntu | `apt` | `apt update` → `apt dist-upgrade --autoremove` |
| Alpine Linux | `apk` | `apk update` → `apk upgrade` |
| RHEL / Fedora | `dnf` | `dnf upgrade --autoremove` |
| Arch Linux | `pacman` | `pacman -Syu` |

```bash
# Upgrade everything
ansible-playbook -i inventory/hosts.ini update_upgrade.yml

# LXC containers only
ansible-playbook -i inventory/hosts.ini update_upgrade.yml --limit lxcs

# VMs only
ansible-playbook -i inventory/hosts.ini update_upgrade.yml --limit vms

# One host
ansible-playbook -i inventory/hosts.ini update_upgrade.yml --limit lxc-prometheus
```

**Example end-of-run summary:**

```
TASK [[summary] Upgrade report — lxc-prometheus]
ok: [lxc-prometheus] => {
    "msg": [
        "════════════════════════════════════════════════",
        "UPGRADE SUMMARY  ▸  lxc-prometheus",
        "OS           : Ubuntu 25.04",
        "Packages (0):",
        "  (none - already up to date)",
        "Upgrade size : N/A",
        "Disk free (/) : 7.1G",
        "Reboot       : NOT NEEDED",
        "════════════════════════════════════════════════"
    ]
}
ok: [lxc-grafana] => {
    "msg": [
        "════════════════════════════════════════════════",
        "UPGRADE SUMMARY  ▸  lxc-grafana",
        "OS           : Ubuntu 25.04",
        "Packages (0):",
        "  (none - already up to date)",
        "Upgrade size : N/A",
        "Disk free (/) : 7.1G",
        "Reboot       : NOT NEEDED",
        "════════════════════════════════════════════════"
    ]
}
ok: [vm-debian-remote-desktop] => {
    "msg": [
        "════════════════════════════════════════════════",
        "UPGRADE SUMMARY  ▸  vm-debian-remote-desktop",
        "OS           : Debian 13.4",
        "Packages (1):",
        "  brave-browser-nightly                1.91.33  ->  1.91.37",
        "Upgrade size : N/A",
        "Disk free (/) : 88G",
        "Reboot       : NOT NEEDED",
        "════════════════════════════════════════════════"
    ]
}
ok: [vm-alpine-gitea-dev.server.wow] => {
    "msg": [
        "════════════════════════════════════════════════",
        "UPGRADE SUMMARY  ▸  vm-alpine-gitea-dev.server.wow",
        "OS           : Alpine 3.23.3",
        "Packages (0):",
        "  (none — already up to date)",
        "Upgrade size : N/A",
        "Disk free (/) : 23.6G",
        "Reboot       : NOT NEEDED",
        "════════════════════════════════════════════════"
    ]
}
```

---

### `wazuh_agent_deploy.yml` — Deploy Wazuh Security Agent

Installs and registers the Wazuh 4.x agent on all apt-based hosts in the inventory. Alpine and other non-apt hosts are skipped automatically. The Wazuh manager host (`lxc-wazuh`) is always excluded to prevent overwriting the server.

```bash
# Deploy to all hosts
ansible-playbook wazuh_agent_deploy.yml

# VMs only
ansible-playbook wazuh_agent_deploy.yml --limit vms

# LXCs only (excluding the Wazuh server itself)
ansible-playbook wazuh_agent_deploy.yml --limit 'lxcs:!lxc-wazuh'

# Single host
ansible-playbook wazuh_agent_deploy.yml --limit vm-debian-dev.server.wow
```

Key vars (set in the playbook):

| Variable | Default | Description |
|---|---|---|
| `wazuh_manager_ip` | `192.168.0.243` | IP of the Wazuh manager (lxc-wazuh) |
| `wazuh_agent_name` | `inventory_hostname` | Agent display name in the Wazuh dashboard |

The agent package is pinned with `apt-mark hold` after install to prevent accidental version upgrades.

---

### `setup-lxc-2fa-master.yml` — TOTP Gateway (Nginx + Authelia)

Installs Nginx and Authelia on `lxc-2fa-master` to provide TOTP two-factor authentication in front of services that have no native MFA support (Wazuh dashboard, Grafana, etc.).

**Architecture:**
```
Browser → lxc-2fa-master:443 (Nginx) → Authelia TOTP portal
                                       → backend service (Wazuh, Grafana, …)
```

Backend services stay on their existing IPs/ports — never directly exposed. All TOTP enforcement happens at the Nginx `auth_request` layer.

```bash
# Full deploy
ansible-playbook setup-lxc-2fa-master.yml

# Nginx config only
ansible-playbook setup-lxc-2fa-master.yml --tags nginx

# Authelia config only
ansible-playbook setup-lxc-2fa-master.yml --tags authelia
```

Required vault vars in `host_vars/lxc-2fa-master/vault.yml`:

| Variable | How to generate |
|---|---|
| `vault_become_password` | sudo password for the LXC |
| `vault_authelia_jwt_secret` | `python3 -c "import secrets; print(secrets.token_hex(32))"` |
| `vault_authelia_session_secret` | same as above |
| `vault_authelia_storage_encryption_key` | same as above |
| `vault_authelia_user_password_hash` | `authelia crypto hash generate argon2 --password 'yourpassword'` |

**First-time order:**
1. Create `lxc-2fa-master` — `ansible-playbook create-lxc-proxmox.yml --tags createLXCs,startLXCs`
2. Bootstrap — `ansible-playbook setup-ansibleuser.yml --limit lxc-2fa-master -u root --ask-pass`
3. Fill in and encrypt `host_vars/lxc-2fa-master/vault.yml`
4. Deploy — `ansible-playbook setup-lxc-2fa-master.yml`
5. Add DNS entries for `auth.lan`, `wazuh.lan`, `grafana.lan` → `192.168.0.242`
6. Browse to `https://auth.lan`, log in, scan TOTP QR code

To add more protected services, add an entry to `authelia_services` in the playbook and re-run.

---

### `deploy-root-key.sh` — Push SSH Key to Root

A Bash script (not a playbook) that uses the vault-encrypted root passwords in `host_vars/<hostname>/vault.yml` to push your SSH public key to root on every host via `sshpass` + `ssh-copy-id`. Run this once before `setup-ansibleuser.yml`.

**Requires:** `sshpass` installed on the control machine.

```bash
bash deploy-root-key.sh
```

---

## Configuration Reference

### `group_vars/all/main.yml`

Your main credentials file. **Never commit this to git** — it is gitignored. Copy from `example_of_main.yml`:

```bash
cp group_vars/all/example_of_main.yml group_vars/all/main.yml
```

| Variable | Description |
|---|---|
| `pm_api_host` | Proxmox node IP or hostname |
| `pm_api_port` | Proxmox API port (default: `8006`) |
| `pm_node` | Node name shown in the Proxmox UI |
| `api_user` | Proxmox API user (e.g., `root@pam`) |
| `api_token_id` | API token name |
| `pm_api_token_secret` | Token secret — vault-encrypt this value |
| `pm_api_validate_certs` | `false` for self-signed certs (typical home lab) |
| `ansible_become_password` | Sudo password for Ansible — vault-encrypt this |

---

### `group_vars/all/preseed_vars.yml`

All settings that control the Debian installer and post-install baseline:

- **ISO settings** — source filename, output filename, storage path on the node
- **Debian mirror** — mirror host and proxy for package downloads
- **Locale / keyboard / timezone** — system settings baked into every VM
- **Ansible user** — username, SSH key path, sudo config
- **`debian_base_packages`** — package list installed by `setup-debian-base.yml`
- **Timing** — `preseed_ssh_wait_timeout` (default 40 min), boot wait seconds

---

### `ansible.cfg`

| Setting | Value | Purpose |
|---|---|---|
| `forks` | `20` | Run tasks on 20 hosts simultaneously |
| `pipelining` | `True` | Reduces SSH round-trips — significantly faster |
| `vault_password_file` | `~/.vault_pass.txt` | Auto-loads vault key — no interactive prompts |
| `collections_paths` | `./collections:...` | Looks in local `collections/` folder first |
| `ControlMaster=auto` | SSH option | Reuses SSH connections across tasks |
| `ControlPersist=60s` | SSH option | Keeps connection alive for 60 s between tasks |

---

## LXC Definitions — `lxcs.yml`

`group_vars/all/lxcs.yml` is the **single source of truth** for all LXC containers. Each entry in the `lxcs:` list defines one container. The `create-lxc-proxmox.yml` playbook merges these with `lxc_defaults` — any field omitted in `lxcs.yml` uses the default.

### Minimum entry

```yaml
- name: lxc-mycontainer
  vmid: 120
  hostname: lxc-mycontainer
  ip: "192.168.0.250/24"
```

### Full field reference

| Field | Default | Description |
|---|---|---|
| `vmid` | — | ✅ Required. Proxmox container ID (must be unique) |
| `hostname` | — | ✅ Required. Container hostname |
| `ip` | — | ✅ Required. Static IP in CIDR notation (`x.x.x.x/24`) |
| `cores` | `1` | vCPU count |
| `memory` | `512` | RAM in MiB |
| `swap` | `512` | Swap in MiB |
| `rootfs_size_gb` | `8` | Root filesystem size in GB |
| `storage` | `local-lvm` | Proxmox storage pool for the rootfs |
| `replicate` | `0` | Disk replication (`0` = off, `1` = on) |
| `onboot` | `true` | Auto-start with Proxmox host |
| `unprivileged` | `true` | Run as unprivileged container (recommended) |
| `ostemplate` | `debian-13-standard` | CT template (must exist on the node) |
| `gateway` | `192.168.0.1` | Default gateway |
| `nameserver` | `192.168.0.1` | DNS server |
| `bridge` | `vmbr0` | Network bridge |
| `iface_name` | `eno1` | Interface name inside the container. Debian 12/13 LXCs use `eno1` (predictable names). |
| `features` | `[]` | Extra LXC features. **`nesting=1` is required on Debian 13 (systemd 257)** — without it `systemd-networkd` fails to start and the container loses its IP. |
| `description` | `Managed by Ansible` | Container description shown in Proxmox UI |

---

## VM Definitions — `vms.yml`

`group_vars/all/vms.yml` is the **single source of truth** for all VMs. Each entry in the `vms:` list defines one VM. Changes here are applied to Proxmox with `create-vm-from-iso-proxmox.yml --tags updateVMs`.

### Minimum — Manual install VM

```yaml
- name: "my-vm"
  vmid: 601
  memory: 2048
  cores: 2
  net0: "virtio,bridge=vmbr0"
  ostype: "l26"
  agent: 1
  disk_size_gb: 32
  storage: "local-lvm"
  iso_storage: "local"
  iso_path: "iso/"
  iso_file: "debian-13.1.0-amd64-netinst.iso"
```

### Minimum — Automated preseed install VM

```yaml
- name: "my-auto-vm"
  vmid: 602
  boot: "order=ide2;scsi0;net0"
  bootdisk: scsi0
  memory: 1024
  cores: 2
  net0: "virtio,bridge=vmbr0"
  ostype: "l26"
  agent: 1
  disk_size_gb: 32
  storage: "local-lvm"
  iso_storage: "local"
  iso_path: "iso/"
  iso_file: "debian-13-amd64-preseed.iso"
  preseed_install: true
  # preseed_hostname: "my-auto-vm"   # omit to use 'name' as hostname
  # preseed_ip: "192.168.0.x"        # omit for DHCP
  # preseed_gateway: "192.168.0.1"   # required when preseed_ip is set
```

### Field Reference

| Field | Required | Example | Description |
|---|---|---|---|
| `name` | ✅ | `"my-vm"` | VM display name in Proxmox |
| `vmid` | ✅ | `500` | Proxmox VM ID (must be unique) |
| `ostype` | ✅ | `"l26"` | OS type: `l26`=Linux, `win10/win11`=Windows |
| `iso_storage` | ✅ | `"local"` | Proxmox storage containing the ISO |
| `iso_path` | ✅ | `"iso/"` | Path within that storage |
| `iso_file` | ✅ | `"debian-13-amd64-preseed.iso"` | ISO filename |
| `memory` | — | `1024` | RAM in MiB (default: `1024`) |
| `cores` | — | `2` | vCPU count (default: `1`) |
| `disk_size_gb` | — | `32` | Disk size in GB (default: `20`) |
| `storage` | — | `"local-lvm"` | Disk storage pool (default: `local-lvm`) |
| `net0` | — | `"virtio,bridge=vmbr0"` | Network interface |
| `agent` | — | `1` | Enable qemu-guest-agent (required for IP discovery) |
| `boot` | — | `"order=ide2;scsi0;net0"` | Boot order — set `ide2` first for ISO install |
| `bootdisk` | — | `"scsi0"` | Primary boot disk identifier |
| `onboot` | — | `false` | Auto-start with Proxmox host |
| `preseed_install` | — | `true` | Flag this VM for unattended install |
| `preseed_hostname` | — | `"my-vm"` | Hostname baked into the ISO (defaults to `name`) |
| `preseed_ip` | — | `"192.168.0.50"` | Static IP for ISOLINUX (omit for DHCP) |
| `preseed_gateway` | — | `"192.168.0.1"` | Required when `preseed_ip` is set |

---

## Inventory

`inventory/hosts.ini` groups every managed machine:

| Group | Used by | Contents |
|---|---|---|
| `[proxmox-bms]` | Most playbooks | Proxmox bare-metal server(s) |
| `[lxcs]` | `update_upgrade.yml`, `setup-ansibleuser.yml`, `wazuh_agent_deploy.yml` | LXC containers |
| `[vms]` | `update_upgrade.yml`, `setup-ansibleuser.yml`, `wazuh_agent_deploy.yml` | Running VMs |
| `[new-debian-vms]` | `setup-debian-base.yml` | Freshly installed VMs (temporary) |

Each host line:

```ini
hostname  ansible_host=192.168.0.x  ansible_user=ansible  ansible_ssh_private_key_file=~/.ssh/id_rsa
```

---

## Preseed Template

`preseed/debian-preseed.cfg.j2` is a Jinja2 template that renders into a complete Debian installer answer file. It covers:

| Section | What it configures |
|---|---|
| Localization | Language, locale, keyboard layout |
| Network | DHCP by default; static IP if `preseed_ip` is set |
| Mirror | APT mirror host and proxy |
| Clock | UTC, NTP enabled |
| Partitioning | Full disk, single partition (atomic — ideal for VMs) |
| Users | Root locked; `ansible` user with SSH key and NOPASSWD sudo |
| APT sources | cdrom source disabled to prevent update failures after ISO ejection |
| Packages | Base packages + `qemu-guest-agent` + `preseed_extra_packages` |
| Finish | Eject CD, power off (VM halts so Ansible can eject ISO and fix boot order) |

---

## Day-to-Day Operations

```bash
# Check live CPU/RAM usage across all guests
ansible-playbook -i inventory/hosts.ini pve_vm_status.yml

# Upgrade all guests
ansible-playbook -i inventory/hosts.ini update_upgrade.yml

# Upgrade only LXC containers
ansible-playbook -i inventory/hosts.ini update_upgrade.yml --limit lxcs

# Upgrade only VMs
ansible-playbook -i inventory/hosts.ini update_upgrade.yml --limit vms

# Upgrade a single host
ansible-playbook -i inventory/hosts.ini update_upgrade.yml --limit lxc-prometheus
```

---

## Vault — Managing Secrets

All secrets are encrypted with Ansible Vault. The vault password is read automatically from `~/.vault_pass.txt` — no interactive prompts.

**Where secrets live:**

| File | Contains |
|---|---|
| `group_vars/all/main.yml` | Proxmox API token secret, sudo password |
| `host_vars/<hostname>/vault.yml` | Per-host root password |

**Common vault operations:**

```bash
# Encrypt a new value (paste output into a YAML file)
ansible-vault encrypt_string --name 'variable_name' 'plaintext_value'

# View an encrypted file
ansible-vault view host_vars/lxc-prometheus/vault.yml

# Edit an encrypted file
ansible-vault edit host_vars/lxc-prometheus/vault.yml

# Re-key all vault files (change master password)
ansible-vault rekey group_vars/all/main.yml host_vars/*/vault.yml
```

---

## Performance Tuning

`ansible.cfg` is pre-configured for fast parallel execution:

| Setting | Effect |
|---|---|
| `forks = 20` | Connects to 20 hosts simultaneously |
| `pipelining = True` | Reduces SSH round-trips — 2–3× faster task execution |
| `ControlMaster=auto` | Reuses SSH connections across tasks on the same host |
| `ControlPersist=60s` | Keeps the connection open for 60 s between tasks |

> **Note:** `pipelining = True` requires that `requiretty` is **not** set in `/etc/sudoers` on managed hosts. The `setup-ansibleuser.yml` playbook configures this correctly via the `NOPASSWD` sudoers rule.

---

## User Guide

For a complete zero-to-running-VM walkthrough with real example output at every step, see:

**[docs/user-guide.md](docs/user-guide.md)**

For detailed pipeline output and troubleshooting examples:

**[docs/pipeline-walkthrough.md](docs/pipeline-walkthrough.md)**

---

## Collections

```bash
ansible-galaxy collection install -r collections/requirements.yml -p ./collections
```

| Collection | Version | Used for |
|---|---|---|
| `community.proxmox` | ≥ 1.3.0 | `proxmox_kvm`, `proxmox_disk`, `proxmox_vm_info` |
| `community.general` | ≥ 11.0.0 | `alternatives`, `authorized_key`, general utilities |

---

*Built and maintained by Thomas Mozdren — 2026*
