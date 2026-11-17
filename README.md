# snaparch

## DISCLAIMER

This project is a work in progress - it's a hobby project to further my knowledge of Linux system administration and secure system configuration.
It has not been extensively tested yet.
Use at your own risk and test in a VM before deploying on real hardware.
Personal Arch Linux installation setup - LUKS2 full-disk encryption, Btrfs with automatic snapshots, post-LUKS initramfs snapshot menu, hibernate via encrypted swapfile, UKI, optional SecureBoot.

Inspired by [secure-arch](https://github.com/Ataraxxia/secure-arch) by Ataraxxia.

---

## TL;DR

```
bash install/install.sh          # TUI guides you through everything
# reboot
bash ~/post-install.sh   # installs AUR helper (paru/yay) + AUR packages + sets zsh
# if SecureBoot: enable Setup Mode in BIOS → sbctl enroll-keys (--microsoft if chosen) → reboot
```

## Boot flow

```
UEFI → UKI (kernel + initramfs + cmdline, optionally signed) → LUKS passphrase
     → resume from hibernate (if an image is present)
     → snapshot menu (5 s timeout, only shown if snapshots exist)
          [Enter / b]  →  normal boot (@)
          [s]          →  pick a Snapper snapshot (arrow keys or j/k)
```

## Features

- LUKS2 full-disk encryption (Argon2id; no GRUB, so no PBKDF2 limitation)
- Btrfs with `zstd` compression, Snapper timeline snapshots and pre/post snapshots on every pacman transaction (`snap-pac`)
- Snapshot menu in the initramfs, after LUKS unlock, before the root mount
- Hibernate to an encrypted swapfile; closing the lid hibernates instead of suspending
- UKIs built by dracut via pacman hooks, optional LTS fallback kernel
- Optional SecureBoot with your own keys (`sbctl`)
- GPU auto-detection (AMD / Intel / Nvidia / hybrid / Nvidia legacy)
- Optional autologin, webapps (Firefox profiles), AUR packages after first boot

**What the script does NOT do:** SecureBoot key enrollment (requires BIOS interaction), dotfiles

---

## Prerequisites

- UEFI system (no legacy BIOS), at least 20 GB disk and 512 MB RAM
- For SecureBoot: firmware that supports Setup Mode / custom keys, and SecureBoot disabled during install
- Internet on the live ISO (`iwctl` for WiFi)

---

## Installation

### 1. Boot the Arch ISO and connect to the internet

```bash
iwctl station wlan0 connect YOUR_SSID
ping -c 3 archlinux.org
```

### 2. Get the repository

The installer needs the whole repository (`install/files/`, the dracut module, `chroot_setup.sh`), not just one script.

```bash
curl -fsSL https://github.com/RoProe/snaparch/archive/refs/heads/main.tar.gz | tar xz
cd snaparch-main/install
```

### 3. Read it, then run it

```bash
less install.sh chroot_setup.sh
bash install.sh
```

The TUI asks for: target disk, CPU vendor (microcode), username, hostname, timezone, locale, console keymap,
EFI size (default 2048 MiB), LTS fallback kernel, swap + hibernate, autologin, SecureBoot, GPU driver,
package selection per category, webapps, AUR packages and AUR helper (paru or yay).

After the summary screen you enter the LUKS passphrase and, inside the chroot, the root and user passwords.
Everything else runs automatically.

### 4. Reboot

```bash
swapoff /mnt/swap/swapfile   # only if swap was enabled
umount -R /mnt
cryptsetup close cryptroot
reboot
```

### 5. SecureBoot (if enabled)

```bash
# in the BIOS: enable Setup Mode / clear the existing keys
sbctl enroll-keys              # add --microsoft only if you chose it (needed for Windows dual-boot)
# in the BIOS: enable SecureBoot, set a BIOS password
sbctl status
```

### 6. Post-install (as your user)

```bash
bash ~/post-install.sh
```

Installs the AUR helper and the selected AUR packages, writes `~/.config/hypr/nvidia.conf` for Nvidia, and sets zsh as the login shell.

---

## Design notes

### Disk layout

```
/dev/nvme0n1
├── p1  EFI    FAT32, unencrypted, holds the UKIs (EFI/Linux/bootx64.efi, bootx64-lts.efi)
└── p2  LUKS2
         └── Btrfs
              ├── @           →  /
              ├── @home       →  /home
              ├── @snapshots  →  /.snapshots
              ├── @var_log    →  /var/log
              └── @swap       →  /swap   (only with swap; holds the NOCOW swapfile)
```

- `@home`: rolling back the system doesn't touch your files.
- `@snapshots`: kept separate so snapshots don't contain themselves.
- `@var_log`: logs survive a rollback, so you can still see why something broke.
- `@swap`: copy-on-write must be off for the swapfile, otherwise `resume_offset` doesn't work.

**Why no GRUB?** GRUB has to unlock LUKS itself and doesn't support Argon2id. Here the firmware starts the UKI
and the initramfs unlocks LUKS, so the full Argon2id KDF can be used.

### Hibernate

The swapfile lives inside LUKS. `AllowSuspend=no` and `HibernateMode=shutdown` make the system always hibernate
and power off instead of suspending to RAM, because with suspend-to-RAM the LUKS key stays in memory.
Closing the lid hibernates. A polkit rule lets members of `wheel` hibernate without a password.

### Snapshot menu

A custom dracut module (`install/dracut/99snapshot-menu`) runs as a pre-mount hook. It reads Snapper's
`info.xml` files and shows the 20 newest snapshots. Selecting one rewrites the root mount options
(`snapshot-rewrite.service`) so that `@snapshots/N/snapshot` is mounted instead of `@`.

> Known limitation: Snapper snapshots are read-only, so booting into one doesn't work properly yet (see TODO.md).
> **Snapper quirk:** When you run `snapper create-config`, Snapper creates its own `.snapshots` subvolume. Since we already have `@snapshots` mounted at `/.snapshots`, this conflicts. The script deletes Snapper's auto-created subvolume and keeps the pre-existing mount. fstab should handle it correctly after reboot.

### UKIs and pacman hooks

`dracut-install.sh` builds one UKI per installed kernel (`linux` → `bootx64.efi`, `linux-lts` → `bootx64-lts.efi`),
triggered by pacman hooks on kernel install/upgrade and on Nvidia driver changes.
`dracut-remove.sh` deletes the UKI when a kernel is removed.

### GPU drivers

| Choice | Packages |
|---|---|
| AMD | `vulkan-radeon`, `mesa` |
| intel | `mesa`, `intel-media-driver` |
| nvidia | `nvidia-open-dkms`, `nvidia-utils`, `egl-wayland`, `lib32-nvidia-utils` |
| hybrid-nvidia-intel / -amd | Nvidia packages plus the iGPU packages |
| nvidia-legacy | `nvidia-580xx-dkms` & co. from the AUR, installed by `post-install.sh` |

For Nvidia the installer adds the modules to the initramfs and `nvidia_drm.modeset=1 nvidia_drm.fbdev=1`
to the kernel command line.

### SecureBoot

`sbctl` creates your own keys. dracut signs the UKI on every build with the sbctl database key.
Keys are enrolled manually after the first boot (see Installation, step 5).

### Autologin

A systemd drop-in for `getty@tty1`. The disk stays encrypted; autologin only skips the user password after the LUKS unlock.

---

### Restoring a snapshot

The kernel command line mounts `subvol=@` explicitly, so `snapper rollback` and `btrfs subvolume set-default`
have **no effect** with this setup. To restore, replace `@` with a writable copy of the snapshot,
e.g. from the live ISO. Rollback is planned but still WIP.

---

## Repository layout

```
install/
├── install.sh            # runs on the live ISO: TUI, partitioning, LUKS, Btrfs, pacstrap
├── chroot_setup.sh       # runs inside arch-chroot: system configuration, UKI, boot entries
├── files/                # static files, paths mirror the target system (etc/…, usr/…)
└── dracut/99snapshot-menu/   # the initramfs snapshot menu
ci-scripts/               # helper scripts used by pre-commit
```

## Development

All checks run through [pre-commit](https://pre-commit.com/), locally and in CI (`.github/workflows/lint.yml`):

```bash
sudo pacman -S --needed pre-commit shellcheck shfmt actionlint gitleaks zizmor
pre-commit install
pre-commit run --all-files
```

Releases are built from tags (`v*.*.*`) by `.github/workflows/release.yml`.

## License

GPL-3.0, see [LICENSE](LICENSE).
