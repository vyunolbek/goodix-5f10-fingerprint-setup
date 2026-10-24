#!/usr/bin/env bash
# Восстановление сенсора Goodix 27c6:5f10 после сбоя.
# Fix the Goodix 27c6:5f10 sensor when it stops responding.
# Симптом / symptom: fprintd-enroll падает с «Open failed: Command timed out: 0x96».
# Причина / cause: после оборванного TLS-сеанса сенсор перестаёт слать ACK;
# лечится программным сбросом MCU (команда RESET 0xa2) — см. driver/provisioning/gx5f10/recover.py.
# Запуск из корня репозитория / run from the repo root: scripts/fix-sensor.sh
set -e
cd "$(dirname "$0")/../driver"
if [ ! -d .venv ]; then
  echo "нет .venv — запусти / no .venv, run first:"
  echo "  cd driver && python3 -m venv .venv && .venv/bin/pip install pyusb python-periphery spidev"
  exit 1
fi
sudo systemctl stop fprintd 2>/dev/null || true
sudo .venv/bin/python - <<'EOF'
import sys, pathlib
sys.path.insert(0, str(pathlib.Path.cwd() / "provisioning"))
from gx5f10 import recover
print("soft_mcu_reset ->", recover.soft_mcu_reset())
EOF
sudo systemctl start fprintd
sleep 1
fprintd-list "$USER"
