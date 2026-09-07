#!/usr/bin/env bash
#
# arch-oneshot-installer: unattended Arch Linux install for any UEFI x86_64
# machine - wipes an empty disk, or dual-boots alongside an existing macOS
# install when it detects one (auto-detection today is Mac-specific; other
# dual-boot targets fall back to the interactive disk picker - see TODO in
# README.md). This is copied to /root/.automated_script.sh in the live ISO
# and sourced automatically by /root/.zlogin the moment root's autologin
# shell starts on tty1.
#
# Safety model: every check below must pass before the FIRST destructive
# command runs. If anything is ambiguous, this script prints why and exits
# to a normal interactive root shell WITHOUT TOUCHING THE DISK. It never
# guesses its way past an assumption violation.

set -uo pipefail

LOG=/root/install.log
exec > >(tee -a "$LOG") 2>&1

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PACKAGES_FILE="$SELF_DIR/packages.txt"
AUR_PACKAGES_FILE="$SELF_DIR/aur-packages.txt"

HOSTNAME=arch-oneshot
USERNAME=dev
ROOT_PLACEHOLDER_PW=changeme-root
USER_PLACEHOLDER_PW=changeme-dev
MIN_FREE_MIB=15360   # 15GiB minimum free space required to proceed
SWAP_SIZE=4G
TIMEZONE=UTC          # change post-install with `timedatectl set-timezone`
LOCALE=en_US.UTF-8

die() {
    echo
    echo "############################################################"
    echo "# ABORTED: $*"
    echo "# Nothing on disk was touched by this run. Dropping to the"
    echo "# normal live shell. Fix the issue and re-run:"
    echo "#   /root/.automated_script.sh"
    echo "############################################################"
    exit 1
}

step() { echo; echo "==> $*"; }

[[ $EUID -eq 0 ]] || die "must run as root (it does, on the live ISO - something is very wrong)"
[[ -f "$PACKAGES_FILE" ]] || die "missing $PACKAGES_FILE"

# ---------------------------------------------------------------------------
step "Checking for network (optional - base install works fully offline)"
# ---------------------------------------------------------------------------
# The base install pulls packages from the offline repo embedded in this ISO
# (see build-iso.sh) and never needs network. Network is only used, best
# effort, for the AUR extras (VS Code, broadcom-wl-dkms) and for SSH
# recovery access - neither is required to finish a working system. Wifi
# isn't auto-configured (no credentials baked in), so unless wired Ethernet
# is plugged in this will typically come back "no network", and that's fine.
NET_OK=0
for i in $(seq 1 5); do
    if curl -fsS --max-time 3 https://archlinux.org >/dev/null 2>&1; then
        NET_OK=1
        break
    fi
    sleep 2
done
if [[ $NET_OK -eq 1 ]]; then
    echo "    network is up - AUR extras and SSH recovery access will be set up"
else
    echo "    no network detected - continuing fully offline (this is expected without wired Ethernet)"
fi

# ---------------------------------------------------------------------------
step "Identifying the target disk (dual-boot next to macOS, or a clean empty disk)"
# ---------------------------------------------------------------------------
# Auto-detected, never guessed, in the two unambiguous shapes:
#   - "wipe": disk has NO partitions at all (completely blank/unpartitioned)
#     - uses the entire disk, creating a fresh ESP + swap + root.
#   - "sidebyside": disk has an EFI System Partition + HFS+/APFS (looks like
#     a Mac with macOS on it already) - installs into its free space, reuses
#     its existing ESP, never touches the macOS partitions.
# Anything else (zero matches, or more than one) is NOT guessed at - instead
# every disk on the system is listed and a human picks, interactively.
DUALBOOT_CANDIDATES=()
WIPE_CANDIDATES=()
for d in $(lsblk -dpno NAME,TYPE | awk '$2=="disk"{print $1}'); do
    PARTCOUNT=$(lsblk -no TYPE "$d" 2>/dev/null | grep -c '^part$')
    if [[ $PARTCOUNT -eq 0 ]]; then
        WIPE_CANDIDATES+=("$d")
        continue
    fi
    PARTTYPES=$(lsblk -no PARTTYPENAME "$d" 2>/dev/null || true)
    FSTYPES=$(lsblk -no FSTYPE "$d" 2>/dev/null || true)
    if grep -qi "EFI System" <<<"$PARTTYPES" && grep -qiE "hfsplus|apfs" <<<"$FSTYPES$PARTTYPES"; then
        DUALBOOT_CANDIDATES+=("$d")
    fi
done

TOTAL=$(( ${#DUALBOOT_CANDIDATES[@]} + ${#WIPE_CANDIDATES[@]} ))
if [[ $TOTAL -eq 1 ]]; then
    if [[ ${#WIPE_CANDIDATES[@]} -eq 1 ]]; then
        MODE=wipe
        DISK="${WIPE_CANDIDATES[0]}"
        echo "    target disk: $DISK (empty - will use the ENTIRE disk, no dual-boot)"
    else
        MODE=sidebyside
        DISK="${DUALBOOT_CANDIDATES[0]}"
        echo "    target disk: $DISK (Mac-shaped - installing alongside macOS in its free space)"
    fi
else
    # -------------------------------------------------------------------
    step "Could not auto-detect a single target disk ($([[ $TOTAL -eq 0 ]] && echo "no disk matched" || echo "$TOTAL disks matched") ) - listing all disks"
    # -------------------------------------------------------------------
    mapfile -t ALL_DISKS < <(lsblk -dpno NAME,TYPE | awk '$2=="disk"{print $1}')
    [[ ${#ALL_DISKS[@]} -gt 0 ]] || die "no disks found on this system at all"

    echo
    printf "    %-3s %-14s %-8s %s\n" "#" "DEVICE" "SIZE" "CONTENTS"
    for i in "${!ALL_DISKS[@]}"; do
        d="${ALL_DISKS[$i]}"
        dsize=$(lsblk -dno SIZE "$d")
        contents=$(lsblk -no FSTYPE,PARTTYPENAME "$d" 2>/dev/null | sed '/^\s*$/d' | paste -sd, -)
        [[ -n "$contents" ]] || contents="(empty - no partitions)"
        printf "    %-3s %-14s %-8s %s\n" "$((i+1))" "$d" "$dsize" "$contents"
    done
    echo

    DISK=""
    while [[ -z "$DISK" ]]; do
        read -r -p "    Enter the number of the disk to install to (or 'q' to abort): " choice
        [[ "$choice" == q ]] && die "disk selection aborted by user"
        if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#ALL_DISKS[@]} )); then
            DISK="${ALL_DISKS[$((choice-1))]}"
        else
            echo "    not a valid choice, try again"
        fi
    done
    echo "    selected: $DISK"

    MODE=""
    while [[ -z "$MODE" ]]; do
        read -r -p "    Wipe $DISK entirely, or install alongside what's already on it? [wipe/side]: " action
        case "$action" in
            wipe) MODE=wipe ;;
            side|sidebyside) MODE=sidebyside ;;
            *) echo "    please answer 'wipe' or 'side'" ;;
        esac
    done
    echo "    mode: $MODE"
fi

# Refuse to run again if this disk already has a Linux partition on it -
# i.e. a previous run of this exact script already completed here.
if lsblk -no FSTYPE "$DISK" | grep -qiE "^ext4$|^swap$"; then
    die "$DISK already has an ext4 or swap partition - looks like Arch is already installed here. Refusing to run again."
fi

CREATE_ESP=0
if [[ "$MODE" == sidebyside ]]; then
    # -----------------------------------------------------------------------
    step "Checking free space on $DISK"
    # -----------------------------------------------------------------------
    # parted machine-readable free-space report; take rows ending in "free;"
    mapfile -t FREE_ROWS < <(parted -sm "$DISK" unit MiB print free 2>/dev/null | grep 'free;$')
    [[ ${#FREE_ROWS[@]} -gt 0 ]] || die "no free space found on $DISK"

    BEST_SIZE=0
    BEST_ROW=""
    for row in "${FREE_ROWS[@]}"; do
        # format: N:START:END:SIZE:free;
        size_mib=$(awk -F: '{print $4}' <<<"$row" | tr -d 'MiB;')
        size_mib=${size_mib%.*}
        if [[ $size_mib -gt $BEST_SIZE ]]; then
            BEST_SIZE=$size_mib
            BEST_ROW="$row"
        fi
    done
    [[ -n "$BEST_ROW" ]] || die "could not parse free space on $DISK"

    # -----------------------------------------------------------------------
    step "Checking for an existing EFI System Partition on $DISK"
    # -----------------------------------------------------------------------
    ESP=$(lsblk -lnpo NAME,PARTTYPENAME "$DISK" | awk -F' ' 'tolower($0) ~ /efi system/ {print $1; exit}')
    if [[ -n "$ESP" ]]; then
        echo "    existing ESP found: $ESP (will be reused, not reformatted)"
    else
        CREATE_ESP=1
        echo "    no existing ESP found - a new 512MiB one will be created in the free space"
    fi

    NEEDED_MIB=$(( MIN_FREE_MIB + (CREATE_ESP ? 512 : 0) ))
    [[ $BEST_SIZE -ge $NEEDED_MIB ]] || die "largest free region on $DISK is only ${BEST_SIZE}MiB, need at least ${NEEDED_MIB}MiB"
    echo "    largest free region: ${BEST_SIZE}MiB - proceeding"
else
    # -----------------------------------------------------------------------
    step "Checking size of $DISK"
    # -----------------------------------------------------------------------
    CREATE_ESP=1
    DISK_MIB=$(( $(lsblk -bdno SIZE "$DISK") / 1024 / 1024 ))
    NEEDED_MIB=$(( MIN_FREE_MIB + 512 ))   # + the new ESP
    [[ $DISK_MIB -ge $NEEDED_MIB ]] || die "$DISK is only ${DISK_MIB}MiB, need at least ${NEEDED_MIB}MiB for a clean install"
    echo "    disk size: ${DISK_MIB}MiB - proceeding"
fi

# ===========================================================================
# Point of no return: everything above this line is read-only.
# ===========================================================================
if [[ "$MODE" == wipe ]]; then
    step "Creating a fresh GPT with EFI + swap + root partitions (entire disk)"
    sgdisk --zap-all "$DISK" || die "sgdisk failed clearing the partition table on $DISK"
else
    step "Creating $([[ $CREATE_ESP -eq 1 ]] && echo "EFI + ")swap + root partitions in the free space"
fi
if [[ $CREATE_ESP -eq 1 ]]; then
    sgdisk --new=0:0:+512MiB --typecode=0:ef00 --change-name=0:"EFI System" "$DISK" \
        || die "sgdisk failed creating the EFI System partition"
fi
sgdisk --new=0:0:+${SWAP_SIZE} --typecode=0:8200 --change-name=0:"Linux swap" "$DISK" \
    || die "sgdisk failed creating the swap partition"
sgdisk --new=0:0:0 --typecode=0:8300 --change-name=0:"Linux root" "$DISK" \
    || die "sgdisk failed creating the root partition"
partprobe "$DISK"
udevadm settle
sleep 2

if [[ $CREATE_ESP -eq 1 ]]; then
    mapfile -t NEW_PARTS < <(lsblk -lnpo NAME "$DISK" | grep -E "^${DISK}p?[0-9]+$" | sort -V | tail -n3)
    [[ ${#NEW_PARTS[@]} -eq 3 ]] || die "expected 3 new partitions, found ${#NEW_PARTS[@]} (${NEW_PARTS[*]:-none})"
    ESP="${NEW_PARTS[0]}"
    SWAP_PART="${NEW_PARTS[1]}"
    ROOT_PART="${NEW_PARTS[2]}"
    echo "    esp: $ESP   swap: $SWAP_PART   root: $ROOT_PART"
else
    mapfile -t NEW_PARTS < <(lsblk -lnpo NAME "$DISK" | grep -v "^${ESP}$" | grep -E "^${DISK}p?[0-9]+$" | sort -V | tail -n2)
    [[ ${#NEW_PARTS[@]} -eq 2 ]] || die "expected 2 new partitions, found ${#NEW_PARTS[@]} (${NEW_PARTS[*]:-none})"
    SWAP_PART="${NEW_PARTS[0]}"
    ROOT_PART="${NEW_PARTS[1]}"
    echo "    swap: $SWAP_PART   root: $ROOT_PART"
fi

step "Formatting"
mkswap "$SWAP_PART" || die "mkswap failed on $SWAP_PART"
mkfs.ext4 -F -L archroot "$ROOT_PART" || die "mkfs.ext4 failed on $ROOT_PART"
if [[ $CREATE_ESP -eq 1 ]]; then
    mkfs.fat -F32 -n EFI "$ESP" || die "mkfs.fat failed on $ESP"
fi

step "Mounting"
mount "$ROOT_PART" /mnt || die "failed to mount $ROOT_PART on /mnt"
mkdir -p /mnt/boot
mount "$ESP" /mnt/boot || die "failed to mount $ESP on /mnt/boot"
swapon "$SWAP_PART" || die "swapon failed on $SWAP_PART"

step "Installing base system (pacstrap) - this takes a while on this hardware"
OFFLINE_REPO_DIR="$SELF_DIR/offline-repo"
[[ -d "$OFFLINE_REPO_DIR" ]] || die "missing embedded offline repo at $OFFLINE_REPO_DIR - was this ISO built with the current build-iso.sh?"
OFFLINE_PACMAN_CONF=/root/pacman-offline.conf
cat > "$OFFLINE_PACMAN_CONF" <<EOF
[options]
Architecture = auto
SigLevel = Never
[oneshot-offline]
Server = file://${OFFLINE_REPO_DIR}
EOF
mapfile -t PKGS < <(grep -v '^\s*#' "$PACKAGES_FILE" | grep -v '^\s*$')
# yay and arc-gtk-theme aren't in packages.txt (both AUR, not official) -
# build-iso.sh builds them separately and drops them into the same offline
# repo, so they're always available here regardless of runtime network.
pacstrap -K -C "$OFFLINE_PACMAN_CONF" /mnt "${PKGS[@]}" yay arc-gtk-theme || die "pacstrap failed"

step "Generating fstab"
genfstab -U /mnt >> /mnt/etc/fstab

# pacstrap pulls in the `pacman-mirrorlist` package's stock file: every known
# mirror worldwide, in no particular order, none ranked by speed/distance.
# Left as-is, the first real pacman use on the installed system (AUR
# bootstrap, or anything you install later) ends up trying mirrors mostly
# sequentially and can look "hung" for a very long time on a slow/lossy
# connection. A couple of known-fast, GeoIP-aware mirrors is far more
# reliable than trying to rank the full list with reflector during install
# (reflector's own mirror-status fetch needs a good connection too - the
# exact thing we can't assume here). Re-run reflector yourself later for a
# fully tailored list once you're on solid network.
step "Setting a fast default mirrorlist for the installed system"
cat > /mnt/etc/pacman.d/mirrorlist <<'MIRRORLIST'
Server = https://geo.mirror.pkgbuild.com/$repo/os/$arch
Server = https://mirrors.kernel.org/archlinux/$repo/os/$arch
MIRRORLIST

# Needed below to hand-write refind_linux.conf with the correct root=. See
# the refind-install comment further down for why we can't trust its guess.
ROOT_UUID=$(blkid -s UUID -o value "$ROOT_PART")
[[ -n "$ROOT_UUID" ]] || die "could not read the UUID of $ROOT_PART after formatting"

# Propagate the live ISO's own SSH recovery key (baked in by build-iso.sh, if
# any) into the installed system, root's placed here so the chroot step below
# can also copy it into ${USERNAME}'s home from the same source.
SSH_KEY_INSTALLED=0
if [[ -s /root/.ssh/authorized_keys ]]; then
    install -d -m700 /mnt/root/.ssh
    install -m600 /root/.ssh/authorized_keys /mnt/root/.ssh/authorized_keys
    SSH_KEY_INSTALLED=1
fi

step "Configuring the installed system"
if ! arch-chroot /mnt /bin/bash -e <<CHROOT
set -e
ln -sf /usr/share/zoneinfo/${TIMEZONE} /etc/localtime
hwclock --systohc
sed -i 's/^#${LOCALE}/${LOCALE}/' /etc/locale.gen
locale-gen
echo "LANG=${LOCALE}" > /etc/locale.conf
echo "${HOSTNAME}" > /etc/hostname
cat > /etc/hosts <<HOSTS
127.0.0.1   localhost
::1         localhost
127.0.1.1   ${HOSTNAME}.localdomain ${HOSTNAME}
HOSTS

echo "root:${ROOT_PLACEHOLDER_PW}" | chpasswd
chage -d 0 root

useradd -m -G wheel -s /bin/bash ${USERNAME}
echo "${USERNAME}:${USER_PLACEHOLDER_PW}" | chpasswd
chage -d 0 ${USERNAME}

# Passwordless sudo for wheel ONLY for the rest of this install (AUR builds
# need it); replaced with normal password-required sudo at the very end.
echo "%wheel ALL=(ALL:ALL) NOPASSWD: ALL" > /etc/sudoers.d/10-wheel-install
chmod 440 /etc/sudoers.d/10-wheel-install

systemctl enable NetworkManager
systemctl enable lightdm

echo "exec startxfce4" > /home/${USERNAME}/.xinitrc
chown ${USERNAME}:${USERNAME} /home/${USERNAME}/.xinitrc
mkdir -p /etc/lightdm/lightdm.conf.d
echo "[Seat:*]" > /etc/lightdm/lightdm.conf.d/50-oneshot.conf
echo "user-session=xfce" >> /etc/lightdm/lightdm.conf.d/50-oneshot.conf

# lightdm-gtk-greeter's default look is bare Adwaita with no icon theme
# set - give it the theme+icons already pulled in by packages.txt instead.
cat > /etc/lightdm/lightdm-gtk-greeter.conf <<'GREETER'
[greeter]
theme-name = Arc-Dark
icon-theme-name = Papirus-Dark
font-name = Sans 10
background = #2b2b2b
indicators = ~host;~spacer;~clock;~spacer;~session;~power
GREETER

refind-install || echo "WARNING: refind-install reported an error - check ${LOG} and install it manually after first boot"

# rEFInd finds other OSes by scanning partitions for known bootloader files
# (e.g. macOS's /System/Library/CoreServices/boot.efi) - but it ships with
# no built-in filesystem support of its own, so it can't even read an
# HFS+/APFS volume's directory structure unless a matching filesystem
# driver is dropped into its own drivers_x64 dir. refind-install only
# copies one automatically when it detects it's running natively on Apple
# hardware (via dmidecode), which isn't reliable from inside arch-chroot
# during install. Copy it explicitly so a macOS dual-boot entry actually
# shows up. (APFS has no rEFInd driver at all as of this writing - this
# only helps HFS+-formatted macOS installs.)
mkdir -p /boot/EFI/refind/drivers_x64
cp /usr/share/refind/drivers_x64/hfs_x64.efi /boot/EFI/refind/drivers_x64/ 2>/dev/null \
    || echo "WARNING: could not copy rEFInd's hfs_x64.efi driver - a macOS dual-boot entry may not appear. See ${LOG}."

# refind-install tries to auto-generate /boot/refind_linux.conf by reading
# the CURRENTLY RUNNING system's boot options - but "currently running"
# here means the live ISO (we're inside arch-chroot, not a real boot of
# this disk), so its guess points root= at the live medium, not this
# install. Overwrite it with the real root partition's UUID so switch-root
# on first boot actually finds this disk instead of failing into emergency
# mode looking for the live ISO's own root.
cat > /boot/refind_linux.conf <<REFIND
"Boot with standard options"  "root=UUID=${ROOT_UUID} rw quiet"
"Boot to single-user mode"    "root=UUID=${ROOT_UUID} rw single"
"Boot to terminal"            "root=UUID=${ROOT_UUID} rw systemd.unit=multi-user.target"
REFIND

# Only enable sshd on the installed system when we have a recovery key to
# lock it to - otherwise it'd come up with Arch's stock sshd_config (password
# auth on) and expose the well-known placeholder passwords over the network
# until the forced first-login change happens, for no offsetting benefit.
if [[ -f /root/.ssh/authorized_keys ]]; then
    mkdir -p /home/${USERNAME}/.ssh
    cp /root/.ssh/authorized_keys /home/${USERNAME}/.ssh/authorized_keys
    chmod 700 /home/${USERNAME}/.ssh
    chmod 600 /home/${USERNAME}/.ssh/authorized_keys
    chown -R ${USERNAME}:${USERNAME} /home/${USERNAME}/.ssh

    cat > /etc/ssh/sshd_config.d/10-oneshot-recovery.conf <<'SSHD'
PasswordAuthentication no
PermitRootLogin prohibit-password
SSHD

    systemctl enable sshd
fi
CHROOT
then
    die "chroot base configuration failed"
fi

if [[ $NET_OK -eq 1 ]]; then
    step "Installing best-effort AUR packages (VS Code, Broadcom wifi driver) via yay"
    mapfile -t AUR_PKGS < <(grep -v '^\s*#' "$AUR_PACKAGES_FILE" | grep -v '^\s*$')
    for pkg in "${AUR_PKGS[@]}"; do
        arch-chroot /mnt runuser -u "${USERNAME}" -- yay -S --noconfirm --removemake "$pkg" \
            || echo "WARNING: AUR package '$pkg' failed to install - continuing. See ${LOG}."
    done
else
    step "Skipping AUR extras (VS Code, Broadcom wifi driver) - no network"
    echo "    yay is already installed - once online, run: yay -S visual-studio-code-bin broadcom-wl-dkms"
fi

step "Locking down sudo (password required from here on)"
arch-chroot /mnt bash -c '
    echo "%wheel ALL=(ALL:ALL) ALL" > /etc/sudoers.d/10-wheel
    rm -f /etc/sudoers.d/10-wheel-install
'

step "Copying install log into the new system"
cp "$LOG" /mnt/var/log/arch-oneshot-install.log || true

step "Unmounting and rebooting"
swapoff "$SWAP_PART" || true
umount -R /mnt

cat <<DONE

############################################################
# Install finished. Remove the USB stick, then press enter
# to reboot into the new system.
#
#   root password: ${ROOT_PLACEHOLDER_PW}      (must change at first login)
#   ${USERNAME} password:  ${USER_PLACEHOLDER_PW}      (must change at first login)
#
$(if [[ $SSH_KEY_INSTALLED -eq 1 ]]; then
cat <<SSHNOTE
# SSH recovery access is enabled (key-only, password auth disabled):
#   ssh root@<this-machine-ip>
#   ssh ${USERNAME}@<this-machine-ip>
# Find the IP with: ip -4 -br addr
#
SSHNOTE
fi)# Known rough edges to expect (see README.md):
#   - Wifi/Bluetooth may not work depending on whether the AUR
#     broadcom-wl-dkms build above succeeded (check
#     /var/log/arch-oneshot-install.log).
#   - Trackpad gestures beyond basic pointer/click may need tuning.
############################################################
DONE
read -r -t 30 _ || true
reboot
