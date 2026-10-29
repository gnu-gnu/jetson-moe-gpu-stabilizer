#!/bin/bash
# usage: sudo ./uninstall.sh   (the service restores the minimum GPU floor when it stops)
set -euo pipefail
[ "$(id -u)" -eq 0 ] || { echo "run as root: sudo $0" >&2; exit 1; }
systemctl disable --now moe-gpu-stabilizer.service 2>/dev/null || true
rm -f /etc/systemd/system/moe-gpu-stabilizer.service /usr/local/sbin/moe-gpu-stabilizer
systemctl daemon-reload
echo "removed; /etc/default/moe-gpu-stabilizer was kept"
