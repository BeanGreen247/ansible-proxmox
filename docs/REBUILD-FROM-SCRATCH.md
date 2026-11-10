# Rebuilding a VM from scratch (new OS install)

Checklist for a freshly installed VM that must get back to the managed setup.
Worked example: `vm-debian-mc-server` (192.168.0.142). Run everything from the
repo root. Replace the host name as needed.

## 0. Prerequisites on the controller

- `~/.ssh/id_rsa` and `~/.ssh/id_rsa.pub` exist (deployed to every host).
- The host is in `inventory/hosts.ini` under `[vms]` (or `[lxcs]`) with the right
  `ansible_host` IP and `ansible_user=ansibleuser`.
- `ssh-keygen -R <ip>` if the VM reuses an old IP (new host key).
- The vault is only needed for vaulted values (see "Vault gotchas"). Bootstrap
  does not need it.

## 1. Bootstrap `ansibleuser` (one time, connects as root)

```bash
# root already has your pubkey (preseed / cloud-init)
ansible-playbook setup-ansibleuser.yml -u root --limit vm-debian-mc-server
# root has only a password (needs sshpass)
ansible-playbook setup-ansibleuser.yml -u root --ask-pass --limit vm-debian-mc-server
# root SSH disabled, you have another sudo user
ansible-playbook setup-ansibleuser.yml -u <user> --ask-pass --ask-become-pass --limit vm-debian-mc-server

ansible -m ping vm-debian-mc-server     # verify
```

Creates `ansibleuser`, passwordless sudo, and installs `~/.ssh/id_rsa.pub`.

## 2. Personal login user (e.g. `bean`) with a password

`vm_enduser_name` defaults come from `group_vars/all/` (`main.yml` = kenny,
`preseed_vars.yml` = cartman). Override per host in `host_vars/<host>/`.
`security-harden.yml` builds sshd `AllowUsers` from `vm_enduser_name`, so only
`ansibleuser` and that user can SSH in after hardening.

```bash
HASH=$(openssl passwd -6)               # prompts for the password

cat >> host_vars/vm-debian-mc-server/main.yml <<'EOF'

vm_enduser_name: bean
vm_enduser_groups: "sudo"
EOF

ansible-vault encrypt_string "$HASH" --name vm_enduser_password_hash \
  >> host_vars/vm-debian-mc-server/vault.yml     # gitignored (host_vars/*/vault.yml)
```

Without a password (key-only login) skip the vault step and add
`-e "vm_enduser_password_hash='!'"` to the playbooks below.

## 3. Playbooks, in order

```bash
# base packages, qemu-guest-agent, SSH key-only, creates the end user.
# Targets ONLY [new-debian-vms]: add the bare host name under that group in
# inventory/hosts.ini first (it inherits its vars from the [vms] line).
# --limit cannot widen a play past the group it names.
ansible-playbook setup-debian-base.yml --limit vm-debian-mc-server

ansible-playbook deploy-personal-access.yml --limit vm-debian-mc-server  # user + your key
ssh bean@192.168.0.142                                                   # TEST before hardening
ansible-playbook enforce-vim.yml --limit vm-debian-mc-server
ansible-playbook security-harden.yml --limit vm-debian-mc-server --check --diff
ansible-playbook security-harden.yml --limit vm-debian-mc-server         # real run
ansible-playbook wazuh_agent_deploy.yml --limit vm-debian-mc-server      # lxc-wazuh must be up
ansible-playbook update_upgrade.yml --limit vm-debian-mc-server
```

Order matters: the user and its key must exist before `security-harden.yml`
locks sshd to `AllowUsers`. Per-host UFW ports and the vsftpd preserve list
live in `host_vars/<host>/main.yml` (`cis_ufw_extra_ports`,
`cis_preserve_services_extra`); see `docs/FIREWALL-PORTS.md`.

## 4. Not covered by any playbook (restore by hand or from backup)

- The Minecraft server itself: Java, server jar, Geyser (Bedrock, port 28258),
  world data, the management panel on 8888.
- vsftpd on the mc-server (`restore-vsftpd.yml` only targets the media and
  navidrome VMs).
- Prefer a Proxmox backup restore (`pve-backup-jobs.yml`,
  `group_vars/all/backup_jobs.yml`) over rebuilding the data.

## Vault gotchas

- `ansible.cfg` reads `~/.vault_pass.txt`. If it does not match the password
  that encrypted a value, you get "Decryption failed (no vault secrets were
  found that could decrypt)". Test with `ansible-vault decrypt --output=/dev/null`
  on a copy of the value. Do not print it.
- `group_vars/all/main.yml` is gitignored and holds vaulted values (end-user
  hash, Proxmox API credentials). Losing the vault password means re-entering
  them; `example_of_main.yml` shows the shape.
- A vaulted value is only evaluated when used. Overriding with `-e` skips it.
- Keep the vault password in KeePass (`~/.keepass`) so it is not lost again.

## Common errors

| Symptom | Cause / fix |
|---|---|
| `skipping: no hosts matched` | Play targets a group the host is not in (`setup-debian-base.yml` = `[new-debian-vms]`). |
| `python3-apt must be installed to use check mode` | `--check` on a fresh VM. Run for real once. |
| Locked out after hardening | End user or its key missing before `security-harden.yml`. Fix via console, then `deploy-personal-access.yml`. |
