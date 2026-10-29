#!/bin/bash
# usage: sudo ./install.sh
set -euo pipefail
cd "$(dirname "$0")"
[ "$(id -u)" -eq 0 ] || { echo "run as root: sudo $0" >&2; exit 1; }
command -v bpftrace >/dev/null || DEBIAN_FRONTEND=noninteractive apt-get install -y bpftrace
install -m 755 -o root -g root moe-gpu-stabilizer /usr/local/sbin/moe-gpu-stabilizer
install -m 644 -o root -g root moe-gpu-stabilizer.service /etc/systemd/system/moe-gpu-stabilizer.service
[ -e /etc/default/moe-gpu-stabilizer ] || install -m 644 -o root -g root moe-gpu-stabilizer.default /etc/default/moe-gpu-stabilizer
/usr/bin/python3 -I /usr/local/sbin/moe-gpu-stabilizer --check
systemctl daemon-reload
systemctl enable --now moe-gpu-stabilizer.service
systemctl restart moe-gpu-stabilizer.service
sleep 3
systemctl --no-pager status moe-gpu-stabilizer.service | head -12
