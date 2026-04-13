# Automated Debian 13 VM Provisioning on Proxmox with Ansible

A complete, hands-off pipeline for provisioning Debian 13 (Trixie) VMs on a Proxmox VE
host using Ansible and a custom preseed system. From zero to a fully configured, SSH-ready
VM — no clicking, no console interaction, no manual steps.

---

## Overview

Four playbooks. One command each. Run them in order and walk away.

```
build-debian-preseed-iso.yml     Remaster the Debian netinst ISO for unattended install
create-vm-from-iso-proxmox.yml   Create the VM shell on Proxmox via API
auto-install-debian.yml          Boot, install Debian, discover IP, verify SSH
setup-debian-base.yml            Install base packages, create users, harden SSH
```

The end result is a Debian 13.4 VM with:
- A locked-down `ansible` automation user (SSH key only, NOPASSWD sudo)
- An interactive end-user account (configurable username, sudo group, SSH key)
- Base tool set: `htop`, `btop`, `vim`, `curl`, `wget`, `git`, `tmux`, `net-tools` and more
- SSH password auth disabled — key-only login
- `qemu-guest-agent` running for Proxmox integration

---

## Prerequisites

| Requirement | Detail |
|---|---|
| Proxmox VE node | API token with `VM.Allocate`, `VM.Config.*`, `Datastore.AllocateSpace` |
| Debian 13 netinst ISO | `debian-13.1.0-amd64-netinst.iso` already in the Proxmox ISO store |
| Ansible control node | Ansible 2.15+, `community.proxmox` collection installed |
| SSH key pair | `~/.ssh/id_rsa` (private) and `~/.ssh/id_rsa.pub` (public) on the control node |

---

## Repository Layout

```
proxmox-ve-vms-ansible/
  build-debian-preseed-iso.yml     Remaster Debian netinst ISO with preseed
  create-vm-from-iso-proxmox.yml   Create/delete VM shells via Proxmox API
  auto-install-debian.yml          Boot + wait for install + discover IP
  setup-debian-base.yml            Post-install base config and user creation
  fetch-iso.yml                    Download a Debian ISO to Proxmox ISO store
  preseed/
    debian-preseed.cfg.j2          Jinja2 preseed template (fully unattended d-i)
  group_vars/all/
    main.yml                       Proxmox API credentials (Ansible Vault encrypted)
    preseed_vars.yml               All preseed + install variables
    vms.yml                        VM definitions (specs, ISO, preseed flags)
  inventory/
    hosts.ini                      proxmox-bms group + auto-populated new-debian-vms
```

---

## Step 0 — Clean Slate (optional)

If a VM already exists from a previous run, this removes it along with all its storage
volumes and cleans up the inventory entry automatically.

```bash
ansible-playbook -i inventory/hosts.ini \
  create-vm-from-iso-proxmox.yml --tags "removeVMs"
```

```
TASK [Stop VMs before removal]
ok: [localhost] => (item=ansible-debian-01)

TASK [Removing VMs and all associated disks]
ok: [localhost] => (item=ansible-debian-01)

TASK [Remove VMs from [new-debian-vms] inventory block]
ok: [localhost] => (item=ansible-debian-01)

PLAY RECAP
localhost : ok=4  changed=0  unreachable=0  failed=0  skipped=0
```

The `removeVMs` tag is tagged `never` so it only runs when explicitly requested — it will
never fire accidentally during a normal run.

---

## Step 1 — Build the Preseed ISO

The `build-debian-preseed-iso.yml` playbook SSHs into the Proxmox node and runs entirely
there. It:

1. Extracts the stock Debian 13 netinst ISO into a temp working directory using `xorriso`
2. Renders the Jinja2 preseed template with Ansible variables and injects `preseed.cfg` into the ISO root
3. Patches the **GRUB config** (EFI boot) — adds `auto=true priority=critical file=/cdrom/preseed.cfg` to every `linux` line, sets `timeout=1`, sets `default=0`
4. Patches the **ISOLINUX config** (BIOS boot) — same preseed parameters on the `append` line, sets the `install` label as `menu default`
5. Strips the `spkgtk.cfg` speech synthesis auto-timeout (which would hijack the BIOS boot menu after 30 seconds)
6. Repacks the whole thing as a bootable BIOS+EFI hybrid ISO using `xorriso`

```bash
ansible-playbook -i inventory/hosts.ini build-debian-preseed-iso.yml
```

```
TASK [Install ISO remaster tools (xorriso, binutils)]
ok: [proxmox-vm-bm-machine]

TASK [Extract ISO content into working directory]
changed: [proxmox-vm-bm-machine]

TASK [Render and inject preseed.cfg into extracted ISO root]
changed: [proxmox-vm-bm-machine]

TASK [Patch GRUB - add preseed auto-install params to linux boot lines]
changed: [proxmox-vm-bm-machine]

TASK [Patch GRUB - set default to first non-graphical install entry]
changed: [proxmox-vm-bm-machine]

TASK [Patch ISOLINUX txt.cfg - add preseed params to append lines]
changed: [proxmox-vm-bm-machine]

TASK [Patch spkgtk.cfg - remove speech synthesis auto-timeout override]
changed: [proxmox-vm-bm-machine] => (item=^timeout\s+)
changed: [proxmox-vm-bm-machine] => (item=^ontimeout\s+)
changed: [proxmox-vm-bm-machine] => (item=^menu\s+autoboot\s+)

TASK [Patch txt.cfg - mark 'install' as default ISOLINUX menu entry]
changed: [proxmox-vm-bm-machine]

TASK [Repack ISO with BIOS + EFI boot support]
changed: [proxmox-vm-bm-machine]

TASK [Print output ISO info]
ok: [proxmox-vm-bm-machine] => {
    "msg": [
        "Preseed ISO built successfully.",
        "Output: /var/lib/vz/template/iso/debian-13-amd64-preseed.iso",
        "Size: 969.0 MiB"
    ]
}

PLAY RECAP
proxmox-vm-bm-machine : ok=24  changed=13  unreachable=0  failed=0  skipped=3
```

---

## Step 2 — Create the VM on Proxmox

`create-vm-from-iso-proxmox.yml` talks to the Proxmox REST API from localhost (no SSH to
the node required). It creates the VM shell, provisions the disk on `local-lvm`, mounts
the preseed ISO as a CD-ROM on `ide2`, and sets the boot order to ISO-first.

All VM specs live in `group_vars/all/vms.yml`:

```yaml
- name: "ansible-debian-01"
  vmid: 510
  boot: "order=ide2;scsi0;net0"
  memory: 2048
  cores: 2
  disk_size_gb: 20
  storage: "local-lvm"
  iso_file: "debian-13-amd64-preseed.iso"
  preseed_install: true
```

```bash
ansible-playbook -i inventory/hosts.ini \
  create-vm-from-iso-proxmox.yml --tags "createVMs,createDisks,mountIso,bootOrder"
```

```
TASK [Create empty VM shells]
changed: [localhost] => (item=ansible-debian-01)

TASK [Create and or update system disks (scsi0)]
changed: [localhost] => (item=ansible-debian-01)

TASK [Mount ISO as CD-ROM (ide2)]
changed: [localhost] => (item=ansible-debian-01)

TASK [Set boot order from vms.yml (or default)]
changed: [localhost] => (item=ansible-debian-01)

PLAY RECAP
localhost : ok=5  changed=4  unreachable=0  failed=0  skipped=0
```

---

## Step 3 — Automated Installation

`auto-install-debian.yml` runs three plays entirely from localhost, talking to the Proxmox
API throughout. No SSH connection to the VM is needed until the very end.

**PLAY 1 — Boot**
Starts the VM via the Proxmox API. The VM immediately boots from the preseed ISO.

**PLAY 2 — Install and discover IP**
The preseed installer runs fully unattended. At the end of `late_command`, after injecting
the SSH key and configuring sudo, the script calls `poweroff -f` — halting the VM
immediately without showing the d-i "Installation complete" dialog.

The playbook polls `GET /api2/json/nodes/{node}/qemu/{vmid}/status/current` every 30
seconds until `status == stopped`. When it detects the halt it:
1. Ejects the ISO from `ide2` via the Proxmox disk API
2. Sets boot order to `scsi0;net0` (disk-first, no more ISO boot)
3. Powers the VM back on
4. Uses the Proxmox guest exec API to run `hostname -I` inside the VM and retrieve its IP

**PLAY 3 — Verify and configure inventory**
Confirms the `ansible` user can SSH and run `sudo id`. Writes the VM's entry into
`inventory/hosts.ini` under `[new-debian-vms]` automatically using `blockinfile` — so
`setup-debian-base.yml` can run immediately with no manual edits.

```bash
ansible-playbook -i inventory/hosts.ini auto-install-debian.yml
```

```
PLAY [Boot VMs for preseed Debian installation]

TASK [Start VMs for preseed installation]
changed: [localhost] => (item=ansible-debian-01)

TASK [Print booted VMs]
ok: [localhost] => {
    "msg": "Started VM: ansible-debian-01 (vmid=510) - IP will be auto-discovered via guest agent"
}

PLAY [Discover VM IPs via guest agent and wait for SSH]

TASK [Wait for install to complete - VM halts when done (up to 40 min)]
FAILED - RETRYING: (80 retries left).
FAILED - RETRYING: (79 retries left).
...
ok: [localhost] => (item=ansible-debian-01 (vmid=510))

TASK [Eject install ISO from ide2 (VM is halted - safe to remove)]
changed: [localhost] => (item=ansible-debian-01)

TASK [Set boot order to disk-first before powering on]
changed: [localhost] => (item=ansible-debian-01)

TASK [Power on VMs to boot from installed disk]
changed: [localhost] => (item=ansible-debian-01)

TASK [Start guest exec - hostname -I (via Proxmox agent API)]
ok: [localhost] => (item=ansible-debian-01 (vmid=510))

TASK [Fetch guest exec result - hostname -I]
ok: [localhost] => (item=ansible-debian-01)

TASK [Print discovered IPs]
ok: [localhost] => {
    "msg": "ansible-debian-01: IP = 192.168.0.106"
}

TASK [Wait for SSH to respond on each VM]
ok: [localhost] => (item=ansible-debian-01 (192.168.0.106))

PLAY [Verify ansible SSH access and eject install ISO]

TASK [Verify SSH + sudo for ansible user on each installed VM]
ok: [localhost] => (item=ansible-debian-01)

TASK [Print SSH verification results]
ok: [localhost] => {
    "msg": "ansible user SSH + sudo OK on ansible-debian-01 (192.168.0.106)"
}

TASK [Add discovered VMs to [new-debian-vms] in inventory]
changed: [localhost] => (item=ansible-debian-01)

TASK [Print completion summary]
ok: [localhost] => {
    "msg": [
        "Debian installation complete for: ansible-debian-01",
        "  IP:      192.168.0.106",
        "  User:    ansible",
        "  SSH key: ~/.ssh/id_rsa.pub",
        "inventory/hosts.ini has been updated automatically.",
        "Next step: ansible-playbook -i inventory/hosts.ini setup-debian-base.yml"
    ]
}

PLAY RECAP
localhost : ok=25  changed=8  unreachable=0  failed=0  skipped=2
```

---

## Step 4 — Base Package Setup and User Creation

`setup-debian-base.yml` connects to the newly installed VM as the `ansible` user over SSH
and handles the post-install baseline:

- Runs `apt safe-upgrade`
- Installs: `htop`, `btop`, `vim`, `curl`, `wget`, `git`, `tmux`, `net-tools`,
  `bash-completion`, `unzip`, `jq`, `qemu-guest-agent`
- Sets `vim` as the default system editor
- Hardens SSH: `PasswordAuthentication no`, `ChallengeResponseAuthentication no`
- Confirms `ansible` user NOPASSWD sudoers entry
- Creates the end-user account (configurable in `preseed_vars.yml`) with sudo access
  and the same SSH public key

```bash
ansible-playbook -i inventory/hosts.ini setup-debian-base.yml
```

```
TASK [Gathering Facts]
ok: [ansible-debian-01]

TASK [Update APT package index]
ok: [ansible-debian-01]

TASK [Install base tool set]
changed: [ansible-debian-01]

TASK [Set vim as default editor (update-alternatives)]
changed: [ansible-debian-01]

TASK [Disable SSH password authentication]
changed: [ansible-debian-01]

TASK [Create end-user account]
changed: [ansible-debian-01]

TASK [Set SSH authorized key for end-user]
changed: [ansible-debian-01]

TASK [Print base setup summary]
ok: [ansible-debian-01] => {
    "msg": [
        "Base setup complete on: ansible-debian-01",
        "  Hostname:     debian-vm",
        "  OS:           Debian 13.4",
        "  Kernel:       6.12.74+deb13+1-amd64",
        "  SSH:          password auth OFF, key-only",
        "  Ansible user: ansible (NOPASSWD sudo, automation only)",
        "  End-user:     cartman (groups: sudo)"
    ]
}

PLAY RECAP
ansible-debian-01 : ok=14  changed=8  unreachable=0  failed=0  skipped=0
```

---

## User Accounts

Two accounts are created across the pipeline:

| Account | Created by | Password | Auth method | Purpose |
|---|---|---|---|---|
| `ansible` | preseed `late_command` | locked (`!`) | SSH key only, NOPASSWD sudo | Ansible automation — never log in as this user |
| `cartman` (configurable) | `setup-debian-base.yml` | SHA-512 hash via Ansible Vault | SSH key + sudo password | Interactive day-to-day use |

To configure the end-user, set these in `group_vars/all/preseed_vars.yml`:

```yaml
vm_enduser_name: "cartman"
vm_enduser_groups: "sudo"
vm_enduser_shell: "/bin/bash"
vm_enduser_ssh_pub_key_file: "~/.ssh/id_rsa.pub"
```

To set a sudo password, generate a SHA-512 hash and vault-encrypt it:

```bash
openssl passwd -6 'yourpassword'
ansible-vault encrypt_string 'the-hash' --name 'vm_enduser_password_hash'
```

Add the vault output to `group_vars/all/main.yml`.

---

## How the Preseed Works

`preseed/debian-preseed.cfg.j2` is a Jinja2 template rendered by Ansible at ISO build
time. Every variable comes from `preseed_vars.yml` — nothing is hardcoded in the template.

Key sections:

- **Locale / keymap / timezone** — `preseed_locale`, `preseed_keymap`, `preseed_timezone`
- **Networking** — DHCP by default; set `preseed_ip` per-VM in `vms.yml` for a static IP
- **Partitioning** — single root partition, atomic recipe, no LVM
- **Package selection** — `openssh-server sudo qemu-guest-agent curl wget vim`
- **`late_command`** — runs on the installer's host OS (not inside the target):
  1. Creates `/home/ansible/.ssh/authorized_keys` with the public key
  2. Sets permissions: `700` on `.ssh`, `600` on `authorized_keys`
  3. Writes `/etc/sudoers.d/ansible` with `NOPASSWD:ALL`
  4. Enables `qemu-guest-agent` via `systemctl`
  5. Calls `poweroff -f` — halts immediately, triggering the Ansible poll to proceed

---

## How IP Auto-Discovery Works

No static IP or DHCP reservation required. After the VM powers off post-install, the
playbook:

1. Detects `status == stopped` via `GET /api2/json/nodes/{node}/qemu/{vmid}/status/current`
2. Ejects the ISO and sets disk-first boot order
3. Powers the VM on
4. Waits 30 seconds for the OS to boot
5. Calls `POST /api2/json/nodes/{node}/qemu/{vmid}/agent/exec` with `["hostname", "-I"]`
6. Retrieves the output via `GET .../agent/exec-status?pid=...`
7. Parses the first IPv4 from the response and stores it in `discovered_ips`

The discovered IP is written to `inventory/hosts.ini` under `[new-debian-vms]`
automatically — `setup-debian-base.yml` can run immediately afterward with no edits.

---

## Variable Reference

| Variable | File | Default | Description |
|---|---|---|---|
| `preseed_iso_src_file` | `preseed_vars.yml` | `debian-13.1.0-amd64-netinst.iso` | Source netinst ISO filename |
| `preseed_iso_dest_file` | `preseed_vars.yml` | `debian-13-amd64-preseed.iso` | Output preseed ISO filename |
| `preseed_debian_suite` | `preseed_vars.yml` | `trixie` | Debian suite for APT mirror |
| `preseed_ansible_user` | `preseed_vars.yml` | `ansible` | Automation user created during install |
| `preseed_ssh_pub_key_file` | `preseed_vars.yml` | `~/.ssh/id_rsa.pub` | SSH public key injected for ansible user |
| `preseed_ssh_priv_key_file` | `preseed_vars.yml` | `~/.ssh/id_rsa` | Private key path written to inventory |
| `preseed_ssh_wait_timeout` | `preseed_vars.yml` | `2400` | Max seconds to wait for install (40 min) |
| `preseed_ssh_wait_delay` | `preseed_vars.yml` | `30` | Polling interval in seconds |
| `preseed_boot_wait_seconds` | `preseed_vars.yml` | `30` | Seconds after power-on before IP query |
| `debian_base_packages` | `preseed_vars.yml` | `htop btop vim ...` | Packages installed by setup-debian-base.yml |
| `vm_enduser_name` | `preseed_vars.yml` | `""` (disabled) | End-user login account name |
| `vm_enduser_groups` | `preseed_vars.yml` | `sudo` | Groups for the end-user account |
| `vm_enduser_password_hash` | `main.yml` (vault) | `!` (locked) | SHA-512 password hash for end-user sudo |


---

## Overview

This pipeline takes a bare Proxmox node and produces one or more fully configured Debian 13
VMs — with an `ansible` SSH user, passwordless sudo, and base packages — by running four
playbooks in sequence.

```
build-debian-preseed-iso.yml     Build a custom unattended install ISO
create-vm-from-iso-proxmox.yml   Create the VM shell on Proxmox
auto-install-debian.yml          Boot, install, discover IP, verify SSH
setup-debian-base.yml            Install base packages and harden SSH
```

---

## Prerequisites

| Requirement | Detail |
|---|---|
| Proxmox VE node | API token with VM.Allocate, VM.Config.*, Datastore.AllocateSpace |
| Debian 13 netinst ISO | `debian-13.1.0-amd64-netinst.iso` in the Proxmox ISO store |
| Ansible control node | Ansible 2.15+, `community.proxmox` collection |
| SSH key pair | Private key at `~/.ssh/id_rsa`, public key injected into VMs by preseed |

---

## Repository Layout

```
proxmox-ve-vms-ansible/
  build-debian-preseed-iso.yml     Remaster Debian netinst ISO with preseed
  create-vm-from-iso-proxmox.yml   Create VM shells via Proxmox API
  auto-install-debian.yml          Boot + wait for install + discover IP
  setup-debian-base.yml            Post-install base config
  fetch-iso.yml                    Download a Debian ISO to Proxmox ISO store
  preseed/
    debian-preseed.cfg.j2          Jinja2 preseed template (fully unattended d-i)
  group_vars/all/
    main.yml                       Proxmox API credentials (Ansible Vault)
    preseed_vars.yml               All preseed + install variables
    vms.yml                        VM definitions (specs, ISO, preseed flags)
  inventory/
    hosts.ini                      proxmox-bms + new-debian-vms groups
```

---

## Step 1 — Build the Preseed ISO

The `build-debian-preseed-iso.yml` playbook runs directly on the Proxmox node over SSH.
It extracts the upstream Debian netinst ISO, injects a rendered preseed.cfg, patches the
GRUB and ISOLINUX boot menus for fully unattended boot, then repacks it as a hybrid
BIOS+EFI ISO.

**Command:**

```bash
ansible-playbook -i inventory/hosts.ini build-debian-preseed-iso.yml
```

**Output:**

```
kenny@Nebula:~/git$  ansible-playbook -i /home/kenny/git/proxmox-ve-vms-ansible/inventory/hosts.ini /home/kenny/git/proxmox-ve-vms-ansible/build-debian-preseed-iso.yml 2>&1 | tail -15
changed: [proxmox-vm-bm-machine]

TASK [Print output ISO info] ***************************************************
ok: [proxmox-vm-bm-machine] => {
    "msg": [
        "Preseed ISO built successfully.",
        "Output: /var/lib/vz/template/iso/debian-13-amd64-preseed.iso",
        "Size: 969.0 MiB",
        "Reference this ISO in vms.yml -> iso_file: debian-13-amd64-preseed.iso"
    ]
}

PLAY RECAP *********************************************************************
proxmox-vm-bm-machine      : ok=24   changed=13   unreachable=0    failed=0    skipped=3    rescued=0    ignored=0   
```

---

## Step 2 — Create the VM on Proxmox

The `create-vm-from-iso-proxmox.yml` playbook talks to the Proxmox REST API from localhost
to create the VM shell (CPU, RAM, disk, net), mount the preseed ISO as a CD-ROM, and set
the boot order to ISO-first.

**Command:**

```bash
ansible-playbook -i inventory/hosts.ini create-vm-from-iso-proxmox.yml \
  --tags "createVMs,createDisks,mountIso,bootOrder"
```

**Output:**

```
kenny@Nebula:~/git$  ansible-playbook -i /home/kenny/git/proxmox-ve-vms-ansible/inventory/hosts.ini /home/kenny/git/proxmox-ve-vms-ansible/create-vm-from-iso-proxmox.yml --tags "createVMs,createDisks,mountIso,bootOrder" 2>&1
[WARNING]: Invalid characters were found in group names but not replaced, use -vvvv to see details

PLAY [Manage VMs via Proxmox API] **********************************************

TASK [Normalize/merge defaults into each VM item] ******************************
ok: [localhost]

TASK [Create empty VM shells] **************************************************
changed: [localhost] => (item=ansible-debian-01)

TASK [Create and or update system disks (scsi0)] *******************************
changed: [localhost] => (item=ansible-debian-01)

TASK [Mount ISO as CD-ROM (ide2)] **********************************************
changed: [localhost] => (item=ansible-debian-01)

TASK [Set boot order from vms.yml (or default)] ********************************
changed: [localhost] => (item=ansible-debian-01)

PLAY RECAP *********************************************************************
localhost                  : ok=5    changed=4    unreachable=0    failed=0    skipped=0    rescued=0    ignored=0   
```

---

## Step 3 — Run the Automated Installer

The `auto-install-debian.yml` playbook handles the entire install lifecycle:

1. **PLAY 1** — Boot the VM via Proxmox API
2. **PLAY 2** — Wait for the VM to halt after install (poweroff triggered by `late_command`),
   eject the ISO, set boot order to disk-first, power on, then poll the qemu-guest-agent
   API to discover the VM's IP address automatically
3. **PLAY 3** — Verify `ansible` user SSH + sudo access, update `inventory/hosts.ini`
   automatically

**Command:**

```bash
ansible-playbook -i inventory/hosts.ini auto-install-debian.yml
```

**Output:**

```
[PASTE OUTPUT HERE]
```

---

## Step 4 — Install Base Packages

The `setup-debian-base.yml` playbook connects to the new VM over SSH using the `ansible`
user and:
- Runs `apt safe-upgrade`
- Installs base packages: `htop btop vim curl wget git tmux net-tools bash-completion unzip jq qemu-guest-agent`
- Sets `vim` as the default editor
- Disables SSH password authentication
- Confirms the sudoers file for the `ansible` user

**Command:**

```bash
ansible-playbook -i inventory/hosts.ini setup-debian-base.yml
```

**Output:**

```
[PASTE OUTPUT HERE]
```

---

## How the Preseed Works

The `preseed/debian-preseed.cfg.j2` Jinja2 template is rendered by Ansible at ISO build
time. Key sections:

- **Locale / keymap / timezone** — configured from `preseed_vars.yml`
- **Networking** — DHCP by default; static IP supported via `preseed_ip` per-VM variable
- **Partitioning** — single root partition, atomic recipe, full disk LVM removed
- **Package selection** — `openssh-server sudo qemu-guest-agent curl wget vim`
- **`late_command`** — injects the SSH public key into `/home/ansible/.ssh/authorized_keys`,
  creates `/etc/sudoers.d/ansible` with `NOPASSWD:ALL`, enables qemu-guest-agent,
  then **calls `poweroff -f`** to immediately halt the system. This fires before the
  d-i "Installation complete" dialog can appear, giving the playbook a clean poweroff
  signal to detect.

---

## How IP Auto-Discovery Works

The VM is defined in `vms.yml` with `preseed_install: true` and **no `ip_address` field**.
PLAY 2 of `auto-install-debian.yml` polls the Proxmox REST API endpoint:

```
GET /api2/json/nodes/{node}/qemu/{vmid}/status/current
```

until `status == stopped` (the `poweroff -f` in late_command triggers this). It then:

1. Ejects the ISO from `ide2`
2. Sets boot order to `scsi0;net0`
3. Powers the VM on
4. Polls the guest agent endpoint:
   ```
   GET /api2/json/nodes/{node}/qemu/{vmid}/agent/network-interfaces
   ```
   until the agent reports a non-loopback IPv4 address.

The discovered IP is stored in `inventory/hosts.ini` automatically under `[new-debian-vms]`.

---

## Variable Reference

| Variable | File | Default | Description |
|---|---|---|---|
| `preseed_iso_src_file` | `preseed_vars.yml` | `debian-13.1.0-amd64-netinst.iso` | Source netinst ISO filename |
| `preseed_iso_dest_file` | `preseed_vars.yml` | `debian-13-amd64-preseed.iso` | Output preseed ISO filename |
| `preseed_debian_suite` | `preseed_vars.yml` | `trixie` | Debian suite for APT mirror |
| `preseed_ansible_user` | `preseed_vars.yml` | `ansible` | User created during install |
| `preseed_ssh_pub_key_file` | `preseed_vars.yml` | `~/.ssh/id_rsa.pub` | SSH public key injected for the ansible user |
| `preseed_ssh_wait_timeout` | `preseed_vars.yml` | `2400` | Max seconds to wait for install to complete |
| `preseed_ssh_wait_delay` | `preseed_vars.yml` | `30` | Polling interval in seconds |
| `preseed_boot_wait_seconds` | `preseed_vars.yml` | `30` | Seconds to wait after VM power-on before polling guest agent |
| `debian_base_packages` | `preseed_vars.yml` | `htop btop vim ...` | Packages installed by setup-debian-base.yml |
