#!/usr/bin/env bash
while read -r line; do
  if [[ "$line" == 'usr/lib/modules/'+([^/])'/pkgbase' ]]; then
    kver="${line#'usr/lib/modules/'}"
    kver="${kver%'/pkgbase'}"
    pkgbase=$(cat "/usr/lib/modules/${kver}/pkgbase")
    if [[ "$pkgbase" == "linux-lts" ]]; then
      rm -f /boot/efi/EFI/Linux/bootx64-lts.efi
    else
      rm -f /boot/efi/EFI/Linux/bootx64.efi
    fi
  fi
done
