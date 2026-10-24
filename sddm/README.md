# Parallel fingerprint + password login at the SDDM screen

Stock SDDM cannot listen for a fingerprint before the user submits the
password field: PAM starts only on submit, and a Login message during an
active authentication is silently dropped (`Existing authentication ongoing,
aborting`). This has been open upstream since 2014 (sddm#284, sddm#1473).

The unmerged upstream PR **sddm/sddm#2176** *"parallel fingerprint + password
authentication"* fixes it properly at the daemon level:

- when the greeter connects, the daemon reads the last logged-in user from
  `/var/lib/sddm/state.conf` and immediately starts a **parallel PAM login
  through the `sddm-fingerprint` service** (finger polling, empty password);
- a finger match logs in instantly — no keypresses, nothing blocked;
- typing a password and pressing Enter **stops the polling** and proceeds with
  password auth (instant, `pam_unix` only);
- after a **failed** password attempt the finger polling restarts
  automatically;
- suspend/resume keeps finger polling working.

## Build & install (Ubuntu 26.04)

Everything is automated:

```bash
./scripts/build-sddm-fp.sh          # builds ~/sddm-fp-build/sddm_<ver>+fp1_amd64.deb
sudo apt install ~/sddm-fp-build/sddm_*+fp1_amd64.deb
sudo apt-mark hold sddm             # keep distro updates from overwriting the fork
```

The script enables `deb-src`, fetches the exact distro source, applies
`pr2176-fingerprint-parallel-auth.patch` (+134/−10 lines, 14 files — applies
cleanly onto `0.21.0+git20250502.4fe234b-2ubuntu3`) and builds with the stock
Debian packaging, so the result is a normal `.deb` with a `+fp1` version.

PAM wiring (files are in `pam/` of this repo):

```bash
sudo cp pam/sddm-fingerprint /etc/pam.d/sddm-fingerprint  # finger-only service (parallel)
sudo cp pam/sddm           /etc/pam.d/sddm               # password-only stack, no pam_fprintd
```

The upstream PR ships an Arch-style PAM file (`system-local-login` includes
that Ubuntu does not have), so use this repo's Ubuntu-style one instead.
`/etc/pam.d/sddm-fingerprint` runs the *same* session modules as the normal
login stack, so a fingerprint login lands in an identical session.

If a **breeze theme auto-submit patch** was previously used (the
finger-window hack for stock SDDM), revert it — it conflicts with the daemon
polling:

```bash
sudo cp /usr/share/sddm/themes/breeze/Login.qml{.orig,}
```

## Rollback

```bash
sudo sddm-fp-rollback        # scripts/sddm-fp-rollback.sh installed to /usr/local/bin
```

Reinstalls the stock Ubuntu sddm (keep the official `.deb` in
`~/sddm-fp-build/`), restores `pam/sddm`, removes the `sddm-fingerprint`
service and re-applies the breeze auto-submit theme patch (the finger-window
fallback scheme). From a broken boot use a TTY: Ctrl+Alt+F3, login,
`sudo sddm-fp-rollback && sudo reboot`.

## Maintenance

- `apt-mark hold sddm` pins the fork; on every distro sddm update, unhold,
  rebuild with `./scripts/build-sddm-fp.sh` (the patch is tiny and usually
  applies), reinstall, hold again.
- Watch upstream: once PR #2176 is merged and released, drop the local build
  and the `pam/sddm-fingerprint` file stays valid (it is what the daemon
  calls).
