# Quickstart — using this repo day to day

Task-oriented companion to [`README.md`](../README.md) (the full
reference) and [`docs/user-guide.md`](user-guide.md) (the "zero to a
running VM" first-time walkthrough). This file is the fast answer to
three questions: how do I run this properly, how do I test a change
before trusting it, and which file do I actually edit for a given
config change.

---

## Using it properly

- **Everything is API-driven, not SSH-driven, for VM/LXC lifecycle.**
  `create-vm-from-iso-proxmox.yml` and `create-lxc-proxmox.yml` talk to
  Proxmox's REST API (`community.proxmox` collection) using the token in
  `group_vars/all/main.yml` (gitignored — copy `example_of_main.yml` and
  fill in real values, see `docs/user-guide.md` Phase 0–1 if this is your
  first time). No sudo needed on the control host for these.
- **Guest-level playbooks are SSH-driven** (`setup-ansibleuser.yml`,
  `setup-debian-base.yml`, `update_upgrade.yml`, `wazuh_agent_deploy.yml`,
  etc.) — these need the guest in `inventory/hosts.ini` and reachable by
  key auth as `ansibleuser`.
- **Tags matter — use them.** Most playbooks are tag-gated so you don't
  accidentally re-run a destructive or slow step:
  - `create-vm-from-iso-proxmox.yml`: `createVMs`, `createDisks`,
    `mountIso`, `bootOrder`, `diskResize` (grow-only, shrink blocked),
    `updateVMs` (config-only: memory/cores/sockets/cpu/scsihw/net/
    ostype/agent/onboot — **never** disk/CD-ROM), `removeVMs` (tagged
    `never` — needs an explicit `--tags removeVMs`, won't fire by
    accident).
  - `create-lxc-proxmox.yml` has the equivalent shape for containers.
- **Read the playbook's own header comment first.** Every playbook here
  documents its own tags, variables, and usage examples at the top of the
  file — that's the authoritative reference, README's Playbook Reference
  section summarizes it.
- **Destructive ops need explicit opt-in tags** (`removeVMs`, LXC
  destroy) and are policy-blocked from automated agents — a human runs
  those, not a script.
- **The vault password file** (`~/.vault_pass.txt`, referenced by
  `ansible.cfg`) must exist before anything touching `main.yml` or
  `preseed_vars.yml`'s vaulted values will run non-interactively.

---

## Running tests

`scripts/test_playbooks.sh` runs yamllint + `ansible-playbook
--syntax-check` (every top-level playbook) + `ansible-lint --profile
basic` — the class of failure catchable without a real host or the
Proxmox API (bad YAML, undefined vars, broken Jinja, deprecated module
args). It cannot validate that an API call or VM spec is *logically*
correct for your actual Proxmox node — that still needs a real run.
`.github/workflows/ci.yml` runs the same script on every push/PR.

```bash
scripts/test_playbooks.sh
```

`ansible-lint` is pinned to the `basic` profile (not `production`) —
deliberately less strict than a from-scratch repo would use, to avoid
demanding this working, in-production repo be rewritten wholesale for
style. `.ansible-lint`'s `skip_list` documents the two rules skipped
with reasoning (one verified false-positive, one deliberate raw-shell
usage) — read it before adding more skips.

For anything that actually changes live infrastructure, the real test is
running it against Proxmox: `qm status <vmid>` / `pve_vm_status.yml` /
`--check --diff` where the module supports check mode (many
`community.proxmox` modules report `skipping` under `--check` rather than
previewing — don't rely on it the way you would for `ansible.builtin`
modules; read the playbook's own tags/guards instead).

---

## What file to change for a given config change

| I want to... | Edit | Then run |
|---|---|---|
| Add/resize/remove a VM | `group_vars/all/vms.yml` (`memory`/`cores`/`disk_size_gb`/etc per entry) | `ansible-playbook create-vm-from-iso-proxmox.yml --tags updateVMs` (config only) or the relevant tag for what changed — see the playbook header |
| Add/resize/remove an LXC container | `group_vars/all/lxcs.yml` | `ansible-playbook create-lxc-proxmox.yml` (see its header for per-field tags) |
| Change a VM/LXC's category/purpose label (shown in `pve_vm_status.yml`) | `group_vars/all/vm_categories.yml` (hand-maintained, not derived from anything live) | nothing to run — read only by `pve_vm_status.yml` at report time |
| Change Debian preseed install behavior (locale, timezone, mirror, default user) | `group_vars/all/preseed_vars.yml` | `ansible-playbook build-debian-preseed-iso.yml`, then re-create affected VMs |
| Add/change a scheduled Proxmox backup job | `group_vars/all/backup_jobs.yml` | `ansible-playbook pve-backup-jobs.yml` |
| Change which VMs get Guacamole Wake-on-Connect | `group_vars/all/guacamole_wol.yml` (`guacamole_wol_targets`) | `ansible-playbook deploy-guacamole-wol.yml` |
| Add a new host to fleet-wide ops (`update_upgrade.yml`, `wazuh_agent_deploy.yml`, etc.) | `inventory/hosts.ini` (add under `[vms]` or `[lxcs]`) | whatever fleet-wide playbook you're running next — no separate "register" step |
| Change Proxmox API credentials or `pm_node` | `group_vars/all/main.yml` (gitignored — copy from `example_of_main.yml` if it doesn't exist yet) | anything API-driven |
| Add/change a CIS hardening rule | `security-harden.yml` (task list) — check `cis_allow_ip_forward` host_vars override if the host runs Docker/NAT (see README's CIS section) | `ansible-playbook security-harden.yml --limit <host>` |

For anything not in this table, check the relevant playbook's own header
comment — it documents its own variables under "Inputs & variables" or
similar.

---

## See also

- [`README.md`](../README.md) — full reference: every playbook, every
  variable, vault usage, day-to-day operations.
- [`docs/user-guide.md`](user-guide.md) — first-time "zero to a running
  VM" walkthrough, if you're setting this up from scratch.
- [`docs/pipeline-walkthrough.md`](pipeline-walkthrough.md) — deep dive
  on the preseed provisioning pipeline specifically.
- [`docs/ssh-access.md`](ssh-access.md) — SSH/key setup details.
- [`docs/INVENTORY-CONSOLIDATION.md`](INVENTORY-CONSOLIDATION.md) — open
  proposal (not yet decided) to replace static `inventory/hosts.ini`
  here and in the sibling `ansible-stationctl` repo with a live
  Tailscale-based lookup.
