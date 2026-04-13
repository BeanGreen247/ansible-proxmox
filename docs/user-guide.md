# User Guide — From Zero to a Running Debian VM with Software

This guide takes you through the **entire workflow**, step by step, from a fresh Proxmox node to a fully configured, SSH-accessible Debian virtual machine with your chosen software installed.

Every command is real. Every variable name matches what is in the repo. No steps are skipped.

---

## Table of Contents

1. [What You Will End Up With](#what-you-will-end-up-with)
2. [Prerequisites](#prerequisites)
3. [Phase 0 — One-Time Control Machine Setup](#phase-0--one-time-control-machine-setup)
4. [Phase 1 — Configure the Project](#phase-1--configure-the-project)
5. [Phase 2 — Bootstrap the Proxmox Node](#phase-2--bootstrap-the-proxmox-node)
6. [Phase 3 — Download the Debian ISO](#phase-3--download-the-debian-iso)
7. [Phase 4 — Inject the Preseed Answer File into the ISO](#phase-4--inject-the-preseed-answer-file-into-the-iso)
8. [Phase 5 — Define Your VM](#phase-5--define-your-vm)
9. [Phase 6 — Create the VM Shell on Proxmox](#phase-6--create-the-vm-shell-on-proxmox)
10. [Phase 7 — Boot and Run the Unattended Debian Install](#phase-7--boot-and-run-the-unattended-debian-install)
11. [Phase 8 — Run the Base Configuration Playbook](#phase-8--run-the-base-configuration-playbook)
12. [Phase 9 — Install Your Software](#phase-9--install-your-software)
13. [Common Operations](#common-operations)
14. [Troubleshooting](#troubleshooting)

---

## What You Will End Up With

After following this guide you will have:

- A Debian 13 (Trixie) VM running on your Proxmox node
- An `ansible` user with SSH key access and passwordless sudo
- Base tools installed: `htop`, `btop`, `vim`, `curl`, `wget`, `git`, `tmux`, and more
- SSH password authentication disabled — key-only login
- `qemu-guest-agent` running for Proxmox integration
- Any additional software you choose to add in Phase 9

The entire process is automated. After the initial configuration you run five commands and walk away. The VM provisions, installs Debian, and configures itself.

---

## Prerequisites

You need the following before starting:

| Requirement | How to get it |
|---|---|
| A Proxmox VE node | Any bare-metal machine with Proxmox installed |
| Proxmox API token | Create in Proxmox UI → Datacenter → API Tokens |
| SSH key pair | Run `ssh-keygen -t rsa -b 4096` if you don't have one |
| Ansible on your control machine | `sudo apt install ansible` or `pip install ansible` |
| `sshpass` (for the root key script) | `sudo apt install sshpass` |
| This repository cloned locally | `git clone <repo-url> && cd ansible-proxmox` |

### Create a Proxmox API Token

1. Open the Proxmox web UI
2. Go to **Datacenter → Permissions → API Tokens**
3. Click **Add**
4. Select user `root@pam`, give the token a name (e.g., `ansible-automation`)
5. **Uncheck** "Privilege Separation" so the token inherits root permissions
6. Copy the token secret — you will only see it once

---

## Phase 0 — One-Time Control Machine Setup

These steps are done once on the machine you will run Ansible from.

### Step 0.1 — Install Ansible collections

```bash
ansible-galaxy collection install -r collections/requirements.yml -p ./collections
```

This installs:
- `community.proxmox` — modules for talking to the Proxmox API
- `community.general` — utility modules used across playbooks

### Step 0.2 — Install Python dependencies

```bash
python3 -m pip install --user proxmoxer requests --break-system-packages
```

`proxmoxer` is the Python library that backs the community.proxmox Ansible modules.

### Step 0.3 — Create your vault password file

Ansible Vault encrypts your secrets. It needs a master password to decrypt them. Store it in a file so you never get prompted at runtime:

```bash
# Use a strong passphrase
echo "replace_this_with_a_strong_passphrase" > ~/.vault_pass.txt
chmod 600 ~/.vault_pass.txt
```

> **Warning:** This file holds the key to all your encrypted secrets. Keep it off version control, off shared drives, and back it up safely.

---

## Phase 1 — Configure the Project

### Step 1.1 — Create your main credentials file

```bash
cp group_vars/all/example_of_main.yml group_vars/all/main.yml
```

Open `group_vars/all/main.yml` and fill in your values:

```yaml
# Your Proxmox node
pm_api_host: "192.168.0.222"   # IP or hostname — no http://, no :8006
pm_api_port: 8006
pm_node: "pve"                 # Node name as shown in Proxmox UI (usually "pve")

# Proxmox API credentials
api_user: "root@pam"
api_token_id: "ansible-automation"    # The token name you created

# Encrypt the token secret with vault (see below)
pm_api_token_secret: !vault |
  $ANSIBLE_VAULT;1.1;AES256
  (paste your encrypted block here)

pm_api_validate_certs: false   # false is fine for home labs with self-signed certs
```

### Step 1.2 — Encrypt your API token secret

You must never store the raw token secret in a file. Encrypt it:

```bash
ansible-vault encrypt_string --name 'pm_api_token_secret' 'paste_your_actual_token_secret_here'
```

Example output:
```
pm_api_token_secret: !vault |
          $ANSIBLE_VAULT;1.1;AES256
          61363162356339623361396661663739333533643866393...
```

Copy the entire block (including the `!vault |` line) and paste it into `main.yml`, replacing the placeholder.

### Step 1.3 — Configure the inventory

Open `inventory/hosts.ini` and update the `[proxmox-bms]` section with your node's details:

```ini
[proxmox-bms]
my-proxmox-node  ansible_port=22  ansible_host=192.168.0.222  ansible_user=root  ansible_ssh_private_key_file=~/.ssh/id_rsa
```

> At this point use `ansible_user=root` because we haven't created `ansibleuser` yet. After Phase 2, switch it to `ansibleuser`.

### Step 1.4 — Check preseed variables

Open `group_vars/all/preseed_vars.yml` and verify or adjust these key settings:

```yaml
# The Debian ISO that will be downloaded — check for the latest version
preseed_iso_src_file: "debian-13.1.0-amd64-netinst.iso"
preseed_iso_url: "https://cdimage.debian.org/debian-cd/current/amd64/iso-cd/{{ preseed_iso_src_file }}"

# The output ISO name after preseed injection
preseed_iso_dest_file: "debian-13-amd64-preseed.iso"

# VM user settings — your SSH key is read automatically from this path
preseed_ssh_pub_key_file: "~/.ssh/id_rsa.pub"
preseed_ansible_user: "ansible"

# Locale and timezone
preseed_locale: "en_US.UTF-8"
preseed_timezone: "UTC"           # Change to your timezone, e.g., "America/New_York"
preseed_keymap: "us"

# Debian mirror — change if you want a regional mirror
preseed_mirror_host: "deb.debian.org"
```

---

## Phase 2 — Bootstrap the Proxmox Node

This installs the Python libraries that Ansible needs on the Proxmox node itself. Run it once.

```bash
ansible-playbook -i inventory/hosts.ini setup-base-ansible-proxmox.yml
```

**What you should see:**
```
PLAY [Setup Ansible base for Proxmox and control node]

TASK [Install python3 and pip]
ok: [my-proxmox-node]

TASK [Install needed modules via pip]
ok: [my-proxmox-node]

PLAY RECAP
my-proxmox-node : ok=2  changed=0  unreachable=0  failed=0
```

After this succeeds, update `hosts.ini` to use `ansibleuser` instead of `root` — but only after you have created that user in Phase 2.5 below.

### Step 2.5 — Create the `ansibleuser` on the Proxmox node

```bash
# First push your SSH key to root
bash deploy-root-key.sh

# Then create the ansibleuser account
ansible-playbook -i inventory/hosts.ini setup-ansibleuser.yml -u root --ask-pass
```

After this succeeds, update `inventory/hosts.ini` to use `ansibleuser`:

```ini
[proxmox-bms]
my-proxmox-node  ansible_port=22  ansible_host=192.168.0.222  ansible_user=ansibleuser  ansible_ssh_private_key_file=~/.ssh/id_rsa
```

---

## Phase 3 — Download the Debian ISO

This downloads the Debian netinst ISO directly to the Proxmox node's ISO storage directory (`/var/lib/vz/template/iso`). The ISO is small (about 650 MB) and downloads quickly.

```bash
ansible-playbook -i inventory/hosts.ini fetch-iso.yml \
  --extra-vars '{"iso_url":"https://cdimage.debian.org/debian-cd/current/amd64/iso-cd/debian-13.1.0-amd64-netinst.iso",
                 "iso_file":"debian-13.1.0-amd64-netinst.iso"}'
```

> The `iso_url` and `iso_file` values here must match `preseed_iso_url` and `preseed_iso_src_file` in `preseed_vars.yml`.

**What you should see:**
```
TASK [Create ISO directory if needed]
ok: [my-proxmox-node]

TASK [Download ISO if missing]
changed: [my-proxmox-node]

TASK [Print status of ISO download]
ok: [my-proxmox-node] =>
  msg:
    - 'Changed: True'
    - 'Downloaded to: /var/lib/vz/template/iso/debian-13.1.0-amd64-netinst.iso'
    - 'Size (bytes): 661651456'
```

If you run it again when the ISO already exists it will say `Changed: False` and skip the download — safe to re-run.

---

## Phase 4 — Inject the Preseed Answer File into the ISO

This takes the raw ISO and builds a new version with your `preseed.cfg` baked in. The new ISO will install Debian completely automatically without any human input.

```bash
ansible-playbook -i inventory/hosts.ini build-debian-preseed-iso.yml
```

**What this does (summarized):**
1. Installs `xorriso` and `binutils` on the Proxmox node
2. Renders your `preseed/debian-preseed.cfg.j2` template into a real `preseed.cfg` using all your variables
3. Extracts the source ISO, injects `preseed.cfg`, patches boot menus (GRUB + ISOLINUX)
4. Repacks into a new bootable ISO: `debian-13-amd64-preseed.iso`
5. Places it in `/var/lib/vz/template/iso/` alongside the original

**Expected runtime:** 2–5 minutes (disk I/O on the Proxmox node).

**What to verify:** After the play finishes you can check in the Proxmox UI under your node → local storage → ISO Images. You should see both the original and the new preseed ISO.

---

## Phase 5 — Define Your VM

Open `group_vars/all/vms.yml` and add (or edit) your VM entry. Here is a complete example for a basic Debian web server VM:

```yaml
vms:
  - name: "my-debian-webserver"
    vmid: 501
    # Boot from ISO first (preseed install), then switch to disk after
    boot: "order=ide2;scsi0;net0"
    bootdisk: scsi0
    onboot: false          # Don't auto-start with Proxmox host until setup is done
    memory: 2048           # 2 GB RAM
    cores: 2               # 2 vCPUs
    net0: "virtio,bridge=vmbr0"
    ostype: "l26"          # Linux 2.6+ kernel
    agent: 1               # Enable qemu-guest-agent (required for IP discovery)
    disk_size_gb: 32       # 32 GB system disk
    storage: "local-lvm"   # Proxmox storage pool — adjust to your actual pool name
    iso_storage: "local"   # Storage where ISO files live
    iso_path: "iso/"
    # This is the preseed ISO built in Phase 4
    iso_file: "debian-13-amd64-preseed.iso"
    # Mark this VM for automated Debian installation
    preseed_install: true
    # Optional: if you have a DHCP reservation set for this VM, put the IP here.
    # If omitted, the IP is auto-discovered via qemu-guest-agent after install.
    # ip_address: "192.168.0.100"
```

**VMID rules:**
- Must be a unique integer between 100 and 999999999
- Cannot conflict with any existing VM or LXC on your Proxmox node
- Check existing IDs in the Proxmox UI

**Storage pool names:**
- Check your actual pool name in Proxmox UI → Node → Storage
- Common names: `local-lvm`, `local`, `data`, `ceph-pool`

---

## Phase 6 — Create the VM Shell on Proxmox

This talks to the Proxmox API from your local machine to create the VM hardware definition — no OS installed yet, just the VM configuration.

```bash
ansible-playbook -i inventory/hosts.ini create-vm-from-iso-proxmox.yml \
  --tags "createVMs,createDisks,mountIso,bootOrder"
```

**What each tag does:**
- `createVMs` — creates the VM with its CPU, RAM, and network config
- `createDisks` — creates and attaches the system disk on `scsi0`
- `mountIso` — mounts the preseed ISO as a virtual CD-ROM on `ide2`
- `bootOrder` — sets the boot order to `ide2` (CD) first, then `scsi0` (disk)

**What you should see:**
```
TASK [Create VM shells]
changed: [localhost] => (item=my-debian-webserver)

TASK [Create/ensure system disks]
changed: [localhost] => (item=my-debian-webserver)

TASK [Mount ISO as CD-ROM (ide2)]
changed: [localhost] => (item=my-debian-webserver)

TASK [Apply boot order]
changed: [localhost] => (item=my-debian-webserver)
```

**Verify in Proxmox UI:** Your VM should appear in the left panel with the correct specs and the preseed ISO mounted under Hardware → CD/DVD Drive (ide2).

---

## Phase 7 — Boot and Run the Unattended Debian Install

This boots the VM from the preseed ISO and waits for the entire Debian installation to complete and SSH to become available. Walk away — this takes 20–40 minutes depending on your internet speed.

```bash
ansible-playbook -i inventory/hosts.ini auto-install-debian.yml
```

**What happens in the background:**
1. The VM is powered on via the Proxmox API
2. The VM boots from the preseed ISO
3. The Debian installer reads `preseed.cfg`, answers all questions automatically, and begins installing
4. The installer downloads packages from `deb.debian.org` (this is the slow part)
5. After packages are installed, the preseed late-command creates the `ansible` user, installs the SSH key, and sets up sudo
6. The VM reboots into the freshly installed system
7. Ansible polls the qemu-guest-agent API until it reports an IPv4 address
8. Ansible waits for SSH to accept connections on that IP
9. Once SSH is up, Ansible verifies the `ansible` user can log in and run sudo
10. The install ISO is ejected and the boot order is switched to disk-first

**What the end of the play looks like:**
```
TASK [Print discovered IP addresses]
ok: [localhost] =>
  msg: 'VM my-debian-webserver (501) installed successfully at 192.168.0.100'

TASK [Eject install ISO from ide2]
changed: [localhost] => (item=my-debian-webserver)

TASK [Set boot order to disk-first after install]
changed: [localhost] => (item=my-debian-webserver)
```

**Write down the discovered IP.** You will need it in the next step.

---

## Phase 8 — Run the Base Configuration Playbook

Now that the VM is running Debian, add it to inventory and run the base setup.

### Step 8.1 — Add the VM to inventory

Open `inventory/hosts.ini` and add an entry under `[new-debian-vms]`:

```ini
[new-debian-vms]
my-debian-webserver  ansible_host=192.168.0.100  ansible_user=ansible  ansible_ssh_private_key_file=~/.ssh/id_rsa
```

> Note: the user is `ansible` (lowercase) — this is the user created by the preseed. It is different from `ansibleuser` which is used on pre-existing hosts.

### Step 8.2 — Run the base setup

```bash
ansible-playbook -i inventory/hosts.ini setup-debian-base.yml
```

Or target by IP directly (no inventory entry needed):

```bash
ansible-playbook -i inventory/hosts.ini setup-debian-base.yml \
  --limit "192.168.0.100"
```

**What gets configured:**
1. Full APT update and safe-upgrade
2. Installs base packages: `htop btop vim curl wget git tmux net-tools bash-completion unzip jq qemu-guest-agent`
3. Sets `vim` as the default system editor
4. Ensures `qemu-guest-agent` is running
5. Disables SSH password authentication
6. Ensures the ansible user has `NOPASSWD` sudo access

**Expected output:**
```
TASK [Update APT package index]
ok: [my-debian-webserver]

TASK [Upgrade all packages to latest (safe-upgrade)]
changed: [my-debian-webserver]

TASK [Install base tool set]
changed: [my-debian-webserver]

TASK [Disable SSH password authentication]
changed: [my-debian-webserver]

TASK [Print base setup confirmation]
ok: [my-debian-webserver] =>
  msg:
    - 'Host: my-debian-webserver'
    - 'Base packages: installed'
    - 'SSH password auth: disabled'
    - 'Ansible user sudo: NOPASSWD configured'
```

---

## Phase 9 — Install Your Software

Now that you have a clean, configured Debian VM you can install whatever software you need. There are two approaches:

### Option A — Extend `setup-debian-base.yml` with more packages

Open `group_vars/all/preseed_vars.yml` and add your packages to `debian_base_packages`. They will be installed as part of the base setup:

```yaml
debian_base_packages:
  - htop
  - btop
  - vim
  - curl
  - wget
  - git
  - tmux
  - net-tools
  - bash-completion
  - unzip
  - jq
  - qemu-guest-agent
  # Add your packages here:
  - nginx
  - postgresql
  - python3
  - python3-pip
```

Then re-run `setup-debian-base.yml` — it is idempotent and will only install what is missing.

### Option B — Write a dedicated playbook for your application

Create a new playbook file in the repo root. Example: `deploy-nginx.yml`:

```yaml
---
- name: Install and configure nginx web server
  hosts: new-debian-vms
  become: true
  gather_facts: true

  tasks:

    - name: Install nginx
      ansible.builtin.apt:
        name: nginx
        state: present
        update_cache: true

    - name: Ensure nginx is started and enabled
      ansible.builtin.service:
        name: nginx
        state: started
        enabled: true

    - name: Deploy custom index page
      ansible.builtin.copy:
        dest: /var/www/html/index.html
        content: |
          <h1>Hello from {{ inventory_hostname }}</h1>
          <p>Provisioned by ansible-proxmox on {{ ansible_date_time.date }}</p>
        owner: www-data
        group: www-data
        mode: "0644"

    - name: Open firewall for HTTP (if ufw is active)
      community.general.ufw:
        rule: allow
        port: "80"
        proto: tcp
      ignore_errors: true   # ufw may not be installed

    - name: Print access URL
      ansible.builtin.debug:
        msg: "Nginx running at http://{{ ansible_host }}"
```

Run it:

```bash
ansible-playbook -i inventory/hosts.ini deploy-nginx.yml
```

### Option C — SSH in and work manually temporarily

Your SSH is set up and ready:

```bash
ssh -i ~/.ssh/id_rsa ansible@192.168.0.100
```

From there you have passwordless sudo — run `sudo apt install <package>` as needed. Once you know what you need, codify it in a playbook for repeatability.

---

## Common Operations

### Check if your Proxmox API connection works

```bash
ansible-playbook -i inventory/hosts.ini pve_vm_status.yml
```

This queries the Proxmox API and prints live CPU/RAM stats for all guests. If this works, all other API-based playbooks will work too.

### Keep all VMs and LXCs up to date

```bash
ansible-playbook -i inventory/hosts.ini update_upgrade.yml
```

### Rebuild a VM from scratch

If something went wrong or you want a fresh VM:

```bash
# Step 1: Delete the existing VM and its disks
ansible-playbook -i inventory/hosts.ini create-vm-from-iso-proxmox.yml \
  --tags "removeVMs"

# Step 2: Re-create and reinstall from Phase 6
ansible-playbook -i inventory/hosts.ini create-vm-from-iso-proxmox.yml \
  --tags "createVMs,createDisks,mountIso,bootOrder"

ansible-playbook -i inventory/hosts.ini auto-install-debian.yml
ansible-playbook -i inventory/hosts.ini setup-debian-base.yml
```

### Update the preseed ISO after changing variables

If you change locale, timezone, packages, or any preseed variable, regenerate the ISO:

```bash
ansible-playbook -i inventory/hosts.ini build-debian-preseed-iso.yml
```

The next VM you create and install will use the updated settings.

### Add a new host to fleet management

1. Add the host to the appropriate group in `inventory/hosts.ini`
2. Run `deploy-root-key.sh` to push your SSH key to root on the new host
3. Run `setup-ansibleuser.yml` to create the automation user
4. The host is now managed and will be included in `update_upgrade.yml` runs

---

## Troubleshooting

### "UNREACHABLE — Connection refused" on the Proxmox node

- Check `ansible_host` in `hosts.ini` is the correct IP
- Verify SSH is running on the node: `ssh root@192.168.0.222`
- Check that `ansible_user` is correct (`root` for initial bootstrap, `ansibleuser` after)

### API token error — "401 Unauthorized" or "403 Forbidden"

- Verify `pm_api_token_secret` is correctly encrypted and decrypts to the right value
- Test with: `ansible-vault decrypt --output=- group_vars/all/main.yml | grep pm_api_token_secret`
- Make sure the token in Proxmox UI is not expired
- Make sure "Privilege Separation" is unchecked for the token (or add explicit permissions)

### "Source ISO not found" during build-debian-preseed-iso.yml

The `preseed_iso_src_file` in `preseed_vars.yml` must match the `iso_file` passed to `fetch-iso.yml`.

```yaml
# preseed_vars.yml
preseed_iso_src_file: "debian-13.1.0-amd64-netinst.iso"

# Must match what you passed to fetch-iso.yml:
# --extra-vars '{"iso_file":"debian-13.1.0-amd64-netinst.iso"}'
```

### VM install times out — SSH never becomes available

- Check Proxmox UI → the VM's Console tab to see if the installer is running or stuck
- Common causes: network unreachable (can't download packages), wrong DNS, not enough disk space
- Increase `preseed_ssh_wait_timeout` in `preseed_vars.yml` if your internet is slow
- Check the VM has a valid IP via DHCP: in Proxmox Console look for a DHCP lease line

### "VMID already exists" when creating VMs

The `vmid` in `vms.yml` conflicts with an existing VM. Either:
- Delete the old VM first with the `removeVMs` tag
- Or pick a different `vmid` in `vms.yml`

### Vault password prompts even though `~/.vault_pass.txt` exists

Check that `ansible.cfg` is being read from the project root:

```bash
ansible-config dump | grep vault_password_file
```

It should show `~/.vault_pass.txt`. If it doesn't, make sure you are running commands from the repo root directory where `ansible.cfg` lives.

### The preseed ISO boots but shows the interactive installer menu

The GRUB/ISOLINUX patching in `build-debian-preseed-iso.yml` may not have fully applied. Check:

1. Re-run `build-debian-preseed-iso.yml` — it is safe to re-run
2. Make sure `xorriso` installed successfully on the Proxmox node
3. Check the Proxmox Console shows the new ISO filename (`debian-13-amd64-preseed.iso`), not the original

---

## Full Command Sequence — Quick Reference

Copy-paste this sequence for a complete new VM provisioning run:

```bash
# Phase 0: one-time setup (skip if done before)
ansible-galaxy collection install -r collections/requirements.yml -p ./collections
python3 -m pip install --user proxmoxer requests --break-system-packages
echo "your_vault_passphrase" > ~/.vault_pass.txt && chmod 600 ~/.vault_pass.txt

# Phase 1: configure (edit files, then...)
cp group_vars/all/example_of_main.yml group_vars/all/main.yml
# ... edit main.yml, hosts.ini, preseed_vars.yml, vms.yml ...

# Phase 2: bootstrap Proxmox node
ansible-playbook -i inventory/hosts.ini setup-base-ansible-proxmox.yml

# Phase 3: download Debian ISO
ansible-playbook -i inventory/hosts.ini fetch-iso.yml \
  --extra-vars '{"iso_url":"https://cdimage.debian.org/debian-cd/current/amd64/iso-cd/debian-13.1.0-amd64-netinst.iso",
                 "iso_file":"debian-13.1.0-amd64-netinst.iso"}'

# Phase 4: build preseed ISO
ansible-playbook -i inventory/hosts.ini build-debian-preseed-iso.yml

# Phase 6: create VM shell (Phase 5 is editing vms.yml)
ansible-playbook -i inventory/hosts.ini create-vm-from-iso-proxmox.yml \
  --tags "createVMs,createDisks,mountIso,bootOrder"

# Phase 7: install Debian (takes 20-40 minutes)
ansible-playbook -i inventory/hosts.ini auto-install-debian.yml

# Phase 8: configure base system (add VM IP to hosts.ini first)
ansible-playbook -i inventory/hosts.ini setup-debian-base.yml

# Phase 9: install your software
ansible-playbook -i inventory/hosts.ini deploy-nginx.yml    # or your own playbook
```

---

*Built and maintained by Thomas Mozdren — 2026*
