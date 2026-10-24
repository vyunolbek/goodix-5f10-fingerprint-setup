# PROMPT_SETUP.md — setup prompt for AI agents

> **Русский:** этот файл — готовый промпт для ИИ-агента (pi/Claude Code/Cursor и
> т.п.). Вставьте содержимое блока ниже в агента на целевой машине — он
> выполнит настройку с контрольными точками и проверками. Люди: инструкция для
> вас — в [`README.ru.md`](README.ru.md).

Copy everything below the line into the agent.

---

## ROLE

You are a Linux system agent. Set up fingerprint authentication on this
machine for the Goodix 27c6:5f10 sensor (HONOR MagicBook laptops) with the
community TOD driver, including reliable unlock on the KDE Plasma lock screen.
Work from the repo `goodix-5f10-fingerprint-setup` (already cloned at
`./` — current directory). Its `driver/` and `vendor/goodix-fp-dump` are git
submodules; run `git submodule update --init --recursive` first.
Reference docs: `README.md` (EN) / `README.ru.md` (RU) in the repo.
Ask the user before destructive steps (PSK write, PAM changes). Communicate in
the user's language.

## GROUND RULES

- Verify every checkpoint before moving on; if one fails, stop and
  troubleshoot (table below) instead of improvising.
- The user must physically touch the sensor during enrollment and tests —
  announce those moments clearly and wait for readiness.
- Never reboot. `sudo systemctl restart fprintd` is enough for driver reloads.

## STEP 0 — PREFLIGHT

```bash
lsusb | grep 27c6:5f10
cat /sys/class/dmi/id/product_name
lsblk -o NAME,FSTYPE,SIZE
```

Checkpoint 0.1: `lsusb` shows `27c6:5f10`. If not — wrong machine, abort.
Checkpoint 0.2: **Decision point — Windows partition.** If any NTFS/Windows
partition exists, STOP and warn: PSK provisioning overwrites the factory key
sealed with Windows DPAPI; the Windows driver will stop seeing the sensor until
re-initialized. Point the user to Sbenazar/goodix-5f10-psk (read-only PSK
recovery from the Windows partition, pairs with the Sbenazar libfprint fork — a
different driver than this one). Continue only with explicit user consent.
Checkpoint 0.3: KDE Plasma lock screen is the target (Ubuntu 26.04 + Plasma 6.x
verified). On other distros adapt PAM paths (see STEP 5) and keep the two rules.

## STEP 1 — PACKAGES

```bash
sudo apt install -y git meson ninja-build gcc g++ pkg-config \
  libfprint-2-tod-dev libssl-dev libopencv-dev libglib2.0-dev \
  libgusb-dev libusb-1.0-0-dev fprintd libpam-fprintd \
  python3-venv python3-dev
```

Checkpoint 1.1: `pkg-config --modversion libfprint-2` prints a `+tod1` version.
If libfprint has no TOD support, install `libfprint-2-tod1`/`-dev` from the
distro TOD packages first.

## STEP 2 — DRIVER WORKDIR

```bash
git submodule update --init --recursive
mkdir -p driver/provisioning/vendor
cp -r vendor/goodix-fp-dump driver/provisioning/vendor/
cd driver
python3 -m venv .venv
.venv/bin/pip install pyusb python-periphery spidev   # NB: python-periphery, NOT periphery
```

Checkpoint 2.1: pip install succeeds (spidev may need python3-dev — already in
STEP 1). The exact path `driver/provisioning/vendor/goodix-fp-dump` is
mandatory — provisioning's `vendor_path.py` expects it.

## STEP 3 — PATCH, BUILD, INSTALL

```bash
git apply ../patches/mcu-reset-at-close.patch
./build.sh
sudo ./packaging/install.sh
```

Checkpoint 3.1: build links `build/libfprint-tod-goodix5f10.so` without errors.
Checkpoint 3.2: `journalctl -u fprintd -n 20` after install shows the driver
loaded (`Opening driver ... libfprint-tod-goodix5f10.so`) and the device
detected. The patch is REQUIRED for lock-screen reliability after aborted
sessions — never skip it (see README «How the lock-screen failure was debugged»).

## STEP 4 — PSK PROVISIONING (one-time, destructive — ask user)

```bash
sudo .venv/bin/python provisioning/provision.py --check
```

Checkpoint 4.1: firmware `GF_ST411SEC_APP_12705` reported, PMK hash readable.

```bash
sudo .venv/bin/python provisioning/provision.py --write --combined
```

Checkpoint 4.2: device replies OK, TLS handshake succeeds. If TLS/transport
hangs or later `Open failed: Command timed out: 0x96` appears — run
`../scripts/fix-sensor.sh` (soft MCU reset) and retry.

## STEP 5 — PAM

```bash
sudo pam-auth-update --enable fprintd
sudo cp ../pam/kde /etc/pam.d/kde
sudo cp ../pam/kde-fingerprint /etc/pam.d/kde-fingerprint
```

Rules (distro-adapt as needed, keep the semantics):
1. `kde` (interactive lock-screen stack): stock file WITHOUT `pam_fprintd`
   (inlined common-auth minus fprintd) — two pam_fprintd instances race for
   the device and the fingerprint stack dies instantly.
2. `kde-fingerprint`: `pam_fprintd.so max_tries=5 timeout=60`, WITHOUT
   `pam_kwallet5` — kwallet issues a password prompt after a successful match,
   and the Plasma greeter blocks in a nested event loop (fingerprint unlock
   then never completes). KWallet stays locked on fingerprint unlocks —
   tell the user.
3. On Ubuntu 26.04+ stock PAM files live in `/usr/lib/pam.d`; local files in
   `/etc/pam.d` override them. Verify with:
   `grep -n pam_fprintd /etc/pam.d/kde` → no match;
   `grep -n pam_fprintd /etc/pam.d/kde-fingerprint` → exactly one auth line.
4. If `/etc/pam.d/kde` already exists (non-stock), diff first; base the
   override on the machine's own stock file, removing only fprintd/kwallet5
   as per rules 1–2. Back up anything you overwrite (`.orig.bak`).

## STEP 6 — ENROLL (user interaction!)

Tell the user: 16 touches, press ~1 s, LIFT the finger between touches, start
touching only after the prompt appears (touching too early corrupts the
baseline and touches are not registered).

```bash
fprintd-enroll          # watch for all 16 stages → enroll-completed
```

Checkpoint 6.1: `fprintd-list "$USER"` shows the enrolled finger.

## STEP 7 — VERIFICATION GATES

```bash
fprintd-verify                                   # gate 7.1: verify-match
sudo -k && sudo true                             # gate 7.2: sudo via PAM (exit 0, no password typed)
```

Gate 7.3 (lock screen): ask the user to get ready, then:
`loginctl lock-session` (or Meta+L); user touches the sensor within a few
seconds and keeps tapping up to ~15 s until unlock. Gate passed only if the
screen unlocks BY FINGERPRINT (ask the user, and check
`journalctl -u fprintd --since '-2 min'` for `verify-match`).

Gate 7.4 (stress — proves the MCU-reset patch): simulate an aborted session,
then lock again:

```bash
fprintd-verify & sleep 6; kill -9 %1             # abort mid-verify
# user: touch during those 6 s if possible
journalctl -u fprintd -n 30 | grep 'MCU reset at close'   # must appear
loginctl lock-session                            # user unlocks by fingerprint again
```

Gate 7.4 passed if the second lock screen still unlocks by fingerprint.

## STEP 8 — CLEANUP

- Remove any fprintd debug override:
  `sudo rm -f /etc/systemd/system/fprintd.service.d/debug.conf && sudo systemctl daemon-reload`
- Leave the repo on disk; document machine specifics in a local NOTES file.

## TROUBLESHOOTING (in order of likelihood)

| Symptom | Fix |
|---|---|
| `Open failed: Command timed out: 0x96` | `../scripts/fix-sensor.sh` |
| Lock screen: instant «failed to match» | `pam/kde` override missing pam_fprintd-removal → re-do STEP 5 |
| Match in fprintd log, screen stays locked | kwallet still in `kde-fingerprint` → re-do STEP 5 |
| Works after boot/hibernate only | mcu-reset patch not applied/built → re-do STEP 3 |
| Enroll: no touches registered | finger was on sensor at start → restart enroll, wait for prompt |
| dmesg `did not claim interface 1 before use` | benign, ignore |
| pip: no package «periphery» | use `python-periphery` |
| provision.py can't find goodix-fp-dump | path must be `driver/provisioning/vendor/goodix-fp-dump` |

## SUCCESS CRITERIA

All gates 7.1–7.4 green; `fprintd-list` shows the finger; user informed about:
KWallet not unlocking by fingerprint, PSK security caveats (public shared key,
factory key overwritten), recovery via `scripts/fix-sensor.sh`.
