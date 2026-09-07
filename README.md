# arch-oneshot-installer

Unattended, one-shot Arch Linux installer for **any UEFI x86_64 machine**.
Insert the USB, boot from it, walk away — it picks a disk mode automatically
(see "Dual-boot vs. clean disk" below), installs Arch + XFCE (X11) + rEFInd,
creates a regular user, and reboots into a working desktop. **The base
install needs no network at all** — every package it needs is embedded in
the ISO itself.

Originally built for (and validated on) a 2011 MacBook Air, dual-booting
alongside macOS. The disk-handling and boot setup are hardware-generic and
have been used successfully in "clean disk" mode; the package list/desktop
choices below are still the ones that machine needed — see
[Roadmap](#roadmap--todo) for making those configurable per machine instead
of fixed.

**Not yet run end-to-end on hardware other than that MacBook Air.** Review
`install/install-arch.sh` before you boot it on a machine you care about.
Every destructive step is gated behind read-only checks that abort loudly
(see "Safety model" below) if anything looks off, but read it anyway.

## How it works

1. `build-iso.sh` takes the official Arch `releng` archiso profile, resolves
   the full dependency closure of `install/packages.txt` (on your machine,
   where there's network), and embeds it as a local pacman repo inside the
   ISO at `/root/offline-repo`. It then drops `install/install-arch.sh` in
   at `airootfs/root/.automated_script.sh`. Arch's live environment
   autologins root on tty1, and its `.zlogin` unconditionally runs
   `~/.automated_script.sh` if present — this is a real, current convention
   in the `archlinux/archiso` releng profile, not a hack. That's the entire
   "runs the moment the prompt lands" mechanism.
2. `write-usb.sh` dd's the resulting ISO to a USB stick. Because the target
   system's packages now travel inside the ISO, expect a multi-gigabyte
   image (roughly 3-5GB depending on `install/packages.txt`) — use an 8GB+
   stick, ideally 16GB.
3. Boot the target machine from the stick (on a Mac: hold Option/Alt at
   power-on, pick the yellow "EFI Boot" icon; on a generic PC: use its
   firmware's one-time boot-device menu). The install starts automatically,
   entirely offline — no Ethernet, no wifi setup, nothing to plug in.

## Usage

```bash
./build-iso.sh          # builds build/out/arch-oneshot*.iso (downloads packages - takes a while)
./write-usb.sh          # writes it to a USB stick (interactive, asks first)
```

Then boot the target machine from the USB stick and walk away. Network is
entirely optional (see below) — nothing needs to be plugged in.

## Dual-boot vs. clean disk

The installer picks its mode automatically from the disk's current state —
it never prompts and never guesses when the state is ambiguous:

- **Dual-boot**: the disk has an EFI System Partition + an HFS+/APFS
  partition (i.e. it looks like a Mac with macOS already on it). Installs
  Arch into its free space, reuses the existing ESP. **Never touches the
  existing EFI System Partition's contents or any existing macOS
  partition** — the ESP is mounted read-write only to add Arch's boot
  files, never reformatted.
- **Clean disk**: the disk has zero partitions on it (completely blank).
  Wipes it (there's nothing to lose) and uses the entire disk: a new 512MiB
  EFI System Partition, swap, and an ext4 root partition.

Anything else — a disk with partitions that match neither shape (an
existing Windows/Linux install, or a Mac disk missing its ESP), zero
matching disks, or more than one match across both shapes — is **not**
guessed at. Instead every disk on the system is listed (device, size,
current contents) and the install pauses for you to type the number of the
disk to use, then whether to wipe it entirely or install alongside what's
already on it. If you pick "alongside" on a disk with no existing ESP, a
new 512MiB one is created in the free space alongside swap + root; if it
already has one (e.g. a non-Mac EFI install), that's reused instead. This
is the only interactive step in the whole install — everything else still
runs unattended once you've answered it.

## What it does

- Briefly checks for network (a few seconds, non-blocking either way - see
  "Network is optional" below).
- Finds the target disk per "Dual-boot vs. clean disk" above.
- **Dual-boot**: requires at least 15GiB of free space next to the existing
  partitions. Aborts if there isn't enough, or if the free space is
  ambiguous. Creates a swap partition (4G) and an ext4 root partition in
  that free space.
- **Clean disk**: requires the disk to be at least ~15.5GiB. Creates a new
  EFI System Partition (512MiB), swap partition (4G), and ext4 root
  partition, using the whole disk.
- Installs base Arch + XFCE (X11, not Wayland — see rationale below) +
  LightDM (themed — see below) + Firefox + rEFInd + `yay`, via
  `install/packages.txt` — entirely from the offline repo embedded in the
  ISO, no network needed. (Package list is currently fixed, not asked
  about — see [Roadmap](#roadmap--todo).)
- Sets hostname `arch-oneshot`, creates `root` and a regular user `dev`,
  both with placeholder passwords forced to change at first login:
  - `root` / `changeme-root`
  - `dev` / `changeme-dev`
- **Only if network is available:** best-effort (non-fatal if it fails)
  installs `install/aur-packages.txt` via `yay` — currently just
  `visual-studio-code-bin`. Failures here are logged to
  `/var/log/arch-oneshot-install.log` on the installed system; the install
  still finishes and reboots either way. With no network, this is skipped
  outright (not attempted, not a failure) — `yay` itself is already
  installed either way (see below), so once you have network just run
  `yay -S visual-studio-code-bin` yourself.
- Installs `rEFInd` into the ESP so the boot picker shows both the existing
  OS (if dual-booting) and Arch.
- Reboots. Remove the USB stick when prompted.

## Network is optional

The base install (partitioning through a working XFCE desktop) never
touches the network — everything it needs is embedded in the ISO. Wifi
isn't configured at all during install (no credentials are baked in, so an
unconfigured `iwd` will never associate with anything on its own); wired
Ethernet, if plugged in, is used opportunistically for two things only:

- the AUR extras (VS Code) described above
- [SSH recovery access](#remote-recovery-over-ssh), if something goes wrong

Neither is required to end up with a working system. If you plug in wired
Ethernet, both come free; if you don't, you get the same desktop minus VS
Code, installable later with `pacman`/`yay` once you're online by whatever
means.

Separately: `pacstrap` pulls in the stock `pacman-mirrorlist` package,
which is every known mirror worldwide in no particular order — not ranked
by speed or distance. The installer overwrites it with a couple of known
fast, GeoIP-aware mirrors (`geo.mirror.pkgbuild.com` +
`mirrors.kernel.org`) so the *first* real `pacman`/`yay` use on the
installed system isn't stuck crawling through slow or dead mirrors one by
one. This happens unconditionally (it's just writing a file, no network
needed) — run `reflector` yourself later for a list tailored to your
actual location once you're on solid network.

## Remote recovery over SSH

`build-iso.sh` bakes your public key (default `~/.ssh/id_ed25519.pub`, override
with `SSH_PUBKEY=/path/to/key.pub ./build-iso.sh`) into the live ISO's
`/root/.ssh/authorized_keys`. sshd is already enabled by default in the
releng profile, so as soon as the live medium is up and has network, you can:

```
ssh root@<the-machine's-ip>      # find it on the console with `ip -4 -br addr`
```

This is a lifeline if the automated install stalls or `die()`s on something
unanticipated and you have wired Ethernet plugged in — you can log in and
look around instead of only having the console. It's optional: the base
install doesn't need network or SSH to succeed, this is purely a debugging
aid for when something unexpected happens. If no key is found at build
time, this is skipped and only the console is available (safe default: live
root has an empty password and `PermitEmptyPasswords` isn't set, so no
unauthenticated remote login is ever possible either way).

The installer carries the same key forward into the installed system's
`root` and `dev` accounts, and **only enables `sshd` there at all if a key
was actually baked in** — with it locked to `PasswordAuthentication no` /
`PermitRootLogin prohibit-password`, so it never accepts the well-known
placeholder passwords over the network. With no key, sshd stays disabled on
the finished desktop (enable it yourself later if you want it). `openssh` is
still pulled in either way by `install/packages.txt` since it's a normal
thing to want on a dev workstation regardless of this feature.

## yay is built into the offline repo

`yay` (the AUR helper) isn't in Arch's official repos, so it can't be
pulled into the offline repo the same way as everything else in
`packages.txt` (`pacman -Syw` only resolves official packages — that's why
it isn't listed there). Instead, `build-iso.sh` builds `yay-bin` (prebuilt
binary, no Go toolchain needed) from AUR on your machine at ISO-build
time, where there's real network, and drops the resulting package into the
same offline repo; `install-arch.sh` appends it explicitly to its
`pacstrap` call. This means `yay` is **always** present on the installed
system regardless of network state at install time — only the AUR
packages you'd actually build *with* it afterwards (currently just VS
Code) stay best-effort/network-gated, since those genuinely need to be
fetched at install time. Add more AUR-only packages the same way by
appending to `AUR_BUILD_PKGS` in `build-iso.sh` — but prefer an
official-repo alternative when one exists (see below: this was tried for
the theme package and dropped for exactly that reason).

## Login screen theme

`lightdm-gtk-greeter`'s default look is bare, unthemed Adwaita.
`packages.txt` now includes `materia-gtk-theme` and `papirus-icon-theme`
(both official — no AUR needed), and `install-arch.sh` writes
`/etc/lightdm/lightdm-gtk-greeter.conf` to use them (Materia-dark theme,
matching icons, a plain dark background color — no image asset shipped, to
keep the repo text-only). This only themes the greeter itself; the XFCE
session you log into still uses its own defaults, though the same
theme/icon packages are available if you want to set them there too
(`xfce4-appearance-settings` after first login).

(`arc-gtk-theme` was tried here first, built from AUR the same way as
`yay` — but its upstream release tarball is missing git-submodule content
its `meson` build needs, a problem in that package itself, unrelated to
anything here. `materia-gtk-theme` is a well-maintained equivalent
available directly in the official repos, so it was used instead rather
than fighting a broken AUR package.)

## rEFInd boot configuration

`install/install-arch.sh` hand-writes `/boot/refind_linux.conf` with the
installed root partition's real UUID right after `refind-install` runs.
This is deliberate, not redundant: `refind-install`'s own auto-generated
config is built by inspecting the *currently running* system's boot
options, and since it runs inside `arch-chroot` during the install, "currently
running" means the **live ISO**, not the disk being installed to. Left
alone, that produces a `root=` pointing at the live medium instead of the
new install, which fails at `initrd-switch-root.service` on first real boot
(the disk never gets found, and you land in a bare emergency shell that
also refuses a password since the real root — where root's password
lives — was never switched to). Overwriting it with the correct UUID after
`refind-install` runs fixes this.

It also copies rEFInd's `hfs_x64.efi` filesystem driver into
`/boot/EFI/refind/drivers_x64/`. rEFInd finds other OSes by scanning
partitions for known bootloader files (macOS's
`/System/Library/CoreServices/boot.efi`), but it ships with no built-in
filesystem support — without this driver it can't read an HFS+ volume's
directory structure at all, so a dual-booted macOS install silently never
shows up in the boot menu even though everything else about the dual-boot
setup is correct. `refind-install` only copies this automatically when it
detects real Apple hardware via `dmidecode`, which isn't reliable from
inside `arch-chroot`. Note this only covers **HFS+**; rEFInd has no APFS
driver at all as of this writing, so a modern APFS-formatted macOS won't
be discoverable this way regardless.

## Wifi reliability

On the original MacBook Air's Broadcom BCM43224, the in-kernel `brcmsmac`
driver was found (on real hardware, via `/proc/net/wireless`) to drop a
huge number of packets — over 200,000 "misc" discards — despite an
excellent -38dBm signal. That's a known symptom of `brcmsmac`'s
power-management implementation on this chip family, not a range/signal
problem. There is **no working driver-package fix**: the proprietary
`broadcom-wl` (`wl.ko`) was already dropped from Arch's official repos for
not supporting current kernels, and its AUR `broadcom-wl-dkms` wrapper —
what earlier versions of this README/`aur-packages.txt` pointed at — no
longer exists on the AUR at all (confirmed via the AUR RPC search API).

The actual fix `install-arch.sh` applies, for every install regardless of
hardware: disable wifi power-save entirely, via
`/etc/NetworkManager/conf.d/wifi-powersave-off.conf` (`wifi.powersave =
2`). This is a documented ArchWiki-level fix for exactly this class of
symptom on older Broadcom chips, not something invented for this project,
and it's harmless on hardware that doesn't need it. If wifi is still
unreliable after this on your machine, a USB wifi adapter is a real,
confirmed-working fallback — the same real-hardware test that found the
`brcmsmac` packet loss also confirmed a USB adapter had none of it.

## Known rough edges on the original target hardware (2011 MacBook Air)

These are specific to the machine this was first built for, not this
project generically — see [Roadmap](#roadmap--todo) for making
hardware/driver choices ask instead of assume:

- **Wifi**: see "Wifi reliability" below — this isn't a simple missing
  driver, and there's no working package fix as of this writing.
- **Trackpad**: basic pointer/click works via the in-kernel driver +
  libinput out of the box. Multi-touch gestures are not tuned; expect to
  hand-tweak `libinput` config if you want them.
- **Graphics**: Intel HD 3000 via `xf86-video-intel` + Mesa — 2D/desktop
  use is fine, don't expect GPU-accelerated anything demanding. This
  package choice is currently baked into `install/packages.txt` for every
  machine this installs on, regardless of actual GPU — see Roadmap.

## Why XFCE-on-X11 and not Wayland (for now)

XFCE's compositor (`xfwm4`) is X11-only; there's no first-party Wayland
session. A Wayland session would mean bolting XFCE's panel onto a
different compositor (`labwc`) — more moving parts, less tested, and no
real benefit on GPUs (like the original target's Intel HD 3000) that don't
accelerate Wayland's compositing path well anyway. Plain XFCE-on-X11 is the
well-trodden, fast default. This is a fixed choice today, not yet asked
per-install — see Roadmap.

## Roadmap / TODO

This started as a MacBook-Air-specific installer and is being generalized.
Already hardware-generic: the disk-detection/partitioning logic (dual-boot
vs. clean-disk vs. interactive picker), the offline package repo mechanism,
rEFInd + `refind_linux.conf` handling, and SSH recovery. Still fixed rather
than asked, planned to become interactive prompts (mirroring the disk-picker
pattern — auto-detect and use a sensible default, only prompt when it
can't):

- **Graphics card** — detect (or ask) and install the matching driver
  package (`xf86-video-intel`/`xf86-video-amdgpu`/`nvidia`/etc.) instead of
  always assuming Intel.
- **CPU architecture** — currently x86_64 only; ask/detect for other
  architectures archiso supports.
- **Desktop environment** — currently always XFCE-on-X11; offer a choice
  (GNOME, KDE Plasma, a Wayland compositor, or none/CLI-only).
- **Extra drivers** — a general hook for hardware-specific extras (wifi,
  Bluetooth, touchpad quirks) beyond the current hardcoded
  `aur-packages.txt`.
- **Mac-specific dual-boot detection** — the current auto-detect (EFI +
  HFS+/APFS ⇒ dual-boot with macOS) is the one genuinely Mac-only piece of
  logic left. Leaving as-is for now; the interactive disk picker already
  covers every other dual-boot shape as a fallback, so this isn't blocking
  use on non-Mac hardware today.

## Safety model

`install/install-arch.sh` does every disk-identification and free-space
check **before** the first destructive command runs. If a check fails, it
prints why and exits — control returns to the normal live root shell,
nothing on disk is touched. Re-run it with `/root/.automated_script.sh`
after fixing whatever it complained about.

The one deliberate exception: if it can't auto-detect a single target disk
(see "Dual-boot vs. clean disk"), it doesn't abort — it lists every disk on
the system and asks you to pick one and a mode, interactively. This is the
only prompt in the entire install.

It also refuses to run a second time on a disk that already has an
ext4 or swap partition on it (i.e. Arch already got installed there).

## Customizing

- `install/packages.txt` — pacstrap package list. Language runtimes
  (Python/Go/Node/JDK/Rust/Docker) are deliberately not included since the
  stack wasn't specified beyond "backend dev, VS Code, build tools,
  browser" — `base-devel` covers the core build toolchain; add what you
  need with `pacman` after first boot.
- `install/aur-packages.txt` — best-effort AUR packages built during
  install, only attempted if network is available.
- Hostname, usernames, placeholder passwords, swap size, and minimum
  free-space threshold are all constants at the top of
  `install/install-arch.sh`.
- `build/pkgcache/` — the downloaded package cache used to build the
  embedded offline repo. It persists across builds (not wiped by
  `build-iso.sh`) so re-running the build only re-downloads what changed.
  Delete it yourself for a fully clean re-fetch.
- `build/aur-build/` — scratch clone/build dir for the AUR-only packages
  (see "AUR-only packages are built into the offline repo"). Wiped and
  rebuilt on every run of `build-iso.sh`, unlike `pkgcache/`.

## License

[MIT](LICENSE)
