# SSH Access Guide

How to reach all LXCs and VMs from your laptop — directly on LAN, through the
RPi bastion SSH jump when you're off-network, and via Tailscale for seamless
access to web UIs (Grafana, Proxmox, Jellyfin) with near-zero bandwidth overhead.

---

## Problem: why CIS hardening locked you out

`cis-harden.yml` applies:

- `AllowUsers ansibleuser cartman` — only those two users may SSH in
- `PasswordAuthentication no` — key-only; your key must be in `authorized_keys`
- `AllowTcpForwarding no` — no port forwarding on the managed hosts

If you could no longer log in from your laptop it is because either:
1. `cartman` did not exist on that host (LXCs skip `setup-debian-base.yml`), or
2. Your laptop's `~/.ssh/id_rsa.pub` was not in `cartman`'s `authorized_keys`.

---

## Fix: deploy personal access to all hosts

```bash
# Ensure cartman exists everywhere and has your key
ansible-playbook deploy-personal-access.yml

# LXCs only
ansible-playbook deploy-personal-access.yml --limit lxcs

# Key deployment only (user already exists)
ansible-playbook deploy-personal-access.yml --tags ssh_key
```

Variables (in `group_vars/all/preseed_vars.yml`):

| Variable | Default | Purpose |
|---|---|---|
| `vm_enduser_name` | `cartman` | Your personal login username |
| `vm_enduser_ssh_pub_key_file` | `~/.ssh/id_rsa.pub` | Laptop public key to deploy |
| `vm_enduser_groups` | `sudo` | Supplementary groups |

---

## Direct LAN access (laptop on home network)

After running `deploy-personal-access.yml`, add this to your laptop's
`~/.ssh/config`:

```ssh-config
# ── Proxmox LXCs ────────────────────────────────────────────────────────
Host lxc-prometheus
    HostName 192.168.0.248
    User cartman
    IdentityFile ~/.ssh/id_rsa

Host lxc-grafana
    HostName 192.168.0.247
    User cartman
    IdentityFile ~/.ssh/id_rsa

Host lxc-proxexport
    HostName 192.168.0.246
    User cartman
    IdentityFile ~/.ssh/id_rsa

Host lxc-optiping
    HostName 192.168.0.244
    User cartman
    IdentityFile ~/.ssh/id_rsa

Host lxc-wazuh
    HostName 192.168.0.243
    User cartman
    IdentityFile ~/.ssh/id_rsa

# ── Proxmox VMs ─────────────────────────────────────────────────────────
Host vm-media
    HostName 192.168.0.230
    User cartman
    IdentityFile ~/.ssh/id_rsa

Host vm-desktop
    HostName 192.168.0.245
    User cartman
    IdentityFile ~/.ssh/id_rsa

Host vm-gitea
    HostName 192.168.0.249
    User cartman
    IdentityFile ~/.ssh/id_rsa

Host vm-ut99
    HostName 192.168.0.108
    User cartman
    IdentityFile ~/.ssh/id_rsa

Host vm-dev
    HostName 192.168.0.250
    User cartman
    IdentityFile ~/.ssh/id_rsa

Host vm-navidrome
    HostName 192.168.0.163
    User cartman
    IdentityFile ~/.ssh/id_rsa

Host vm-mc
    HostName 192.168.0.142
    User cartman
    IdentityFile ~/.ssh/id_rsa

Host vm-ut2004
    HostName 192.168.0.129
    User cartman
    IdentityFile ~/.ssh/id_rsa

Host vm-proxmox-bm
    HostName 192.168.0.222
    User cartman
    IdentityFile ~/.ssh/id_rsa
```

Then just:

```bash
ssh lxc-grafana
ssh vm-dev
```

---

## Off-network access via RPi bastion + Tailscale

### Architecture

```
[Laptop — anywhere]
    │
    ├─ SSH ProxyJump ──────────────────────────────────────────────────────┐
    │   ssh -J bastion@rpi <target>    (terminal access, near-zero bandwidth)
    │                                                                      ↓
    │                                                         [RPi — only exposed host]
    │                                                                      │
    │                                          ┌───────────────────────────┤
    │                                          ↓                           ↓
    │                                    [lxc-grafana]              [vm-dev] ...
    │
    └─ Tailscale (WireGuard) ─────────────────────────────────────────────┐
        laptop joins Tailnet          RPi advertises 192.168.0.0/24       │
        → reach any 192.168.0.x directly  (Grafana:3000, Proxmox:8006)   │
        → extremely low bandwidth (WireGuard protocol)                    │
        → Cockpit on RPi: https://<rpi-tailscale-ip>:9090  ──────────────┘
```

**Bandwidth note**: WireGuard (Tailscale's protocol) adds ~60 bytes of overhead
per packet — comparable to a raw SSH session. For terminal use it is effectively
indistinguishable from direct connection. For web UIs you only transfer the UI
itself, not a video stream like RDP/VNC.

---

### Step 1 — Deploy the RPi

```bash
# 1. Flash Raspberry Pi OS Lite (64-bit Bookworm) to a microSD card.
# 2. Enable SSH: create an empty file named 'ssh' in /boot/firmware/
# 3. Boot the RPi on your LAN.
# 4. Add it to inventory/hosts.ini under [rpi-bastions]:
#      rpi-bastion ansible_host=192.168.0.10 ansible_user=pi ansible_ssh_private_key_file=~/.ssh/id_rsa
# 5. Bootstrap ansibleuser:
ansible-playbook setup-ansibleuser.yml -u pi --limit rpi-bastions
# 6. Harden, configure SSH bastion, Tailscale subnet router, and Cockpit:
ansible-playbook setup-rpi-bastion.yml
```

### Step 2 — Tailscale auth key (optional but recommended)

Generate a reusable auth key at https://login.tailscale.com/admin/settings/keys and
store it in `host_vars/rpi-bastion/vault.yml`:

```yaml
bastion_tailscale_authkey: !vault |
  $ANSIBLE_VAULT;1.1;AES256
  ...
```

Without it, Tailscale installs but you authenticate manually on first boot:
```bash
ssh rpi-bastion
sudo tailscale up --advertise-routes=192.168.0.0/24
```

Then in the Tailscale admin console: **Machines → RPi → Edit route settings → approve 192.168.0.0/24**.

### Step 3 — Router port forward (SSH only)

Forward one external TCP port to the RPi for SSH access. Tailscale does *not*
need a port forward — it punches through NAT automatically.

```
Router rule: external TCP 2222  →  192.168.0.10:22
```

Set `cis_bastion_ssh_port: 22` in `setup-rpi-bastion.yml` vars (the router maps
the external port; sshd on the RPi always listens on 22 internally).

### Step 4 — Install Tailscale on your laptop

```bash
# Linux
curl -fsSL https://tailscale.com/install.sh | sh
sudo tailscale up --accept-routes

# macOS / Windows: download from https://tailscale.com/download
# iOS / Android: install from App Store / Play Store
```

`--accept-routes` tells the client to use the RPi's advertised `192.168.0.0/24` route.

### Step 5 — Laptop `~/.ssh/config`

```ssh-config
# ── RPi Bastion (SSH ProxyJump) ──────────────────────────────────────────
Host rpi-bastion
    HostName <your-public-IP-or-DDNS-hostname>
    Port 2222                          # external port you forwarded on router
    User bastion                       # the jump account (nologin shell)
    IdentityFile ~/.ssh/id_rsa
    ServerAliveInterval 30
    ServerAliveCountMax 3

# ── LXCs via bastion ────────────────────────────────────────────────────
Host lxc-prometheus
    HostName 192.168.0.248
    User cartman
    IdentityFile ~/.ssh/id_rsa
    ProxyJump rpi-bastion

Host lxc-grafana
    HostName 192.168.0.247
    User cartman
    IdentityFile ~/.ssh/id_rsa
    ProxyJump rpi-bastion

Host lxc-proxexport
    HostName 192.168.0.246
    User cartman
    IdentityFile ~/.ssh/id_rsa
    ProxyJump rpi-bastion

Host lxc-optiping
    HostName 192.168.0.244
    User cartman
    IdentityFile ~/.ssh/id_rsa
    ProxyJump rpi-bastion

Host lxc-wazuh
    HostName 192.168.0.243
    User cartman
    IdentityFile ~/.ssh/id_rsa
    ProxyJump rpi-bastion

# ── VMs via bastion ─────────────────────────────────────────────────────
Host vm-media
    HostName 192.168.0.230
    User cartman
    IdentityFile ~/.ssh/id_rsa
    ProxyJump rpi-bastion

Host vm-desktop
    HostName 192.168.0.245
    User cartman
    IdentityFile ~/.ssh/id_rsa
    ProxyJump rpi-bastion

Host vm-gitea
    HostName 192.168.0.249
    User cartman
    IdentityFile ~/.ssh/id_rsa
    ProxyJump rpi-bastion

Host vm-dev
    HostName 192.168.0.250
    User cartman
    IdentityFile ~/.ssh/id_rsa
    ProxyJump rpi-bastion

Host vm-navidrome
    HostName 192.168.0.163
    User cartman
    IdentityFile ~/.ssh/id_rsa
    ProxyJump rpi-bastion

Host vm-mc
    HostName 192.168.0.142
    User cartman
    IdentityFile ~/.ssh/id_rsa
    ProxyJump rpi-bastion

Host vm-ut99
    HostName 192.168.0.108
    User cartman
    IdentityFile ~/.ssh/id_rsa
    ProxyJump rpi-bastion

Host vm-ut2004
    HostName 192.168.0.129
    User cartman
    IdentityFile ~/.ssh/id_rsa
    ProxyJump rpi-bastion
```

SSH to any host from anywhere:
```bash
ssh lxc-grafana
ssh vm-dev
```

### Step 6 — Access web UIs via Tailscale (no port forward, no tunnel command)

Once your laptop is on the Tailnet and the route is approved:

| Service | URL |
|---|---|
| Proxmox UI | http://192.168.0.222:8006 |
| Grafana | http://192.168.0.247:3000 |
| Jellyfin | http://192.168.0.230:8096 |
| Navidrome | http://192.168.0.163 |
| Cockpit (RPi) | https://192.168.0.10:9090 |

These work from your browser directly — no SSH tunnels, no VPN client dialogs,
just open the URL.

### Cockpit — browser terminal for system maintenance

Cockpit gives you a full terminal and system health view in a browser tab.
It uses the same bandwidth as SSH.

- **On LAN**: `https://192.168.0.10:9090` (replace with your RPi's IP)
- **Off-network via Tailscale**: `https://<rpi-tailscale-ip>:9090`
- Login: your personal user (`cartman`) or `ansibleuser`
- Root login is disabled

Cockpit is blocked from the internet by UFW (port 9090 only allows
`192.168.0.0/24` and Tailscale `100.64.0.0/10`).

---

## Physical RPi terminal device (future)

The RPi can plug into a display + keyboard as a **zero-config maintenance
terminal** — connect it to any ethernet port and you have direct LAN SSH access
to everything with no laptop, no internet needed. Add a small TFT HAT + keyboard
(e.g. PiSugar + Waveshare) for a portable device.

---

## Security summary

| Control | LXCs/VMs | RPi Bastion |
|---|---|---|
| Root login | `no` | `no` |
| Password auth | `no` | `no` |
| AllowUsers | `ansibleuser cartman` | `ansibleuser bastion` |
| AllowTcpForwarding | `no` (CIS-compliant) | `yes` (required for ProxyJump) |
| Fail2ban | via auditd | enabled (3 retries → 1h ban) |
| UFW | SSH + service ports | SSH + Tailscale + Cockpit (LAN/TS only) |
| Tailscale | not installed | subnet router, WireGuard encrypted |
| Cockpit | not installed | port 9090, LAN + Tailscale only |

The internal LXCs/VMs are never touched. CIS compliance is fully preserved.
Only the RPi — which you own and control — is the single external exposure point.

---

## Troubleshooting

**"Permission denied (publickey)" on LXC/VM**
- Confirm your key is deployed: `ansible-playbook deploy-personal-access.yml`
- Check AllowUsers on the target: `sudo sshd -T | grep allowusers`

**"Connection refused" through bastion**
- Check the RPi UFW: `sudo ufw status`
- Verify fail2ban hasn't banned your IP: `sudo fail2ban-client status sshd`
- Test direct first: `ssh -p 2222 bastion@<rpi-public-ip>`

**"channel 0: open failed"**
- `AllowTcpForwarding` must be `yes` on the RPi: `sudo sshd -T | grep allowtcp`

**Tailscale: can't reach 192.168.0.x from laptop**
- Confirm `--accept-routes` is set on the laptop: `tailscale status`
- Confirm the subnet route is approved: Tailscale admin → Machines → RPi → Routes
- Check `tailscale status` on the RPi — should show `advertised routes: 192.168.0.0/24`

**Cockpit: "This site can't be reached" from outside LAN**
- Expected — Cockpit is UFW-blocked from internet. Access via Tailscale: `https://<ts-ip>:9090`
