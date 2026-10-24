#!/bin/bash
# Откат sddm+fp1 на стоковый Ubuntu sddm + рабочая схема «автозапуск окна пальца».
# Запуск из TTY (Ctrl+Alt+F3) или из сеанса: sudo sddm-fp-rollback && sudo reboot
set -ex
cd /home/vyunolbek/sddm-fp-build
apt-mark unhold sddm || true
apt install -y --allow-downgrades ./sddm_0.21.0+git20250502.4fe234b-2ubuntu3_amd64.deb
cp /etc/pam.d/sddm.v2.bak /etc/pam.d/sddm
rm -f /etc/pam.d/sddm-fingerprint
cp /home/vyunolbek/fp-theme-work/Login.qml /usr/share/sddm/themes/breeze/Login.qml
echo "OK — sddm сток + окно пальца восстановлены. Перезагрузитесь: sudo reboot"
