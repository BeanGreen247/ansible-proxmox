# ansible-proxmox

A consolidated Ansible workspace for managing Proxmox VE infrastructure — from provisioning new VMs to keeping every guest up to date and monitoring live resource usage from a single repo.

This project automates the entire lifecycle of a virtual machine: downloading a Linux ISO, injecting an automated installer config, creating the VM on Proxmox, installing the OS with zero human input, and then configuring the running system — all from the command line.

---

## Table of Contents

1. [Background — What Is This?](#background--what-is-this)
2. [How It All Fits Together](#how-it-all-fits-together)
3. [Repository Layout — Every File Explained](#repository-layout--every-file-explained)
   - [Playbooks](#playbooks)
   - [Configuration & Variables](#configuration--variables)
   - [Inventory](#inventory)
   - [Preseed Template](#preseed-template)
   - [Collections & Tooling](#collections--tooling)
4. [Requirements](#requirements)
5. [First-Time Setup](#first-time-setup)
6. [VM Provisioning Pipeline](#vm-provisioning-pipeline)
7. [Day-to-Day Operations](#day-to-day-operations)
8. [Vault — Storing Secrets Safely](#vault--storing-secrets-safely)
9. [Performance Tuning](#performance-tuning)
10. [Complete User Guide — Zero to Running VM](#complete-user-guide--zero-to-running-vm)

---

## Background — What Is This?

### Ansible

**Ansible** is an automation tool that runs tasks on remote machines over SSH.
You write **playbooks** (YAML files) that describe what should happen — install this package, create this user, reboot this server — and Ansible connects to the target machine and makes it happen.

Key concepts used in this project:

| Term | What it means |
|---|---|
| **Playbook** | A `.yml` file with a list of tasks to run |
| **Task** | A single action (install a package, copy a file, etc.) |
| **Module** | The built-in function that performs a task (`apt`, `copy`, `file`, etc.) |
| **Inventory** | The list of machines Ansible knows about (`inventory/hosts.ini`) |
| **Group vars** | Variables that apply to a whole group of machines (`group_vars/`) |
| **Host vars** | Variables specific to one machine (`host_vars/`) |
| **Vault** | Ansible's encrypted secret store — keeps passwords out of plaintext files |
| **Tags** | Labels on tasks that let you run only a subset of a playbook (`--tags`) |
| **Role / Collection** | Reusable, packaged Ansible code (we use `community.proxmox`) |

### Proxmox VE

**Proxmox VE** is an open-source hypervisor — software that runs virtual machines (VMs) and LXC containers on a physical server. It has a web UI and a full REST API. This project talks to that API to create and manage VMs without any manual clicking.

### Preseed

**Preseed** is the Debian installer's answer file system. Instead of a human clicking through the installer screens, a `preseed.cfg` file answers every question in advance — locale, keyboard, partitioning, user accounts, packages. The result is a fully unattended Debian installation that runs start-to-finish with no input.

---

## How It All Fits Together

The project has two modes of operation:

**1. VM Provisioning Pipeline** — create a fresh VM from scratch:

```
fetch-iso.yml               Download the Debian netinst ISO to the Proxmox node
  └─> build-debian-preseed-iso.yml     Inject a preseed answer file into the ISO
        └─> create-vm-from-iso-proxmox.yml    Create the VM shell via Proxmox API
              └─> auto-install-debian.yml     Boot VM, wait for Debian to install itself
                    └─> setup-debian-base.yml Install base packages, harden SSH
```

**2. Fleet Management** — ongoing maintenance of existing VMs and LXC containers:

```
pve_vm_status.yml    Live CPU/RAM report for all guests (read-only)
update_upgrade.yml   Mass upgrade all guests (apt / apk / dnf / pacman)
```

---

## Repository Layout — Every File Explained

```
ansible-proxmox/
│
├── ansible.cfg                         ← Ansible runtime settings
├── deploy-root-key.sh                  ← One-time script: push SSH key to root on all hosts
│
├── Playbooks (the automation scripts)
│   ├── fetch-iso.yml                   ← Step 1: download ISO to Proxmox node
│   ├── build-debian-preseed-iso.yml    ← Step 2: inject preseed into ISO
│   ├── create-vm-from-iso-proxmox.yml  ← Step 3: create VM shell via API
│   ├── auto-install-debian.yml         ← Step 4: boot VM, wait for install + SSH
│   ├── setup-debian-base.yml           ← Step 5: install packages, harden SSH
│   ├── setup-base-ansible-proxmox.yml  ← Bootstrap: install Python/proxmoxer on node
│   ├── setup-ansibleuser.yml           ← Bootstrap: create ansibleuser on all guests
│   ├── pve_vm_status.yml               ← Day-to-day: live VM resource report
│   └── update_upgrade.yml              ← Day-to-day: upgrade all guests
│
├── inventory/
│   └── hosts.ini                       ← List of all managed machines
│
├── group_vars/
│   ├── proxmox-bms.yml                 ← Variables for the Proxmox node group
│   └── all/
│       ├── example_of_main.yml         ← Template — copy to main.yml and fill in
│       ├── main.yml                    ← (gitignored) API tokens, vault secrets
│       ├── preseed_vars.yml            ← All Debian install + preseed settings
│       └── vms.yml                     ← The list of VMs to create and manage
│
├── host_vars/
│   └── <hostname>/
│       └── vault.yml                   ← (gitignored) per-host root password
│
├── preseed/
│   └── debian-preseed.cfg.j2           ← Jinja2 template for the Debian answer file
│
├── collections/
│   └── requirements.yml                ← community.proxmox + community.general
│
└── docs/
    └── pipeline-walkthrough.md         ← Detailed pipeline walkthrough with example output
```

---

### Playbooks

#### `fetch-iso.yml` — Step 1: Download the ISO

**What it does:** Connects to the Proxmox node over SSH and downloads a Debian (or any) ISO file into the Proxmox ISO storage directory (`/var/lib/vz/template/iso`). Skips the download if the file already exists — safe to re-run.

**When to use it:** The very first step. You need the ISO on the Proxmox node before you can build the preseed version or create any VMs.

**Key variables:**
| Variable | What it controls |
|---|---|
| `iso_url` | Full URL to the ISO file (passed via `--extra-vars`) |
| `iso_file` | Filename to save it as on the node (passed via `--extra-vars`) |
| `iso_dir` | Directory on the node — defaults to `/var/lib/vz/template/iso` |

**Example:**
```bash
ansible-playbook -i inventory/hosts.ini fetch-iso.yml \
  --extra-vars '{"iso_url":"https://cdimage.debian.org/debian-cd/current/amd64/iso-cd/debian-13.1.0-amd64-netinst.iso",
                 "iso_file":"debian-13.1.0-amd64-netinst.iso"}'
```

**Tags:** `always` (all tasks run by default)

---

#### `build-debian-preseed-iso.yml` — Step 2: Inject Preseed into the ISO

**What it does:** Takes the raw Debian netinst ISO already on the Proxmox node, injects a rendered `preseed.cfg` answer file, patches the GRUB (EFI) and ISOLINUX (BIOS) boot menus to start automatically, and repackages everything into a new hybrid ISO. The result is an ISO that installs Debian completely unattended — no human interaction required.

**What the build process looks like internally:**
1. Installs `xorriso` and `binutils` on the Proxmox node (if not there)
2. Renders `preseed/debian-preseed.cfg.j2` into a `preseed.cfg` using your variables
3. Extracts the source ISO into a temp directory
4. Copies `preseed.cfg` into the extracted ISO root
5. Patches `grub.cfg` (for EFI boot) and `txt.cfg` (for BIOS boot) to auto-select the preseed installer
6. Sets the boot menu timeout to zero so it starts immediately
7. Uses `xorriso` to repack everything into a new bootable hybrid ISO
8. Moves the output ISO to the Proxmox ISO storage
9. Cleans up the temp directory

**Key variables** (all in `group_vars/all/preseed_vars.yml`):
| Variable | Default | What it controls |
|---|---|---|
| `preseed_iso_src_file` | `debian-13.1.0-amd64-netinst.iso` | Source ISO filename |
| `preseed_iso_dest_file` | `debian-13-amd64-preseed.iso` | Output preseed ISO filename |
| `preseed_iso_dir` | `/var/lib/vz/template/iso` | Where ISOs live on the node |
| `preseed_hostname` | `debian-vm` | Default hostname baked into the ISO |
| `preseed_ansible_user` | `ansible` | Admin user created by the installer |
| `preseed_ssh_pub_key` | reads `~/.ssh/id_rsa.pub` | SSH key injected for that user |
| `preseed_timezone` | `UTC` | System timezone |
| `preseed_locale` | `en_US.UTF-8` | System locale |
| `preseed_debian_suite` | `trixie` | Debian version codename |

**Example:**
```bash
ansible-playbook -i inventory/hosts.ini build-debian-preseed-iso.yml
```

**Tags:** `preseed`, `build`, `tools`

---

#### `create-vm-from-iso-proxmox.yml` — Step 3: Create the VM Shell

**What it does:** Talks to the Proxmox REST API (from your local machine — no SSH into the node) to create one or more VM shells exactly as defined in `group_vars/all/vms.yml`. It does not install an OS — it just creates the VM hardware configuration: CPU, RAM, disk, network card, and mounts the preseed ISO as a virtual CD-ROM.

**Runs on:** `localhost` (your control machine), using the Proxmox API.

**Key variables in `vms.yml`** (per VM):
| Field | Example | What it does |
|---|---|---|
| `name` | `"ansible-debian-01"` | VM display name in Proxmox |
| `vmid` | `500` | Proxmox VM ID (must be unique) |
| `memory` | `1024` | RAM in MiB |
| `cores` | `2` | Number of vCPUs |
| `disk_size_gb` | `32` | System disk size in GB |
| `storage` | `"local-lvm"` | Proxmox storage pool for the disk |
| `net0` | `"virtio,bridge=vmbr0"` | Network interface config |
| `ostype` | `"l26"` | OS type hint (`l26`=Linux, `win10`=Windows 10) |
| `iso_storage` | `"local"` | Proxmox storage where the ISO lives |
| `iso_path` | `"iso/"` | Path prefix within that storage |
| `iso_file` | `"debian-13-amd64-preseed.iso"` | The ISO to mount as CD-ROM |
| `boot` | `"order=ide2;scsi0;net0"` | Boot order (ide2=CD first for install) |
| `preseed_install` | `true` | Flag: include this VM in auto-install |
| `agent` | `1` | Enable qemu-guest-agent (required for IP discovery) |

**Tags and what they target:**
| Tag | What it does |
|---|---|
| `createVMs` | Create the VM shell (CPU, RAM, network) |
| `createDisks` | Create the system disk on scsi0 |
| `mountIso` | Mount ISO as CD-ROM on ide2 |
| `bootOrder` | Apply boot order and bootdisk settings |
| `diskResize` | Grow the disk (shrink is blocked — Proxmox limitation) |
| `removeVMs` | Delete VMs and their disks |
| `updateVMs` | Apply config changes from vms.yml to existing VMs |

**Example — create VMs with all required steps:**
```bash
ansible-playbook -i inventory/hosts.ini create-vm-from-iso-proxmox.yml \
  --tags "createVMs,createDisks,mountIso,bootOrder"
```

---

#### `auto-install-debian.yml` — Step 4: Boot and Wait for Install

**What it does:** Boots the VMs that have `preseed_install: true` in `vms.yml`, then waits for the Debian installer to finish and for SSH to become available. The entire unattended install takes 20–40 minutes (the Debian netinst image downloads packages over the internet).

**Three internal plays:**
1. **Boot VMs** — calls the Proxmox API to `state=started` each flagged VM
2. **Discover IP and wait for SSH** — polls the Proxmox guest agent API until it reports a non-loopback IPv4 address, then waits for SSH to accept connections on that IP
3. **Verify and finalize** — confirms the `ansible` user can SSH in with sudo, ejects the install ISO from `ide2`, and switches the boot order to disk-first so it doesn't re-install on next boot

**IP discovery:** If `ip_address` is set in `vms.yml`, that IP is used directly. If it is omitted, the playbook polls the qemu-guest-agent (which is installed by the preseed during install) until the guest reports its IP. This works for DHCP environments.

**Key variables:**
| Variable | Default | What it controls |
|---|---|---|
| `preseed_boot_wait_seconds` | `30` | Seconds to wait after power-on before checking SSH |
| `preseed_ssh_wait_timeout` | `2400` (40 min) | Max seconds to wait for SSH |
| `preseed_ssh_wait_delay` | `30` | Seconds between SSH check attempts |

**Example:**
```bash
ansible-playbook -i inventory/hosts.ini auto-install-debian.yml
```

---

#### `setup-debian-base.yml` — Step 5: Configure the Installed VM

**What it does:** Runs on newly installed VMs (listed under `[new-debian-vms]` in `hosts.ini`) to bring them to a consistent baseline state. Safe to re-run at any time (idempotent).

**Tasks it performs:**
1. Updates APT package index and runs a full safe-upgrade
2. Installs the base package set (see `debian_base_packages` in `preseed_vars.yml`)
3. Sets `vim` as the system default editor
4. Ensures `qemu-guest-agent` is enabled and running
5. Disables SSH password authentication (key-only login enforced)
6. Ensures the ansible user has passwordless sudo (`NOPASSWD: ALL`)
7. Prints a per-host summary confirming everything is configured

**Default base packages installed:**
`htop`, `btop`, `vim`, `curl`, `wget`, `git`, `tmux`, `net-tools`, `bash-completion`, `unzip`, `jq`, `qemu-guest-agent`

**Targeting hosts:**
```bash
# All hosts in [new-debian-vms]
ansible-playbook -i inventory/hosts.ini setup-debian-base.yml

# Specific IP address directly (no inventory entry needed)
ansible-playbook -i inventory/hosts.ini setup-debian-base.yml \
  --limit "192.168.0.50"
```

---

#### `setup-base-ansible-proxmox.yml` — Bootstrap the Proxmox Node

**What it does:** A one-time setup playbook that installs Python 3, pip, and the Python libraries needed for Ansible to talk to the Proxmox API (`proxmoxer`, `requests`) on the Proxmox node itself.

**When to run it:** Once, immediately after adding your Proxmox node to inventory and before running any other playbook.

**What gets installed:**
- System packages: `python3`, `python3-pip`
- Python packages: `setuptools`, `requests`, `proxmoxer`

**Example:**
```bash
ansible-playbook -i inventory/hosts.ini setup-base-ansible-proxmox.yml
```

---

#### `setup-ansibleuser.yml` — Create the Automation User on Guest Machines

**What it does:** Connects as `root` to every host and creates the `ansibleuser` account with:
- A disabled password (SSH key auth only)
- Passwordless sudo (`NOPASSWD: ALL`)
- Your SSH public key already installed

Run this once per host after `deploy-root-key.sh` has pushed your SSH key to root.

**Handles multiple OS families:**
- Debian/Ubuntu: uses standard `/bin/bash`
- Alpine Linux: installs `python3` and `sudo` first via raw shell (before any Ansible module runs), sets shell to `/bin/ash`

**Example:**
```bash
ansible-playbook -i inventory/hosts.ini setup-ansibleuser.yml -u root --ask-pass

# Target a single host:
ansible-playbook -i inventory/hosts.ini setup-ansibleuser.yml \
  -u root --ask-pass --limit lxc-prometheus
```

---

#### `pve_vm_status.yml` — Live VM Resource Report

**What it does:** Queries the Proxmox REST API and prints a formatted, one-line-per-VM report of current CPU and RAM usage for every VM and LXC container in the cluster. Read-only — it never modifies anything.

**What the output shows per guest:**
- VM name and type (QEMU or LXC)
- Current CPU usage percentage
- RAM used vs allocated (in GiB and percent)
- Running state

**Also shows:** Overall totals and available headroom across the cluster.

**Example:**
```bash
ansible-playbook -i inventory/hosts.ini pve_vm_status.yml
```

---

#### `update_upgrade.yml` — Upgrade All Guests

**What it does:** Connects to every host in inventory, detects the package manager, and runs the appropriate upgrade command. Hosts that need a reboot are rebooted automatically.

**Supported package managers:**
| OS | Package manager | Commands run |
|---|---|---|
| Debian / Ubuntu | `apt` | `apt update` → `apt dist-upgrade` → `autoremove` |
| Alpine Linux | `apk` | `apk update` → `apk upgrade` |
| RHEL / Fedora | `dnf` | `dnf upgrade` |
| Arch Linux | `pacman` | `pacman -Syu` |

**Targeting a subset:**
```bash
# All LXC containers only
ansible-playbook -i inventory/hosts.ini update_upgrade.yml --limit lxcs

# All VMs only
ansible-playbook -i inventory/hosts.ini update_upgrade.yml --limit vms

# One specific host
ansible-playbook -i inventory/hosts.ini update_upgrade.yml --limit lxc-prometheus
```

---

#### `deploy-root-key.sh` — Push SSH Key to Root (Pre-Bootstrap)

**What it does:** A plain Bash script (not an Ansible playbook) that reads each host's vault-encrypted root password and uses `sshpass` + `ssh-copy-id` to push your SSH public key to the root account on every host.

**Why it exists:** Before Ansible can manage a host, it needs SSH access. New machines only have a root password. This script bridges the gap — it uses the password once to install the key, so all subsequent access is key-based.

**Requirements:** `sshpass` must be installed on your control machine.

**Example:**
```bash
bash deploy-root-key.sh
```

After it succeeds, run `setup-ansibleuser.yml` to create the dedicated automation user.

---

### Configuration & Variables

#### `group_vars/all/example_of_main.yml` → copy to `main.yml`

The template for your main credentials file. **Never commit `main.yml` to git** — it is gitignored. It contains:

| Variable | What it is |
|---|---|
| `pm_api_host` | IP or hostname of your Proxmox node (no scheme, no port) |
| `pm_api_port` | Proxmox API port (default: 8006) |
| `pm_node` | Proxmox node name as shown in the UI |
| `api_user` | Proxmox API user (e.g., `root@pam`) |
| `api_token_id` | Name of the API token you created |
| `pm_api_token_secret` | The token secret (stored encrypted in vault) |
| `pm_api_validate_certs` | `false` for self-signed certs (typical for home labs) |
| `ansible_become_password` | Your sudo password for Ansible (vault encrypted) |

#### `group_vars/all/preseed_vars.yml`

All variables that control the Debian preseed installer and the base setup. Key sections:

- **ISO settings** — source and output filenames, storage path
- **Debian mirror** — which apt mirror to use during install
- **Locale / keyboard / timezone** — system settings baked into the VM
- **Ansible user** — username, SSH key, sudo config
- **`debian_base_packages`** — list of packages `setup-debian-base.yml` installs
- **Timing** — how long to wait for install to finish (`preseed_ssh_wait_timeout`)

#### `group_vars/all/vms.yml`

**The single source of truth for your VMs.** Each entry in the `vms:` list defines one VM. Required fields: `name`, `vmid`, `ostype`, `iso_storage`, `iso_path`, `iso_file`. Everything else falls back to defaults defined inside `create-vm-from-iso-proxmox.yml`.

**VM defaults (when not specified per-VM):**
| Field | Default | Notes |
|---|---|---|
| `memory` | `1024` MiB | |
| `cores` | `1` | |
| `disk_size_gb` | `20` GB | |
| `net0` | `virtio,bridge=vmbr0` | |
| `storage` | `local-lvm` | Proxmox disk storage pool |
| `boot` | `order=ide2;scsi0;net0` | Boot from CD first |
| `agent` | `1` | qemu-guest-agent enabled |
| `onboot` | `true` | Start with Proxmox host |

#### `group_vars/proxmox-bms.yml`

Contains group-specific overrides for the `[proxmox-bms]` inventory group. Currently sets `ansible_python_interpreter: /usr/bin/python3` to avoid interpreter auto-detection warnings.

#### `host_vars/<hostname>/vault.yml`

Per-host encrypted file containing `ansible_password` — the root password for that specific host. Used by `deploy-root-key.sh` to authenticate the initial SSH key deployment.

---

### Inventory

#### `inventory/hosts.ini`

The list of every machine Ansible knows about. Organized into groups:

| Group | Used by | What goes here |
|---|---|---|
| `[proxmox-bms]` | Most playbooks | Your Proxmox bare-metal server(s) |
| `[lxcs]` | `update_upgrade.yml`, `setup-ansibleuser.yml` | LXC containers |
| `[vms]` | `update_upgrade.yml`, `setup-ansibleuser.yml` | Running VMs |
| `[new-debian-vms]` | `setup-debian-base.yml` | Freshly installed VMs (temporary entry) |

Each host line format:
```ini
hostname  ansible_port=22  ansible_host=IP  ansible_user=ansibleuser  ansible_ssh_private_key_file=~/.ssh/id_rsa
```

---

### Preseed Template

#### `preseed/debian-preseed.cfg.j2`

A Jinja2 template that renders into a Debian installer answer file. Each `d-i` line answers one installer question. The template covers:

| Section | What it configures |
|---|---|
| Localization | Language, locale, keyboard layout |
| Network | DHCP by default; static IP if `preseed_ip` is set |
| Mirror | Which Debian mirror to fetch packages from |
| Clock | UTC, NTP enabled |
| Partitioning | Full disk, single partition (atomic recipe — ideal for VMs) |
| Users | root locked, `ansible` user created with SSH key and NOPASSWD sudo |
| Packages | Base packages + qemu-guest-agent + anything in `preseed_extra_packages` |
| Finish | Eject CD, reboot automatically |

---

### Collections & Tooling

#### `collections/requirements.yml`

Declares two Ansible collections this project depends on:
- `community.proxmox >= 1.3.0` — modules for talking to the Proxmox API (`proxmox_kvm`, `proxmox_vm_info`, etc.)
- `community.general >= 11.0.0` — general utility modules (`alternatives`, `authorized_key`, etc.)

Install them with:
```bash
ansible-galaxy collection install -r collections/requirements.yml -p ./collections
```

#### `ansible.cfg`

The Ansible runtime configuration. Notable settings:

| Setting | Value | Why |
|---|---|---|
| `forks` | `20` | Run tasks on 20 hosts in parallel |
| `pipelining` | `True` | Reduces SSH round-trips — faster runs |
| `vault_password_file` | `~/.vault_pass.txt` | Auto-loads vault password — no prompts |
| `collections_paths` | `./collections:...` | Looks in local `collections/` folder first |
| `ControlMaster=auto` | SSH option | Reuses SSH connections across tasks |
| `ControlPersist=60s` | SSH option | Keeps connection open for 60 seconds |

---

## Requirements

- Ansible 2.12+ on your control machine
- `~/.vault_pass.txt` containing your Ansible Vault master password
- SSH key pair at `~/.ssh/id_rsa` / `~/.ssh/id_rsa.pub`
- Proxmox API token with `VM.Allocate`, `VM.Config.*`, `Datastore.AllocateSpace` privileges
- `sshpass` installed (only needed for `deploy-root-key.sh`)

Install required Ansible collections:

```bash
ansible-galaxy collection install -r collections/requirements.yml -p ./collections
```

Install Python dependencies on the control node:

```bash
python3 -m pip install --user proxmoxer requests --break-system-packages
```

---

## First-Time Setup

### 1 — Create your vault password file

```bash
echo "your_strong_passphrase_here" > ~/.vault_pass.txt
chmod 600 ~/.vault_pass.txt
```

### 2 — Configure credentials

```bash
cp group_vars/all/example_of_main.yml group_vars/all/main.yml
```

Edit `group_vars/all/main.yml` and fill in:
- `pm_api_host` — your Proxmox node's IP or hostname
- `pm_node` — node name from the Proxmox UI
- `api_token_id` — API token name you created
- `pm_api_token_secret` — encrypt this with vault (see below)

To encrypt a secret value with vault:
```bash
ansible-vault encrypt_string --name 'pm_api_token_secret' 'your_actual_token_secret_here'
```
Paste the output block into `main.yml`.

### 3 — Configure inventory

Edit `inventory/hosts.ini`:
- Replace the example IPs and hostnames with your actual Proxmox node and guests
- `[proxmox-bms]` must have your Proxmox server

### 4 — Bootstrap the Proxmox node (once)

```bash
ansible-playbook -i inventory/hosts.ini setup-base-ansible-proxmox.yml
```

This installs Python and proxmoxer on the Proxmox node so Ansible modules can talk to it.

### 5 — Bootstrap `ansibleuser` on existing guests (once per host)

```bash
# Step A: Push your SSH key to root on all hosts
bash deploy-root-key.sh

# Step B: Create the ansibleuser with sudo + key auth
ansible-playbook -i inventory/hosts.ini setup-ansibleuser.yml -u root --ask-pass
```

---

## VM Provisioning Pipeline

Full walkthrough with real output examples: [`docs/pipeline-walkthrough.md`](docs/pipeline-walkthrough.md)

```
fetch-iso.yml
  └─> build-debian-preseed-iso.yml
        └─> create-vm-from-iso-proxmox.yml
              └─> auto-install-debian.yml
                    └─> setup-debian-base.yml
```

See [Complete User Guide](#complete-user-guide--zero-to-running-vm) below for the full step-by-step walkthrough with real examples.

---

## Day-to-Day Operations

### Check live resource usage

```bash
ansible-playbook -i inventory/hosts.ini pve_vm_status.yml
```

### Upgrade all guests

```bash
ansible-playbook -i inventory/hosts.ini update_upgrade.yml
```

### Upgrade only LXC containers

```bash
ansible-playbook -i inventory/hosts.ini update_upgrade.yml --limit lxcs
```

### Upgrade a single host

```bash
ansible-playbook -i inventory/hosts.ini update_upgrade.yml --limit lxc-prometheus
```

---

## Vault — Storing Secrets Safely

All secrets are encrypted with Ansible Vault and loaded automatically via `~/.vault_pass.txt`.

**Where secrets live:**
- `group_vars/all/main.yml` — API token, sudo password
- `host_vars/<hostname>/vault.yml` — per-host root password

**Encrypt a new value:**
```bash
ansible-vault encrypt_string --name 'variable_name' 'plaintext_value'
```

**View an encrypted file:**
```bash
ansible-vault view host_vars/lxc-prometheus/vault.yml
```

**Edit an encrypted file:**
```bash
ansible-vault edit host_vars/lxc-prometheus/vault.yml
```

---

## Performance Tuning

`ansible.cfg` is pre-configured for fast parallel runs:
- `forks = 20` — 20 parallel host connections at once
- `pipelining = True` — reduces SSH round-trips (may need `requiretty` disabled in sudoers)
- SSH `ControlMaster/ControlPersist` — reuses SSH connections, eliminates repeated handshakes

---

## Complete User Guide — Zero to Running VM

> **Goal:** Start with a bare Proxmox node and end up with a fully configured Debian VM running with base software, SSH key access, and sudo configured — entirely from the command line.

See [docs/user-guide.md](docs/user-guide.md) for the full guide.

---

## Credit

Thomas Mozdren, 2026
