#!/usr/bin/env bash
# Writes the custom ISO built by build-iso.sh onto a USB stick.
# Run on your Linux machine, with the target USB stick plugged in.
# This is interactive on purpose: writing the wrong device here destroys it.

set -euo pipefail

ISO="${1:-}"
if [[ -z "$ISO" ]]; then
    ISO=$(ls -1t "$(dirname "${BASH_SOURCE[0]}")"/build/out/*.iso 2>/dev/null | head -n1 || true)
fi
[[ -n "$ISO" && -f "$ISO" ]] || {
    echo "Usage: $0 [path-to-iso]"
    echo "No ISO found in build/out/ - run build-iso.sh first, or pass a path."
    exit 1
}

echo "ISO: $ISO"
echo
lsblk -dpno NAME,SIZE,MODEL,TRAN
echo
read -rp "Target USB device (e.g. /dev/sdb) - NOT a partition, NOT your main disk: " DEV
[[ -b "$DEV" ]] || { echo "no such block device: $DEV"; exit 1; }

echo
echo "About to OVERWRITE ALL DATA on $DEV with $ISO"
lsblk "$DEV"
read -rp "Type the device path again to confirm ($DEV): " CONFIRM
[[ "$CONFIRM" == "$DEV" ]] || { echo "confirmation did not match, aborting"; exit 1; }

sudo dd if="$ISO" of="$DEV" bs=4M status=progress oflag=sync
sudo sync
echo "Done. Safe to remove $DEV."
