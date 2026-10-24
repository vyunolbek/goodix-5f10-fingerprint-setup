#!/bin/bash
# Build an Ubuntu sddm .deb with parallel fingerprint + password login
# (upstream sddm PR #2176, "feat: parallel fingerprint + password authentication").
#
# Result: true Windows-like behavior at the SDDM login screen:
#   - the sensor is polled from the moment the greeter appears (no keypresses)
#   - typing a password + Enter stops the polling and logs in instantly
#   - a failed password attempt restarts the fingerprint polling
#
# Run from the repository root:  ./scripts/build-sddm-fp.sh
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$(pwd)

# 0. build tools and build dependencies
sudo apt-get install -y devscripts build-essential >/dev/null
if ! grep -q '^Types: deb deb-src' /etc/apt/sources.list.d/ubuntu.sources 2>/dev/null; then
  sudo sed -i 's/^Types: deb$/Types: deb deb-src/' /etc/apt/sources.list.d/ubuntu.sources
  sudo apt-get update -qq
fi
sudo apt-get build-dep -y sddm >/dev/null

# 1. fetch the exact distro source
BUILD=~/sddm-fp-build
mkdir -p "$BUILD" && cd "$BUILD"
rm -rf sddm-*/ # rebuild from scratch
apt-get source sddm >/dev/null
SRC=$(find . -maxdepth 1 -type d -name 'sddm-*' | head -1)
cd "$SRC"

# 2. apply the parallel-auth patch and record it in the quilt series
patch -p1 < "$ROOT/sddm/pr2176-fingerprint-parallel-auth.patch" >/dev/null
cp "$ROOT/sddm/pr2176-fingerprint-parallel-auth.patch" debian/patches/
echo pr2176-fingerprint-parallel-auth.patch >> debian/patches/series
dch -l fp1 --force-distribution -D UNRELEASED \
  'Add parallel fingerprint + password authentication (sddm PR #2176)' </dev/null >/dev/null
# normalize the version to a clean local suffix (+fp1)
sed -i "0,/^sddm (\(.*\)) UNRELEASED/s//sddm (\1+fp1) UNRELEASED/" debian/changelog 2>/dev/null || true
V=$(dpkg-parsechangelog -S Version | sed 's/fp[0-9]*1$/fp1/')
[ "$V" != "$(dpkg-parsechangelog -S Version)" ] && sed -i "1s/($(dpkg-parsechangelog -S Version))/($V)/" debian/changelog

# 3. build binary packages only
DEB_BUILD_OPTIONS=nocheck dpkg-buildpackage -us -uc -b -j"$(nproc)" >/dev/null

echo
echo "Built: $BUILD/sddm_${V}_amd64.deb"
echo "Next:"
echo "  sudo apt install \"$BUILD/sddm_${V}_amd64.deb\""
echo "  sudo apt-mark hold sddm   # do not let updates overwrite the fork"
echo "  sudo cp pam/sddm-fingerprint /etc/pam.d/sddm-fingerprint   # from repo root"
echo "  sudo cp pam/sddm /etc/pam.d/sddm                           # password-only stack"
echo "  sudo cp /usr/share/sddm/themes/breeze/Login.qml{.orig,}    # if a theme patch was used"
echo "  sudo reboot"
