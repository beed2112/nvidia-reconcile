#!/usr/bin/env bash
# Install nvidia-reconcile. Run as root ON the target machine, from this dir:
#   sudo ./install.sh
set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ $EUID -ne 0 ]]; then
  echo "Run as root: sudo ./install.sh" >&2
  exit 1
fi

echo "==> Installing script to /usr/local/sbin"
install -m 0755 "$SRC/nvidia-reconcile.sh" /usr/local/sbin/nvidia-reconcile.sh

echo "==> Installing systemd unit"
install -m 0644 "$SRC/systemd/nvidia-reconcile.service" /etc/systemd/system/
systemctl daemon-reload
systemctl enable nvidia-reconcile.service

echo
echo "Done. It will run automatically at every boot (no-op unless it finds a"
echo "driver/library version mismatch). To reconcile right now:"
echo "    sudo /usr/local/sbin/nvidia-reconcile.sh"
echo "History:"
echo "    journalctl -t nvidia-reconcile"
