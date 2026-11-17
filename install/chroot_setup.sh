#!/usr/bin/env bash
# chroot_setup.sh runs via arch-chroot in new system and gets variables passed by install.sh
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'
info() { echo -e "${CYAN}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[OK]${NC}   $*"; }
WARNINGS=()
warn() {
  echo -e "${YELLOW}[WARN]${NC} $*"
  WARNINGS+=("$*")
}
die() {
  echo -e "${RED}[ERROR]${NC} $*"
  exit 1
}

# --- sanity check - ensure required vars were passed
: "${USERNAME:?}" "${HOSTNAME:?}" "${TIMEZONE:?}" "${LOCALE:?}" "${KEYMAP:?}"
: "${LUKS_UUID:?}" "${GPU_CHOICE:?}" "${ALL_PKGS:?}" "${AUR_HELPER:-}" "${WEBAPPS:-}"
: "${ENABLE_AUTOLOGIN:?}" "${ENABLE_SWAP:?}" "${ENABLE_SECUREBOOT:?}" "${MICROSOFT_CA:?}"
: "${ENABLE_LTS:?}" "${PKGS_AUR:-}" "${DISK:?}" "${CONFIGURE_DOTFILES:?}"
: "${LUKS_NAME:?}" "${RESUME_ARGS?}"

# --- Helper var for the static files
# copies file from repo to target system
# usage: put <mode> <path relative to />
FILES=/root/snaparch-files
put() {
  (($# == 2)) || die "put: expected 2 args, got $#: $*"
  install -Dm"$1" "${FILES}/$2" "/$2"
}

# --- passwords
echo "Set ROOT password:"
passwd < /dev/tty

# --- timezone & clock
ln -sf /usr/share/zoneinfo/"${TIMEZONE}" /etc/localtime
hwclock --systohc

# --- locale
sed -i "s/^#${LOCALE}/${LOCALE}/" /etc/locale.gen
locale-gen
echo "LANG=${LOCALE}" > /etc/locale.conf

# --- vconsole
printf 'KEYMAP=%s\n' "$KEYMAP" > /etc/vconsole.conf

# --- hostname
echo "${HOSTNAME}" > /etc/hostname

# --- user
useradd -m -G wheel "${USERNAME}"
echo "Set password for ${USERNAME}:"
passwd "${USERNAME}" < /dev/tty
sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers

# --- autologin (optional)
if [[ "$ENABLE_AUTOLOGIN" == true ]]; then
  info "Configuring autologin..."
  mkdir -p /etc/systemd/system/getty@tty1.service.d
  cat > /etc/systemd/system/getty@tty1.service.d/autologin.conf << EOF
[Service]
ExecStart=
ExecStart=-/sbin/agetty -a ${USERNAME} --noclear %I \$TERM
EOF
fi

# --- install user packages
info "Installing selected packages..."
read -ra PKG_ARRAY <<< "$ALL_PKGS"
pacman -S --noconfirm --needed "${PKG_ARRAY[@]}"

# --- activate services
systemctl enable --no-reload bluetooth || warn "bluetooth not available"
systemctl enable --no-reload ufw || warn "ufw not available"
systemctl enable --no-reload power-profiles-daemon || warn "power-profiles-daemon not available"
systemctl enable --no-reload "syncthing@${USERNAME}.service" || warn "syncthing not available"
systemctl enable --no-reload NetworkManager || die "NetworkManager can't be activate"
systemctl enable --no-reload fstrim.timer || die "fstrim.timer can't be activated"

# --- hibernate config (suspend-to-disk via swapfile)
if [[ "$ENABLE_SWAP" == true ]]; then
  info "Configuring hibernate..."

  # Override systemd sleep defaults to always hibernate
  # on closing the lid or running 'systemctl hibernate' writes RAM to the encrypted swapfile and powers off.
  # Reason: Luks-Key is kept in RAM if we use Suspend-to-RAM. We don't want that.
  # TODO: offer suspend-then-hibernate as installer option (SLEEP_MODE)
  put 644 etc/systemd/sleep.conf.d/hibernate.conf

  # hibernate on lid close
  put 644 etc/systemd/logind.conf.d/lid.conf

  # Allow wheel users to hibernate without sudo password via polkit
  put 644 etc/polkit-1/rules.d/10-hibernate.rules
  success "Hibernate configured. Use: systemctl hibernate"
fi

# --- dracut hook scripts
# depending on active pkgbase chooses correct outfile in dracut-install or file to remove in dracut-remove.sh
put 755 usr/local/bin/dracut-install.sh

put 755 usr/local/bin/dracut-remove.sh

# --- pacman hooks for dracut
put 644 etc/pacman.d/hooks/90-dracut-install.hook

put 644 etc/pacman.d/hooks/60-dracut-remove.hook

# --- dracut config
mkdir -p /etc/dracut.conf.d

cat > /etc/dracut.conf.d/cmdline.conf << EOF
kernel_cmdline="rd.luks.name=${LUKS_UUID}=cryptroot root=/dev/mapper/cryptroot rootfstype=btrfs rootflags=rw,noatime,compress=zstd,subvol=@${RESUME_ARGS}"
EOF

put 644 etc/dracut.conf.d/flags.conf

# --- Nvidia (open, hybrid and legacy)
if [[ $GPU_CHOICE == nvidia* || $GPU_CHOICE == hybrid-nvidia* ]]; then
  put 644 etc/dracut.conf.d/nvidia.conf
  put 644 etc/modprobe.d/nvidia.conf
  put 644 etc/pacman.d/hooks/95-nvidia-dracut.hook

  # Wayland requires DRM modesetting - fbdev needed for early KMS
  sed -i 's/"$/ nvidia_drm.modeset=1 nvidia_drm.fbdev=1"/' /etc/dracut.conf.d/cmdline.conf
fi

# --- snapper

put 644 etc/snapper/configs/root

put 644 etc/conf.d/snapper

chmod 750 /.snapshots
chown :wheel /.snapshots

pacman -S --noconfirm snap-pac

systemctl enable --no-reload snapper-timeline.timer snapper-cleanup.timer

# --- Secure Boot
if [[ "$ENABLE_SECUREBOOT" == true ]]; then
  pacman -S --noconfirm sbctl
  sbctl create-keys

  put 644 etc/dracut.conf.d/secureboot.conf

  put 644 etc/pacman.d/hooks/zz-sbctl.hook

  # hook for lts
  if [[ "$ENABLE_LTS" == true ]]; then
    put 644 etc/pacman.d/hooks/zz-sbctl-lts.hook
  fi
fi

# --- generate UKI (triggers dracut hook)
# reinstalls the linux package which fires 90-dracut-install.hook,
# calling dracut-install.sh, and running dracut --uefi to produce bootx64.efi
pacman -S --noconfirm linux

if [[ "$ENABLE_LTS" == true ]]; then
  pacman -S --noconfirm linux-lts
fi

# Initial sign - must happen after UKI exists, before reboot
if [[ "$ENABLE_SECUREBOOT" == true ]]; then
  sbctl sign -s /boot/efi/EFI/Linux/bootx64.efi
  if [[ "$ENABLE_LTS" == true ]]; then
    sbctl sign -s /boot/efi/EFI/Linux/bootx64-lts.efi
  fi
fi

if [[ "$ENABLE_LTS" == true ]]; then
  efibootmgr --create --disk "${DISK}" --part 1 --label "Arch Linux LTS" --loader '\EFI\Linux\bootx64-lts.efi'
fi
efibootmgr --create --disk "${DISK}" --part 1 --label "Arch Linux" --loader '\EFI\Linux\bootx64.efi'

# --- WebApps
if [[ -n "${WEBAPPS}" ]]; then
  DESKTOP_DIR="/home/${USERNAME}/.local/share/applications"
  mkdir -p "$DESKTOP_DIR"

  declare -A WEBAPP_URLS=(
    ["github"]="https://github.com"
    ["zoom"]="https://app.zoom.us/wc"
    ["whatsapp"]="https://web.whatsapp.com"
    ["notion"]="https://notion.so"
    ["protonmail"]="https://mail.proton.me"
  )

  declare -A WEBAPP_NAMES=(
    ["github"]="GitHub"
    ["zoom"]="Zoom"
    ["whatsapp"]="WhatsApp"
    ["notion"]="Notion"
    ["protonmail"]="Proton Mail"
  )

  declare -A WEBAPP_CATEGORIES=(
    ["github"]="Development;"
    ["zoom"]="Network;VideoConference;"
    ["whatsapp"]="Network;InstantMessaging;"
    ["notion"]="Office;"
    ["protonmail"]="Network;Email;"
  )

  for app in ${WEBAPPS}; do
    [[ -z "${WEBAPP_URLS[$app]:-}" ]] && continue
    PROFILE_DIR="/home/${USERNAME}/.mozilla/firefox/webapps/${app}"
    mkdir -p "$PROFILE_DIR"
    tee "${DESKTOP_DIR}/${app}-webapp.desktop" > /dev/null << EOF
[Desktop Entry]
Name=${WEBAPP_NAMES[$app]}
Exec=firefox --profile ${PROFILE_DIR} --new-window ${WEBAPP_URLS[$app]}
Icon=${app}
Type=Application
Categories=${WEBAPP_CATEGORIES[$app]}
StartupNotify=true
StartupWMClass=${WEBAPP_NAMES[$app]}
EOF
    chown -R "${USERNAME}":"${USERNAME}" "$PROFILE_DIR"
    chown "${USERNAME}":"${USERNAME}" "${DESKTOP_DIR}/${app}-webapp.desktop"
    success "WebApp created: ${WEBAPP_NAMES[$app]}"
  done
fi

# === Post Install Script and AUR setup

# --- base
cat > /home/"${USERNAME}"/post-install.sh << EOF
#!/usr/bin/env bash
set -euo pipefail
GREEN='\033[0;32m'; CYAN='\033[0;36m'; NC='\033[0m'
info()    { echo -e "\${CYAN}[INFO]\${NC} \$*"; }
success() { echo -e "\${GREEN}[OK]\${NC}   \$*"; }
EOF

# --- AUR (optional)
if [[ -n "${PKGS_AUR:-}" ]] && [[ -n "${AUR_HELPER:-}" ]]; then
  echo "${PKGS_AUR}" | tr ' ' '\n' | grep -v '^$' > /home/"${USERNAME}"/aur-packages.txt
  chown "${USERNAME}":"${USERNAME}" /home/"${USERNAME}"/aur-packages.txt

  cat >> /home/"${USERNAME}"/post-install.sh << EOF
info "Installing ${AUR_HELPER}..."
cd /tmp
git clone https://aur.archlinux.org/${AUR_HELPER}.git
cd ${AUR_HELPER}
makepkg -si --noconfirm
cd /tmp && rm -rf ${AUR_HELPER}

AUR_LIST="\$HOME/aur-packages.txt"
if [[ -f "\$AUR_LIST" && -s "\$AUR_LIST" ]]; then
  mapfile -t AUR_PKGS < "\$AUR_LIST"
  info "Installing AUR packages: \${AUR_PKGS[*]}"
  ${AUR_HELPER} -S --noconfirm "\${AUR_PKGS[@]}"
fi
EOF
fi

# --- Nvidia (optional)
if [[ "${GPU_CHOICE:-}" == nvidia* || "${GPU_CHOICE:-}" == hybrid-nvidia* ]]; then
  cat >> /home/"${USERNAME}"/post-install.sh << 'EOF'
info "Writing Hyprland nvidia env config..."
mkdir -p "$HOME/.config/hypr"
cat > "$HOME/.config/hypr/nvidia.conf" << 'HYPRCONF'
env = LIBVA_DRIVER_NAME,nvidia
env = __GLX_VENDOR_LIBRARY_NAME,nvidia
env = NVD_BACKEND,direct
env = WLR_NO_HARDWARE_CURSORS,1
HYPRCONF
echo ""
echo "  Add the following to ~/.config/hypr/hyprland.conf:"
echo "      source = ~/.config/hypr/nvidia.conf"
EOF
fi

# TODO: fetch dotfiles from repo, set up zsh with highlighting, fuzzyfind, basic rice, QOL features

# --- add summary and set zsh as default
cat >> /home/"${USERNAME}"/post-install.sh << 'EOF'
info "Setting zsh as default shell..."
chsh -s /bin/zsh

success "Post-install complete!"
echo ""
echo "Next steps:"
echo "  1. Restore dotfiles:   cd ~/dotfiles && stow *"
echo "  2. Restore NM VPN configs from Borg backup:"
echo "       sudo cp /path/*.nmconnection /etc/NetworkManager/system-connections/"
echo "       sudo chmod 600 /etc/NetworkManager/system-connections/*"
echo "       sudo systemctl restart NetworkManager"
EOF

# --- ownership and make executable
chown "${USERNAME}:${USERNAME}" /home/"${USERNAME}"/post-install.sh
chmod +x /home/"${USERNAME}"/post-install.sh
success "post-install.sh written to /home/${USERNAME}/"

# === Summary
echo ""
echo "╔══════════════════════════════════════════════════════════╗"
echo "║  Chroot setup complete!                                  ║"
echo "╠══════════════════════════════════════════════════════════╣"
echo "║  Exit chroot and run:                                    ║"
echo "║    swapoff /mnt/swap/swapfile                            ║"
echo "║    umount -R /mnt                                        ║"
echo "║    cryptsetup close ${LUKS_NAME}                        ║"
echo "║    reboot                                                ║"
echo "╠══════════════════════════════════════════════════════════╣"
if [[ "$ENABLE_SECUREBOOT" == true ]]; then
  echo "╠══════════════════════════════════════════════════════════╣"
  echo "║  After first boot — SecureBoot:                          ║"
  echo "║    1. Enable Setup Mode in BIOS                          ║"
  if [[ "$MICROSOFT_CA" == true ]]; then
    echo "║    2. sbctl enroll-keys --microsoft                      ║"
  else
    echo "║    2. sbctl enroll-keys                                  ║"
  fi
  echo "║    3. Reboot, enable UEFI Secure Boot, set BIOS password ║"
  echo "╠══════════════════════════════════════════════════════════╣"
fi
if [[ "$GPU_CHOICE" == nvidia* || "$GPU_CHOICE" == hybrid-nvidia* ]]; then
  echo "║    4. Add the following to ~/.config/hypr/hyprland.conf: ║"
  echo "║    -->     source = ~/.config/hypr/nvidia.conf           ║"
  echo "╠══════════════════════════════════════════════════════════╣"
fi
echo "║  Then log in as ${USERNAME} and run:                     ║"
echo "║    bash ~/post-install.sh                                ║"
echo "╚══════════════════════════════════════════════════════════╝"

if [[ ${#WARNINGS[@]} -gt 0 ]]; then
  echo ""
  echo "══════════════════════════════════════════════════════════"
  echo "  Warnings:"
  for w in "${WARNINGS[@]}"; do
    echo "  [WARN] $w"
  done
  echo "══════════════════════════════════════════════════════════"
fi
