# Goodix 5f10 (27c6:5f10) Fingerprint on Linux — full setup incl. KDE Plasma lock screen

Working recipe for the **Goodix 27c6:5f10** fingerprint sensor (milanG / ST411SEC
chip, firmware `GF_ST411SEC_APP_12705`) found in HONOR MagicBook laptops
(X16 Pro / X14 Plus «FMI-XX», also reported in DRA-XX and others). The sensor is
**not supported by mainline libfprint**; this repo orchestrates the community
TOD driver ([levantez/goodix-5f10-linux-driver](https://github.com/levantez/goodix-5f10-linux-driver),
included as a submodule) plus the fixes needed to make fingerprint unlock work
reliably **on the KDE Plasma lock screen**, not just in terminals.

**Tested on:** Ubuntu 26.04 (Resolute Raccoon), KDE Plasma 6.6 / SDDM,
libfprint `1.95.1+tod1`, fprintd `1.94.5`, HONOR MagicBook X14 Plus 2024 (FMI-XX, AMD).

**AI agent?** Feed [`PROMPT_SETUP.md`](PROMPT_SETUP.md) to your coding agent — it
contains a complete, checkpointed setup prompt.

**По-русски?** См. [`README.ru.md`](README.ru.md).

---

## What this repo adds on top of the driver

| Piece | File | Why |
|---|---|---|
| **MCU reset at close patch** | `patches/mcu-reset-at-close.patch` | The stock driver resets only the *sensor* when a session ends. After an **aborted session** (user gives up tapping and types the password → greeter cancels the verify → TLS stream torn down mid-flight) the MCU stays in a dirty state: it still answers commands, but every frame of the *next* session is garbage (match score 0–10 across all templates). The patch sends a **full soft MCU reset (cmd 0xa2, bits 0b011)** on device close, so every session starts with a pristine sensor — like after hibernation. Without it the lock screen fails exactly *after* the first failed/unlock-by-password attempt, forever. |
| **PAM overrides** | `pam/kde`, `pam/kde-fingerprint`, `pam/sddm` | Plasma greeter and SDDM bugs: (1) `pam_kwallet5` in fingerprint-first stacks (`kde-fingerprint`, `sddm`) asks for a **password after a successful fingerprint match**, and the greeter/DM then blocks — fingerprint-only login is impossible; (2) `pam_fprintd` present in *both* the interactive `kde` stack and `kde-fingerprint` makes two PAM stacks race for the device and the fingerprint stack dies instantly; (3) stock SDDM stacks get `pam_fprintd` via `common-auth` with `max-tries=1 timeout=10` and no UI hint — the finger window opens only when the user submits the field, so early touches are lost. |
| **Recovery script** | `scripts/fix-sensor.sh` | When the sensor stops ACKing entirely (`Open failed: Command timed out: 0x96`) after a hard abort, a software MCU reset revives it. |
| **Submodules** | `driver/`, `vendor/goodix-fp-dump` | The TOD driver and the Python USB transport used for one-time PSK provisioning. |

## Hardware preflight

```bash
lsusb | grep 27c6:5f10        # must show the Goodix sensor
cat /sys/class/dmi/id/product_name   # e.g. FMI-XX
```

> **Dual-boot Windows?** PSK provisioning **overwrites the sensor's factory TLS
> key** (it is sealed with Windows DPAPI and cannot be recovered on Linux).
> After provisioning the Windows driver will not talk to the sensor until
> re-initialized. On Linux-only machines there is no alternative — see
> [Security notes](#security-notes) and
> [Sbenazar/goodix-5f10-psk](https://github.com/Sbenazar/goodix-5f10-psk)
> for a read-only recovery route that needs a Windows partition.

## Install (Ubuntu 26.04)

### 1. Packages

```bash
sudo apt install -y git meson ninja-build gcc g++ pkg-config \
  libfprint-2-tod-dev libssl-dev libopencv-dev libglib2.0-dev \
  libgusb-dev libusb-1.0-0-dev fprintd libpam-fprintd \
  python3-venv python3-dev
```

### 2. Clone with submodules, prepare provisioning transport

```bash
git clone --recurse-submodules https://github.com/vyunolbek/goodix-5f10-fingerprint-setup
cd goodix-5f10-fingerprint-setup

# provisioning scripts expect the dump tool at this exact path
mkdir -p driver/provisioning/vendor
cp -r vendor/goodix-fp-dump driver/provisioning/vendor/

cd driver
python3 -m venv .venv
# NB: package is "python-periphery", NOT "periphery"
.venv/bin/pip install pyusb python-periphery spidev
```

### 3. Patch + build + install the driver

```bash
git apply ../patches/mcu-reset-at-close.patch
./build.sh                       # produces build/libfprint-tod-goodix5f10.so
sudo ./packaging/install.sh      # installs .so + udev rule, restarts fprintd
```

### 4. One-time PSK provisioning

```bash
sudo .venv/bin/python provisioning/provision.py --check          # sensor health
sudo .venv/bin/python provisioning/provision.py --write --combined
```

`--check` must report firmware `GF_ST411SEC_APP_12705` and a readable PMK hash;
`--write --combined` writes the production TLS blob (device answers OK) and a
TLS handshake must succeed. This is **one-time per machine**.

### 5. PAM

```bash
# fingerprint in common-auth: sudo / SDDM / polkit / terminal
sudo pam-auth-update --enable fprintd

# Plasma lock screen overrides (Ubuntu 26.04 keeps stock files in /usr/lib/pam.d,
# local files in /etc/pam.d win)
sudo cp pam/kde /etc/pam.d/kde
sudo cp pam/kde-fingerprint /etc/pam.d/kde-fingerprint

# SDDM login screen (skip if you stay on gdm3)
sudo cp pam/sddm /etc/pam.d/sddm
```

The rules encoded in these files:
* `kde` (interactive/password stack): **no** `pam_fprintd` — otherwise it races
  with the fingerprint stack for the device;
* `kde-fingerprint`: `pam_fprintd.so max_tries=5 timeout=60` and **no**
  `pam_kwallet5` — otherwise a password prompt follows a successful match and
  the greeter hangs. KWallet simply stays locked on fingerprint unlocks
  (it unlocks on password logins as before).
* `sddm` (login screen, **only if SDDM is your display manager**): inlines
  `common-auth` with `pam_fprintd.so max_tries=3 timeout=30` (30 s window,
  3 tries) and **no `pam_kwallet5` in the auth phase** — otherwise the same
  password-prompt-after-match hang. Session `pam_kwallet5 auto_start` stays
  (it just starts kwalletd locked).

### 5a. Using SDDM instead of GDM (optional)

Ubuntu may default to `gdm3` even on KDE installs. To switch:

```bash
sudo apt install sddm kde-config-sddm          # usually already there
echo sddm shared/default-x-display-manager select sddm | sudo debconf-set-selections
echo /usr/bin/sddm | sudo tee /etc/X11/default-display-manager
sudo systemctl disable gdm3 gdm 2>/dev/null; sudo rm -f /etc/systemd/system/display-manager.service
sudo systemctl enable sddm
sudo reboot
```

SDDM UX notes: the stock themes show **no fingerprint hint** and breeze does not
submit an **empty** field — the finger window opens only after you submit a
**non-empty** password field. Practical recipe: type **any character**, press
Enter, then touch the sensor within 30 s (the real password is not even
checked when the finger matches). Submitting the real password also opens the
finger window first; without a touch the password is checked after the window
closes. Theme/HiDPI are configured in *System Settings → Colors & Themes →
Login Screen*.

### 6. Enroll and test

```bash
fprintd-enroll                 # 16 touches, lift the finger between touches
fprintd-verify
sudo -k && sudo true           # sudo via fingerprint
```

Then lock the session (Meta+L) and touch the sensor. For the gory details of
why this needed the patch and PAM surgery, see
[How the lock-screen failure was debugged](#how-the-lock-screen-failure-was-debugged).

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `Open failed: Command timed out: 0x96` | sensor ACK-dead after a hard abort | `scripts/fix-sensor.sh` (soft MCU reset) |
| Lock screen shows “failed to match fingerprint” instantly | two `pam_fprintd` instances racing | install `pam/kde` override |
| Fingerprint matches (fprintd log) but screen stays locked | kwallet password prompt inside the fingerprint stack | install `pam/kde-fingerprint` override |
| Lock screen works right after boot/hibernate, then never | dirty MCU after an aborted session | apply `patches/mcu-reset-at-close.patch` |
| SDDM: fingerprint matched (fprintd log) but login doesn't complete | kwallet password prompt inside the sddm stack | install `pam/sddm` override |
| SDDM: touches do nothing | finger window not open — it starts only after a non-empty field submit (breeze ignores empty submits) | type any character + Enter, then touch (≤30 s) |
| SDDM: huge on-screen keyboard covers the greeter | `budgie-sddm-theme` package forces `InputMethod=qtvirtualkeyboard` in `/etc/sddm.conf.d/50-ubuntu-budgie.conf` for every theme | `sudo apt remove budgie-sddm-theme` (KDE machines don't need it) or override `InputMethod=` empty in a lexically later conf file |
| SDDM: plain white unstyled screen ("no theme at all") | the chosen theme is Qt5-era — SDDM 0.21 greeter is Qt6 and `import QtQuick.Controls 1.x` no longer exists; SDDM silently falls back to the embedded theme (WhiteSur and many other popular themes are affected) | install a Qt6 theme (`sudo apt install sddm-theme-breeze`) and set `Current=breeze`; check compatibility with `sddm-greeter-qt6 --test-mode --theme /usr/share/sddm/themes/<name>` (look for “module … is not installed” / “Fallback to embedded theme”) |
| Enrollment registers no touches | finger already on sensor while the driver takes its baseline | lift the finger, restart `fprintd-enroll`, wait for the prompt, then touch |
| dmesg: `usbfs: process fprintd did not claim interface 1 before use` | driver uses the sensor's data interface without claiming | benign, ignore |
| Frames match weakly (score ≈ threshold 20) | quick taps / partial contact | press firmly ~1 s; driver re-captures within the window |

Enable verbose driver logs when debugging:

```bash
sudo systemctl edit fprintd      # [Service] → Environment=G_MESSAGES_DEBUG=all
```

Remove the override afterwards.

## Security notes

* Provisioning **overwrites the factory PSK** with the public shared key from
  the driver repo (`psk.hex`). Anyone with **physical USB access** could read
  sensor frames; treat physical access as game over anyway (disk encryption!).
* Fingerprint templates are stored in `/var/lib/fprint`, protected only by
  disk encryption.
* Password always remains a fallback: `pam_fprintd` is `sufficient`, not
  `required`.
* Consider the legal standing of biometric unlock in your jurisdiction
  (compelled unlocking).

## How the lock-screen failure was debugged

1. *Terminal `fprintd-verify`, `sudo`, SDDM: all worked.* Only the Plasma lock
   screen failed.
2. fprintd debug logs showed the fingerprint **did match** at the fprintd level
   while the screen stayed locked → the failure was above fprintd.
3. Reading the Plasma 6.6 greeter sources (`kscreenlocker_greet`,
   `PamAuthenticator`/`PamWorker`): it runs several PAM stacks in parallel —
   interactive `kde`, non-interactive `kde-fingerprint` and `kde-smartcard` —
   and `PamWorker::converse()` opens a **nested event loop on any
   password-style prompt**. `pam_kwallet5` (optional, after `pam_fprintd`)
   issued exactly such a prompt → fingerprint-only unlock could never finish.
4. Removing `pam_fprintd` from the interactive stack stopped the device race
   (`two clients claiming`), removing `pam_kwallet5` from the fingerprint stack
   stopped the hang.
5. Remaining symptom: lock screen worked **after hibernation** but not after a
   regular lock. Frames of the failing sessions scored 0–10 against all
   enrolled templates → systematically corrupted captures, not noise.
   `provisioning/gx5f10/recover.py` documents that a **soft MCU reset** is the
   recovery for a wedged sensor; the driver's own close path only reset the
   *sensor part*. Result: any aborted session (greeter cancels the verify when
   the user types the password instead) dirtied the MCU for the next session →
   the “works only after hibernation” pattern. The close-time MCU-reset patch
   broke that loop; verified with a stress test (verify SIGKILLed mid-stream →
   lock screen still unlocks by fingerprint, match 88/20 on the 8th frame of
   the first touch).

## Credits

* [levantez/goodix-5f10-linux-driver](https://github.com/levantez/goodix-5f10-linux-driver) —
  the TOD driver (TLS transport, SIGFM host-side matcher, provisioning tooling)
* [goodix-fp-linux-dev/goodix-fp-dump](https://github.com/goodix-fp-linux-dev/goodix-fp-dump) —
  low-level USB protocol documentation/transport
* [Sbenazar/goodix-5f10-libfprint](https://github.com/Sbenazar/goodix-5f10-libfprint) and
  [Sbenazar/goodix-5f10-psk](https://github.com/Sbenazar/goodix-5f10-psk) —
  alternative full-libfprint fork with the Windows-PSK recovery route
* libfprint / fprintd / KDE Plasma teams

The patch in `patches/` is a derivative of the LGPL-2.1+ driver and inherits
its license; everything else in this repo: do whatever helps.
