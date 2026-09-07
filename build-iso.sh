#!/usr/bin/env bash
# arch-oneshot-installer: builds a custom Arch Linux live ISO that auto-runs
# install/install-arch.sh as root the moment the live medium's tty1
# autologin shell starts. Boots and installs unattended on any UEFI x86_64
# machine; see README.md for the current package/DE choices (fixed for now,
# see TODO for making them interactive).
#
# How the autorun works: Arch's live root .zlogin unconditionally sources
# ~/.automated_script.sh if present (verified against the current
# archlinux/archiso releng profile). We drop our script in at that exact
# path inside the ISO's airootfs before building, so it runs at login with
# no boot-parameter tricks and no race conditions.
#
# Run this on an Arch/Manjaro Linux machine (NOT on the target machine).

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK="$HERE/build/work"
OUT="$HERE/build/out"
PROFILE="$HERE/build/profile"

command -v mkarchiso >/dev/null 2>&1 || {
    echo "mkarchiso not found - installing archiso"
    sudo pacman -S --needed --noconfirm archiso
}

echo "==> Resetting build/ directory"
sudo rm -rf "$WORK" "$OUT" "$PROFILE"
mkdir -p "$PROFILE"

echo "==> Copying releng base profile"
cp -r /usr/share/archiso/configs/releng/* "$PROFILE/"

echo "==> Pointing the build at real Arch repos (not this host's distro mirrors)"
# This profile's pacman.conf pulls in /etc/pacman.d/mirrorlist by default, which
# on a non-Arch host (e.g. Manjaro) points at that distro's own curated/delayed
# mirrors - missing packages like archinstall/reflector, and offering multiple
# kernel/broadcom-wl "providers" Arch itself doesn't have. Use Arch's official
# geo-balanced mirror instead so this builds correctly regardless of host distro.
cat > "$PROFILE/mirrorlist-arch" <<'EOF'
Server = https://geo.mirror.pkgbuild.com/$repo/os/$arch
EOF
sed -i "s|^Include = /etc/pacman.d/mirrorlist|Include = $PROFILE/mirrorlist-arch|" "$PROFILE/pacman.conf"

echo "==> Removing packages no longer in Arch's official repos"
# broadcom-wl (precompiled) was dropped from extra - it doesn't support
# current kernels. We already install broadcom-wl-dkms from AUR post-boot
# (see install/aur-packages.txt), so the live ISO itself doesn't need it.
sed -i '/^broadcom-wl$/d' "$PROFILE/packages.x86_64"

echo "==> Downloading target-system packages for a fully offline install"
# install-arch.sh's pacstrap step must not require network on the Mac -
# wifi isn't automated (no credentials to connect with) and wired Ethernet
# may not be plugged in. We resolve the full dependency closure of
# install/packages.txt here (where we do have network) and embed it as a
# local pacman repo inside the ISO; the installer installs from that local
# repo only. Network on the Mac stays purely optional, for the best-effort
# AUR extras (VS Code, broadcom-wl-dkms) and for SSH recovery access.
PKG_CACHE="$HERE/build/pkgcache"
mkdir -p "$PKG_CACHE"
mapfile -t TARGET_PKGS < <(grep -v '^\s*#' "$HERE/install/packages.txt" | grep -v '^\s*$')
mkdir -p "$PROFILE/pacman.db.tmp"
sudo pacman -Syw --noconfirm \
    --config "$PROFILE/pacman.conf" \
    --cachedir "$PKG_CACHE" \
    --dbpath "$PROFILE/pacman.db.tmp" \
    "${TARGET_PKGS[@]}" < /dev/null
sudo rm -rf "$PROFILE/pacman.db.tmp"

OFFLINE_REPO="$PROFILE/airootfs/root/offline-repo"
mkdir -p "$OFFLINE_REPO"
cp "$PKG_CACHE"/*.pkg.tar.zst "$OFFLINE_REPO/"

echo "==> Building AUR-only packages so they're available offline (no runtime network needed)"
# yay itself isn't in the official repos - pacman -Syw above can't resolve
# AUR packages - so it's built here (where there's network) and dropped
# into the same offline repo. Old approach (git clone + build at runtime
# on the target) was best-effort and skipped entirely without network;
# this makes it unconditional. Add more AUR-only packages here the same
# way if needed - but prefer an official-repo alternative when one exists
# (see the login-screen theme choice in README: arc-gtk-theme was tried
# here first and dropped - its upstream tarball is missing git-submodule
# content its build needs, unrelated to anything in this script).
command -v makepkg >/dev/null 2>&1 || {
    echo "makepkg not found - installing base-devel"
    sudo pacman -S --needed --noconfirm base-devel
}
AUR_BUILD_PKGS=(yay-bin)
AUR_BUILD_DIR="$HERE/build/aur-build"
rm -rf "$AUR_BUILD_DIR"
mkdir -p "$AUR_BUILD_DIR"
for pkg in "${AUR_BUILD_PKGS[@]}"; do
    git clone --depth=1 "https://aur.archlinux.org/${pkg}.git" "$AUR_BUILD_DIR/$pkg"
    # Some AUR PKGBUILDs verify upstream source tarballs with the
    # maintainer's PGP signature, whose public key we won't have. The
    # source is still checksum-verified either way (makepkg always checks
    # sha256/sha512 first) - if only the signature step fails, retry
    # skipping just that check rather than managing per-maintainer keys.
    ( cd "$AUR_BUILD_DIR/$pkg" && makepkg -s --noconfirm ) \
        || ( cd "$AUR_BUILD_DIR/$pkg" && echo "    PGP signature check failed (source checksum already verified) - retrying with --skippgpcheck" && makepkg -s --noconfirm --skippgpcheck )
    cp "$AUR_BUILD_DIR/$pkg"/*.pkg.tar.zst "$OFFLINE_REPO/"
done

( cd "$OFFLINE_REPO" && repo-add oneshot-offline.db.tar.gz ./*.pkg.tar.zst >/dev/null )
echo "    offline repo size: $(du -sh "$OFFLINE_REPO" | cut -f1)"
# PKG_CACHE at build/pkgcache is intentionally NOT wiped between builds (it's
# outside build/work, build/out, build/profile) so re-runs re-download only
# what changed. Delete it yourself for a fully clean re-fetch.

echo "==> Installing autorun script into airootfs"
install -Dm755 "$HERE/install/install-arch.sh" "$PROFILE/airootfs/root/.automated_script.sh"
install -Dm644 "$HERE/install/packages.txt" "$PROFILE/airootfs/root/packages.txt"
install -Dm644 "$HERE/install/aur-packages.txt" "$PROFILE/airootfs/root/aur-packages.txt"

echo "==> Installing SSH key for remote recovery access"
# sshd is already enabled by default in this releng profile, and its
# sshd_config.d/10-archiso.conf already permits root login - but live root
# has no password and PermitEmptyPasswords isn't set, so nothing can
# actually log in yet. Dropping our own key in makes `ssh root@<live-ip>`
# work during the automated install if something goes wrong and you need to
# poke around instead of just watching it fail on the console.
SSH_PUBKEY="${SSH_PUBKEY:-$HOME/.ssh/id_ed25519.pub}"
if [[ -f "$SSH_PUBKEY" ]]; then
    sudo install -d -m700 -o root -g root "$PROFILE/airootfs/root/.ssh"
    sudo install -m600 -o root -g root "$SSH_PUBKEY" "$PROFILE/airootfs/root/.ssh/authorized_keys"
    echo "    baked in: $SSH_PUBKEY"
else
    echo "    WARNING: $SSH_PUBKEY not found - no SSH recovery access will be configured."
fi

echo "==> Setting ISO label/name"
sed -i 's/^iso_name=.*/iso_name="arch-oneshot"/' "$PROFILE/profiledef.sh"
sed -i 's/^iso_label=.*/iso_label="ARCH_OS_$(date +%Y%m)"/' "$PROFILE/profiledef.sh"

echo "==> Building ISO (this takes a while)"
sudo mkarchiso -v -w "$WORK" -o "$OUT" "$PROFILE"

echo
echo "==> Done. ISO at:"
ls -1 "$OUT"/*.iso
