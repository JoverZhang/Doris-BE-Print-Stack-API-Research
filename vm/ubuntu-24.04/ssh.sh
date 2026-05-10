#!/usr/bin/env bash
set -euo pipefail

ssh_port="${VM_SSH_PORT:-2222}"
key="$(cd "$(dirname "$0")" && pwd)/id_ed25519"
exec ssh -i "$key" -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p "$ssh_port" repro@127.0.0.1 "$@"
