#!/usr/bin/env bash
set -euo pipefail

build() {
  local kver=$1 pkgbase out
  pkgbase=$(< "/usr/lib/modules/${kver}/pkgbase")
  case $pkgbase in
    linux-lts) out=bootx64-lts.efi ;;
    *) out=bootx64.efi ;;
  esac
  mkdir -p /boot/efi/EFI/Linux
  dracut --force --uefi --kver "$kver" "/boot/efi/EFI/Linux/${out}" || {
    echo "ERROR: UKI build failed for $kver ($out)" >&2
    return 1
  }
}

rc=0

if [[ ${1:-} == --all ]]; then
  for f in /usr/lib/modules/*/pkgbase; do
    [[ -f $f ]] || continue # no match
    kver=${f#/usr/lib/modules/}
    kver=${kver%/pkgbase}
    build "$kver" || rc=1
  done
else
  while read -r line; do
    [[ $line == usr/lib/modules/+([^/])/pkgbase ]] || continue
    kver=${line#usr/lib/modules/}
    kver=${kver%/pkgbase}
    build "$kver" || rc=1
  done
fi

exit "$rc"
