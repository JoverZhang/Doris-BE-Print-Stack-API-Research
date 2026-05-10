#!/usr/bin/env bash
set -euo pipefail

ssh_port="${VM_SSH_PORT:-2222}"
exec ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p "$ssh_port" repro@127.0.0.1 "$@"

