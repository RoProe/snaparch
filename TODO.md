# Fixes to implement

- README is in an old state and needs an overhaul
- clean up env variables in chroot script and all following scripts
- Nvidia-Pacman-Hooks don't rebuild UKI (no NeedsTargets), needs a "rebuild all installed kernels" mode for package hooks
- module-setup.sh: stty/dmesg/date missing in initramfs
- Snapper-Snapshots are read-only -> Snapshot-Boot needs e.g. an Overlay
- Locale-List may still include comment strings;
- Menu-Timer starts before pre_menu
- swapoff before umount missing; chsh runs also without zsh

# Outlook

- heredocs should be their own files (esp. static ones)
- add a conf file, --config and shared validation. The .env list should be removed
- The install-process should be .conf driven
- post-install.sh should also be static and conf-driven
- Back-Navigation should be possible in tui
- no --noconfirm when touching AUR
