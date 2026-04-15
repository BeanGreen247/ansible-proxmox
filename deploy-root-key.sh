#!/usr/bin/env bash
# deploy-root-key.sh
# Deploys your SSH public key to root on every host using the vault-stored
# root passwords. Run this once before setup-ansibleuser.yml.
#
# Usage:
#   bash deploy-root-key.sh

set -euo pipefail

PUB_KEY="${HOME}/.ssh/id_rsa.pub"
VAULT_PASS_FILE="${HOME}/.vault_pass.txt"

if [[ ! -f "$PUB_KEY" ]]; then
  echo "ERROR: $PUB_KEY not found. Generate it with: ssh-keygen -t rsa -b 4096"
  exit 1
fi

if [[ ! -f "$VAULT_PASS_FILE" ]]; then
  echo "ERROR: $VAULT_PASS_FILE not found."
  exit 1
fi

# host_name -> ip
declare -A HOSTS=(
  ["lxc-prometheus"]="192.168.0.248"
  ["lxc-grafana"]="192.168.0.247"
  ["lxc-proxexport"]="192.168.0.246"
  ["lxc-optiping"]="192.168.0.244"
  ["lxc-wazuh"]="192.168.0.243"
  ["vm-debian-media-server"]="192.168.0.230"
  ["vm-debian-remote-desktop"]="192.168.0.245"
  ["vm-alpine-gitea-dev.server.wow"]="192.168.0.249"
  ["vm-debian-ut99-server"]="192.168.0.108"
  ["vm-debian-dev.server.wow"]="192.168.0.250"
  ["vm-debian-navidrome-bean"]="192.168.0.163"
  ["vm-debian-mc-server"]="192.168.0.142"
  ["vm-alpine-mysql-bckp-dev.wow.server"]="192.168.0.251"
  ["vm-debian-ut2004-server"]="192.168.0.129"
)

for host in "${!HOSTS[@]}"; do
  ip="${HOSTS[$host]}"
  vault_file="host_vars/${host}/vault.yml"

  if [[ ! -f "$vault_file" ]]; then
    echo "[$host] SKIP — no vault file found at $vault_file"
    continue
  fi

  password=$(ansible-vault view "$vault_file" \
    --vault-password-file "$VAULT_PASS_FILE" \
    | grep 'ansible_password' \
    | sed 's/ansible_password:[[:space:]]*//' \
    | tr -d '"')

  echo -n "[$host] ($ip) deploying key ... "
  if sshpass -p "$password" ssh-copy-id \
      -i "$PUB_KEY" \
      -o StrictHostKeyChecking=no \
      -o ConnectTimeout=5 \
      "root@${ip}" 2>/dev/null; then
    echo "OK"
  else
    echo "FAILED (wrong password, host down, or already key-only)"
  fi
done

echo ""
echo "Done. Now run: ansible-playbook -i inventory/hosts.ini setup-ansibleuser.yml"
