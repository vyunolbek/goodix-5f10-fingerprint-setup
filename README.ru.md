# Goodix 5f10 (27c6:5f10) — отпечаток пальца в Linux, включая экран блокировки KDE Plasma

Рабочая инструкция для сканера **Goodix 27c6:5f10** (milanG / чип ST411SEC,
прошивка `GF_ST411SEC_APP_12705`) из ноутбуков HONOR MagicBook
(X16 Pro / X14 Plus «FMI-XX», встречается и в DRA-XX и др.). Сенсор **не
поддерживается основным libfprint**; этот репозиторий — обвязка над
 community-драйвером ([levantez/goodix-5f10-linux-driver](https://github.com/levantez/goodix-5f10-linux-driver),
подключён сабмодулем) с фиксами, без которых разблокировка **пальцем на экране
блокировки** работает нестабильно или не работает вовсе.

**Проверено на:** Ubuntu 26.04, KDE Plasma 6.6 / SDDM, libfprint `1.95.1+tod1`,
fprintd `1.94.5`, HONOR MagicBook X14 Plus 2024 (FMI-XX, AMD).

**Настроить через ИИ-агента?** Скормите ему [`PROMPT_SETUP.md`](PROMPT_SETUP.md) —
там полный промпт с контрольными точками.

**English?** See [`README.md`](README.md).

---

## Что этот репозиторий добавляет к драйверу

| Часть | Файл | Зачем |
|---|---|---|
| **Патч «сброс MCU при закрытии»** | `patches/mcu-reset-at-close.patch` | Сток-драйвер при завершении сессии сбрасывает только *сенсор*. После **оборванной сессии** (пользователь бросил тапать и ввёл пароль → гритер отменил verify → TLS-поток оборван посередине) MCU остаётся в «грязном» состоянии: на команды отвечает, но все кадры *следующей* сессии — мусор (score 0–10 по всем шаблонам). Патч шлёт при закрытии устройства **полный soft-reset MCU (команда 0xa2, биты 0b011)** — каждая сессия стартует с чистым сенсором, как после гибернации. Без него локскрин падает ровно *после* первой же неудачи, и дальше навсегда. |
| **PAM-оверрайды** | `pam/kde`, `pam/kde-fingerprint`, `pam/sddm` | Беды гритера Plasma и SDDM: (1) `pam_kwallet5` в стеках с отпечатком (`kde-fingerprint`, `sddm`) после успешного отпечатка просит **пароль** — и вход пальцем зависает; (2) `pam_fprintd` в *обоих* стеках локскрина (интерактивном `kde` и `kde-fingerprint`) устраивает гонку за устройство; (3) в стоковом стеке sddm pam_fprintd приходит через common-auth с `max-tries=1 timeout=10` и без всякой подсветки в теме — окно пальца открывается только после отправки поля, ранние касания теряются. |
| **Скрипт восстановления** | `scripts/fix-sensor.sh` | Если сенсор совсем перестал отвечать (`Open failed: Command timed out: 0x96`) после жёсткого обрыва — программный сброс MCU оживляет его. |
| **Сабмодули** | `driver/`, `vendor/goodix-fp-dump` | Драйвер TOD и Python-транспорт для одноразового PSK-провижининга. |

## Проверка железа

```bash
lsusb | grep 27c6:5f10        # должен показать Goodix-сенсор
cat /sys/class/dmi/id/product_name   # например FMI-XX
```

> **Двойная загрузка с Windows?** Провижининг **перезаписывает заводской TLS-ключ
> сенсора** (он запечатан Windows DPAPI и на Linux не восстанавливается).
> Windows-драйвер после этого перестанет видеть сенсор до переинициализации. На
> машинах только с Linux альтернативы нет — см. [Безопасность](#безопасность) и
> [Sbenazar/goodix-5f10-psk](https://github.com/Sbenazar/goodix-5f10-psk)
> (путь восстановления PSK с живого Windows-раздела).

## Установка (Ubuntu 26.04)

### 1. Пакеты

```bash
sudo apt install -y git meson ninja-build gcc g++ pkg-config \
  libfprint-2-tod-dev libssl-dev libopencv-dev libglib2.0-dev \
  libgusb-dev libusb-1.0-0-dev fprintd libpam-fprintd \
  python3-venv python3-dev
```

### 2. Клонирование с сабмодулями, подготовка транспорта

```bash
git clone --recurse-submodules https://github.com/vyunolbek/goodix-5f10-fingerprint-setup
cd goodix-5f10-fingerprint-setup

# provisioning-скрипты ждут дампер строго по этому пути
mkdir -p driver/provisioning/vendor
cp -r vendor/goodix-fp-dump driver/provisioning/vendor/

cd driver
python3 -m venv .venv
# ВАЖНО: пакет называется "python-periphery", а НЕ "periphery"
.venv/bin/pip install pyusb python-periphery spidev
```

### 3. Патч + сборка + установка драйвера

```bash
git apply ../patches/mcu-reset-at-close.patch
./build.sh                       # получится build/libfprint-tod-goodix5f10.so
sudo ./packaging/install.sh      # ставит .so + udev-правило, перезапускает fprintd
```

### 4. Одноразовый PSK-провижининг

```bash
sudo .venv/bin/python provisioning/provision.py --check          # здоровье сенсора
sudo .venv/bin/python provisioning/provision.py --write --combined
```

`--check` должен показать прошивку `GF_ST411SEC_APP_12705` и читаемый хэш PMK;
`--write --combined` пишет продакшн TLS-блоб (устройство отвечает OK), после
чего TLS-хендшейк обязан пройти. Выполняется **один раз на машину**.

### 5. PAM

```bash
# отпечаток в common-auth: sudo / SDDM / polkit / терминал
sudo pam-auth-update --enable fprintd

# оверрайды для локскрина Plasma (в Ubuntu 26.04 сток лежит в /usr/lib/pam.d,
# локальные файлы в /etc/pam.d имеют приоритет)
sudo cp pam/kde /etc/pam.d/kde
sudo cp pam/kde-fingerprint /etc/pam.d/kde-fingerprint

# экран входа SDDM (пропустите, если остались на gdm3)
sudo cp pam/sddm /etc/pam.d/sddm
```

Правила, зашитые в эти файлы:
* `kde` (интерактивный/парольный стек): **без** `pam_fprintd` — иначе он
  конфликтует со стеком отпечатка за устройство;
* `kde-fingerprint`: `pam_fprintd.so max_tries=5 timeout=60` и **без**
  `pam_kwallet5` — иначе после успешного отпечатка выпадает запрос пароля и
  гритер виснет. KWallet при разблокировке пальцем просто остаётся закрытым
  (при входе по паролю — как обычно, расшифровывается).
* `sddm` (экран входа, **только если SDDM — ваш display manager**): инлайнит
  `common-auth` с `pam_fprintd.so max_tries=3 timeout=30` (окно 30 с, 3
  попытки) и **без `pam_kwallet5` в auth-фазе** — иначе тот же висяк с запросом
  пароля после матча. Сессионный `pam_kwallet5 auto_start` оставлен
  (просто запускает kwalletd запертым).

### 5а. SDDM вместо GDM (опционально)

Ubuntu может по умолчанию ставить `gdm3` даже с KDE. Переключение:

```bash
sudo apt install sddm kde-config-sddm          # обычно уже стоит
echo sddm shared/default-x-display-manager select sddm | sudo debconf-set-selections
echo /usr/bin/sddm | sudo tee /etc/X11/default-display-manager
sudo systemctl disable gdm3 gdm 2>/dev/null; sudo rm -f /etc/systemd/system/display-manager.service
sudo systemctl enable sddm
sudo reboot
```

UX SDDM: стоковые темы **не показывают подсказку про палец** — окно пальца
открывается после **первой отправки поля пароля** (можно пустого, Enter);
после этого касайтесь сенсора в течение 30 с. Тема и HiDPI настраиваются в
*Параметры системы → Цвета и темы → Экран входа*.

### 6. Регистрация и тесты

```bash
fprintd-enroll                 # 16 касаний, палец поднимать между касаниями
fprintd-verify
sudo -k && sudo true           # sudo по пальцу
```

Затем заблокируйте сессию (Meta+L) и коснитесь сенсора. Подробности, зачем
понадобились патч и PAM-хирургия — в разделе
[Как отлаживали падение локскрина](#как-отлаживали-падение-локскрина).

## Траблшутинг

| Симптом | Причина | Лечение |
|---|---|---|
| `Open failed: Command timed out: 0x96` | сенсор «умер» после жёсткого обрыва | `scripts/fix-sensor.sh` (soft MCU reset) |
| Локскрин мгновенно пишет «не удалось сопоставить отпечаток» | два `pam_fprintd` дерутся за устройство | поставить оверрайд `pam/kde` |
| Отпечаток совпал (лог fprintd), но экран не разблокируется | запрос пароля от kwallet внутри стека отпечатка | поставить оверрайд `pam/kde-fingerprint` |
| После загрузки/гибернации работает, дальше — никогда | грязный MCU после оборванной сессии | применить `patches/mcu-reset-at-close.patch` |
| SDDM: отпечаток совпал (лог fprintd), но вход не завершается | запрос пароля от kwallet внутри стека sddm | поставить оверрайд `pam/sddm` |
| SDDM: касания ничего не делают | окно пальца не открыто — оно стартует после отправки поля | нажать Enter на пустом поле, затем касаться (≤30 с) |
| SDDM: огромная экранная клавиатура закрывает вход | пакет `budgie-sddm-theme` в `/etc/sddm.conf.d/50-ubuntu-budgie.conf` принудительно ставит `InputMethod=qtvirtualkeyboard` для любой темы | `sudo apt remove budgie-sddm-theme` (на KDE он не нужен) или переопределить `InputMethod=` пустым в более позднем conf-файле |
| Enroll не регистрирует касания | палец уже лежит, пока драйвер снимает базовую линию | поднять палец, перезапустить `fprintd-enroll`, ждать приглашения, потом касаться |
| dmesg: `usbfs: process fprintd did not claim interface 1 before use` | драйвер пользуется data-интерфейсом без claim | безвредно, игнорировать |
| Кадры матчатся слабо (score ≈ порога 20) | короткие тапы / неполный контакт | прижимать ~1 с; драйвер сам переснимает в окне |

Подробные логи драйвера при отладке:

```bash
sudo systemctl edit fprintd      # [Service] → Environment=G_MESSAGES_DEBUG=all
```

Оверрайд потом удалить.

## Безопасность

* Провижининг **перезаписывает заводской PSK** публичным общим ключом из репо
  драйвера (`psk.hex`). Любой с **физическим доступом к USB** теоретически
  может читать кадры сенсора; физический доступ — и так game over (шифруйте диск).
* Шаблоны отпечатков лежат в `/var/lib/fprint`, их защищает только шифрование диска.
* Пароль всегда остаётся запасным входом: `pam_fprintd` стоит как `sufficient`.
* Помните про юридический статус биометрической разблокировки в вашей юрисдикции.

## Как отлаживали падение локскрина

1. *Терминальный `fprintd-verify`, `sudo`, SDDM — работали.* Падал только
   локскрин Plasma.
2. debug-логи fprintd показывали, что отпечаток **совпадает** на уровне fprintd,
   а экран остаётся заблокированным → проблема выше fprintd.
3. По исходникам гритера Plasma 6.6 (`kscreenlocker_greet`,
   `PamAuthenticator`/`PamWorker`): он запускает несколько PAM-стеков параллельно
   — интерактивный `kde`, non-interactive `kde-fingerprint` и `kde-smartcard` —
   а `PamWorker::converse()` открывает **вложенный event-loop на любой
   парольный запрос**. `pam_kwallet5` (optional, после `pam_fprintd`) выдавал
   ровно такой запрос → разблокировка пальцем не могла завершиться никогда.
4. Убрали `pam_fprintd` из интерактивного стека (гонка за устройство исчезла),
   `pam_kwallet5` из стека отпечатка (висение исчезло).
5. Осталось: локскрин работает **после гибернации**, но не после обычной
   блокировки. Кадры падавших сессий набирали 0–10 очков против всех шаблонов →
   систематически испорченный захват, а не шум. В
   `provisioning/gx5f10/recover.py` прямо написано, что **soft reset MCU** —
   лекарство от «залипшего» сенсора; закрытие устройства в драйвере сбрасывало
   только *сенсорную часть*. Итог: любая оборванная сессия (гритер отменяет
   verify, когда пользователь вводит пароль) оставляла MCU грязным для
   следующей — паттерн «работает только после сна». Патч сброса MCU при
   закрытии разорвал цикл; проверено стресс-тестом (verify убит SIGKILL'ом
   посреди потока → локскрин всё равно разблокируется пальцем, матч 88/20 на
   8-м кадре первого касания).

## Авторы и источники

* [levantez/goodix-5f10-linux-driver](https://github.com/levantez/goodix-5f10-linux-driver) —
  драйвер TOD (TLS-транспорт, SIGFM-матчер на хосте, provisioning)
* [goodix-fp-linux-dev/goodix-fp-dump](https://github.com/goodix-fp-linux-dev/goodix-fp-dump) —
  документация низкоуровневого USB-протокола
* [Sbenazar/goodix-5f10-libfprint](https://github.com/Sbenazar/goodix-5f10-libfprint) и
  [Sbenazar/goodix-5f10-psk](https://github.com/Sbenazar/goodix-5f10-psk) —
  альтернативный форк libfprint целиком и путь восстановления PSK с Windows
* libfprint / fprintd / KDE Plasma

Патч в `patches/` — производное от LGPL-2.1+ драйвера и наследует его лицензию;
на остальное — делайте что полезно.
