# Firewall ports — how to add/change one

`security-harden.yml`'s CIS 4 section puts every host in `lxcs`/`vms`
behind UFW with a default-deny-incoming policy. SSH (22/tcp) is opened
automatically for every host. **Everything else a host needs must be
declared per-host** — nothing else is open by default, and this file is
the only thing standing between "the firewall went live" and "the service
that host runs stopped being reachable."

This file only covers ansible-proxmox's own guests (`lxcs` + `vms`
groups). ansible-stationctl has its own copy of this same doc for its
`workstations` group — see that repo's `docs/FIREWALL-PORTS.md`. The two
repos manage different fleets; don't declare one repo's ports in the
other's host_vars.

## How to add a port

1. Open (or create) `host_vars/<hostname>/main.yml` for the guest.
2. Add or extend `cis_ufw_extra_ports`:

   ```yaml
   cis_ufw_extra_ports:
   - { port: "8080", proto: "tcp", comment: "Whatever web UI" }
   - { port: "27015", proto: "udp", comment: "Game server query port" }
   ```

   `port` can be a single port (`"8080"`) or a range (`"40000:40100"`).
   `proto` defaults to `tcp` if omitted — declare `udp` explicitly as a
   separate list entry if the service needs it too (UFW doesn't have a
   "both" shorthand in the `community.general.ufw` module the way the CLI
   does when you run `ufw allow <port>` with no proto).

3. **Do not** add `cis_ufw_extra_ports` in `security-harden.yml`'s own
   `vars:` block — host_vars would be silently overridden. This variable
   only belongs in `host_vars/<host>/main.yml`.

## How to apply it

```bash
ansible-playbook security-harden.yml --limit <hostname> --tags cis4
```

`--tags cis4` re-runs only the firewall section (fast, and skips
re-hardening SSH/PAM/auditd/etc. on a host that's already had the full
playbook run). Drop the tag for a first-time run on a new guest.

## How to verify it actually worked

```bash
ansible <hostname> -m shell -a "ufw status verbose" -b
```

Cross-check against what's actually listening, so you don't just confirm
the rule exists — confirm it's the right rule for the right thing:

```bash
ansible <hostname> -m shell -a "ss -tulnp" -b
```

Anything bound to `0.0.0.0`/`[::]` (not `127.0.0.1`/`[::1]`) that isn't
covered by an existing `cis_ufw_extra_ports` entry will go dark the next
time CIS 4 runs on that host.

## Where to look for undocumented ports on an existing guest

Before assuming a guest only needs what's already in its host_vars, check
two things — this is how the 2026-09-21 audit caught several real gaps
(mc-server's actual panel port, guacd on remote-desktop, ut2004's full
LinuxGSM port set):

1. **The guest's Proxmox Notes field** (visible in the Proxmox web UI, or
   via `community.proxmox.proxmox_vm_info` with `config: current` — the
   text is under `item.config.description`, not `item.description`).
   Several guests have manual setup notes there with the exact `ufw
   allow` commands that were run by hand outside Ansible.
2. **Live `ss -tulnp` + `ufw status verbose` on the host itself.** Notes
   go stale; the live firewall and socket table don't. Where they
   disagree with `host_vars`, trust the live state and update
   `host_vars` to match — a rebuild from Ansible alone should reproduce
   the same firewall a host actually has today, not just what's been
   formally declared.

## Current per-host ports (as of the 2026-09-21 audit)

Anything marked "unconfirmed" was found already `ufw allow`-ed live and
kept for compatibility even though nothing is currently listening behind
it or its purpose wasn't documented anywhere — removing a rule is a
one-way door if it turns out something intermittent needs it, so these
are left in place rather than pruned.

| Host | Ports | Notes |
|---|---|---|
| `lxc-prometheus` | 9090 tcp/udp, 9093 tcp/udp | Alertmanager (9093) not currently running |
| `lxc-proxexport` | 9100 tcp/udp, 9221 tcp/udp, 20 tcp/udp, 21 tcp/udp, 9090 tcp/udp | Last three: unconfirmed, nothing listening |
| `lxc-grafana` | 3000 tcp | |
| `lxc-optiping` | 8080 tcp | |
| `vm-debian-media-server` | 8096 tcp/udp, 21 tcp/udp, 20 tcp/udp, 40000:40100 tcp/udp, 40000:50000 tcp/udp, 30000:31000 tcp, 7359 tcp/udp, 9091 tcp/udp, 80 tcp/udp, 443 tcp/udp | Jellyfin (8096, 7359 discovery) confirmed live; FTP (20/21/passive ranges) and 9091/80/443 not currently listening |
| `vm-debian-navidrome-bean` | 4533 tcp, 21 tcp/udp, 40000:40100 tcp/udp, 30000:31000 tcp | FTP not currently listening |
| `vm-debian-remote-desktop` | 5901 tcp/udp, 8080 tcp, 4822 tcp/udp, 5091 tcp/udp | 4822 = guacd, confirmed live; 5091 unconfirmed |
| `vm-debian-mc-server` | 9900 tcp, 28258 tcp/udp, 8443 tcp/udp, 8888 tcp, 21 tcp/udp, 22 udp, 25565 tcp/udp, 2121 tcp/udp | 8888 = the actual live management panel (not 8443, despite the name); 25565/2121 unconfirmed |
| `vm-debian-ut99-server` | 8076 tcp/udp | |
| `vm-debian-ut2004-server` | 8075 tcp/udp, 7777:7787 udp, 7777/7778/7787 tcp, 10777 tcp/udp, 28902 tcp, 443 tcp/udp | LinuxGSM's `ucc-bin` binds several engine ports beyond the primary game port |

`vm-debian-workstation-01` is **not** in this repo's `vms`/`lxcs` groups
(it's in `new-debian-vms`) — it's hardened via ansible-stationctl's copy
of `security-harden.yml` instead. See that repo's `docs/FIREWALL-PORTS.md`.
