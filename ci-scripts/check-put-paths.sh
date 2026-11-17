#!/usr/bin/env bash
# checks that every 'put <mode> <path>' in chroot_setup.sh has a matching file in install/files/
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
[[ -f install/chroot_setup.sh ]] || {
  echo "install/chroot_setup.sh not found" >&2
  exit 1
}
rc=0
while read -r p; do
  if [[ ! -f install/files/$p ]]; then
    echo "missing: install/files/$p" >&2
    rc=1
  fi
done < <(grep -oP 'put \d+ \K\S+' install/chroot_setup.sh)
exit "$rc"
