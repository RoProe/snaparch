# Fixes to implement

- module-setup.sh: stty/dmesg/date missing in initramfs
- Snapshot rollback design (read-only snapshots + `subvol=@` pinned in cmdline and fstab):
  - boot menu: boot snapshot via overlayfs (temporary, for testing)
  - permanent rollback: replace @ (mv @ @broken, writable snapshot → @), see AUR snapper-rollback
  - `snapper rollback` / `btrfs subvolume set-default` currently have no effect → change
- Locale-List may still include comment strings;
- Menu-Timer starts before pre_menu
- swapoff before umount missing; chsh runs also without zsh

# Outlook

- add a conf file, --config and shared validation. The .env list should be removed
- The install-process should be .conf driven
- post-install.sh should also be static and conf-driven
- Back-Navigation should be possible in tui
- no --noconfirm when touching AUR
- README needs update after conf update
