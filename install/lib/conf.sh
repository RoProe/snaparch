# install/lib/conf.sh: config helpers, sourced by install.sh and chroot_setup.sh

# every key a conf must define
CONF_KEYS=(
  DISK CPU USERNAME TARGET_HOSTNAME TIMEZONE LOCALE KEYMAP EFI_SIZE
  ENABLE_LTS ENABLE_SWAP SWAP_SIZE_GIB ENABLE_AUTOLOGIN ENABLE_SECUREBOOT
  MICROSOFT_CA GPU_CHOICE PKGS PKGS_AUR AUR_HELPER WEBAPPS CONFIGURE_DOTFILES
)
CONF_CPU_CHOICES=(amd intel)
CONF_GPU_CHOICES=(amd intel nvidia hybrid-nvidia-intel hybrid-nvidia-amd nvidia-legacy none)
CONF_AUR_CHOICES=(yay paru)
CONF_WEBAPPS=(github zoom whatsapp notion protonmail)

_conf_err() { CONF_ERRORS+=("$*"); }

# --- HELPERS

# load_conf <file>: source a conf file into the global scope
load_conf() {
  [[ -f $1 && -r $1 ]] || return 1
  unset "${CONF_KEYS[@]}"
  # shellcheck source=../snaparch.conf.example
  source "$1"
}

# _conf_bool <name>: value must be exactly true or false
_conf_bool() {
  local name=$1
  [[ ${!name} == true || ${!name} == false ]] \
    || _conf_err "$name must be true or false (got '${!name}')"
}

# _conf_in <value> <allowed...>: true if value is one of the allowed
_conf_in() {
  local v=$1 a
  shift
  for a; do [[ $v == "$a" ]] && return 0; done
  return 1
}

# _conf_array <name>: variable must be an indexed array
_conf_array() {
  [[ $(declare -p "$1") == "declare -a"* ]] || _conf_err "$1 must be an array: $1=(...)"
}

# --- VALIDATION
# validate_conf: check all conf values, collect errors in CONF_ERRORS
# returns 0 if valid, 1 otherwise
validate_conf() {
  CONF_ERRORS=()
  local k
  for k in "${CONF_KEYS[@]}"; do
    declare -p "$k" &> /dev/null || _conf_err "missing key: $k"
  done
  # stop here, the checks below would hit unset vars
  ((${#CONF_ERRORS[@]} == 0)) || return 1

  [[ $USERNAME =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] \
    || _conf_err "USERNAME invalid: '$USERNAME'"

  [[ $TARGET_HOSTNAME =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$ ]] \
    || _conf_err "TARGET_HOSTNAME invalid: '$TARGET_HOSTNAME'"

  for k in ENABLE_LTS ENABLE_SWAP ENABLE_AUTOLOGIN ENABLE_SECUREBOOT MICROSOFT_CA CONFIGURE_DOTFILES; do
    _conf_bool "$k"
  done

  for k in PKGS PKGS_AUR WEBAPPS; do
    _conf_array "$k"
  done

  _conf_in "$CPU" "${CONF_CPU_CHOICES[@]}" || _conf_err "CPU invalid: '$CPU' (allowed: ${CONF_CPU_CHOICES[*]})"

  _conf_in "$GPU_CHOICE" "${CONF_GPU_CHOICES[@]}" || _conf_err "GPU_CHOICE invalid: '$GPU_CHOICE' (allowed: ${CONF_GPU_CHOICES[*]})"

  [[ -z $AUR_HELPER ]] || _conf_in "$AUR_HELPER" "${CONF_AUR_CHOICES[@]}" || _conf_err "AUR_HELPER invalid: '$AUR_HELPER' (allowed: ${CONF_AUR_CHOICES[*]} or empty)"

  for k in "${WEBAPPS[@]}"; do
    _conf_in "$k" "${CONF_WEBAPPS[@]}" || _conf_err "WEBAPP invalid: '$k' (allowed: ${CONF_WEBAPPS[*]})"
  done

  [[ $DISK == /dev/?* ]] || _conf_err "DISK must be a device path like /dev/sda (got '$DISK')"

  local efi_mib
  if [[ $EFI_SIZE =~ ^([0-9]{1,6})(MiB|GiB)$ ]]; then
    efi_mib=$((10#${BASH_REMATCH[1]}))
    if [[ ${BASH_REMATCH[2]} == GiB ]]; then efi_mib=$((efi_mib * 1024)); fi
    ((efi_mib >= 512)) || _conf_err "EFI_SIZE too small: '$EFI_SIZE' (min 512MiB)"
  else
    _conf_err "EFI_SIZE invalid: '$EFI_SIZE' (e.g. 2048MiB, 2GiB)"
  fi

  if [[ ! $SWAP_SIZE_GIB =~ ^[0-9]{1,6}$ ]]; then
    _conf_err "SWAP_SIZE_GIB must be a whole number (got '$SWAP_SIZE_GIB')"
  elif [[ $ENABLE_SWAP == true ]] && ((10#$SWAP_SIZE_GIB < 1)); then
    _conf_err "SWAP_SIZE_GIB must be >= 1 when ENABLE_SWAP=true"
  fi

  if [[ $MICROSOFT_CA == true && $ENABLE_SECUREBOOT != true ]]; then
    _conf_err "MICROSOFT_CA=true requires ENABLE_SECUREBOOT=true"
  fi

  if [[ -z $AUR_HELPER ]] && { ((${#PKGS_AUR[@]} > 0)) || [[ $GPU_CHOICE == nvidia-legacy ]]; }; then
    _conf_err "AUR_HELPER required when PKGS_AUR is set or GPU_CHOICE=nvidia-legacy"
  fi

  for k in "${PKGS[@]}" "${PKGS_AUR[@]}"; do
    [[ $k =~ ^[a-z0-9@_+][a-z0-9@._+-]*$ ]] || _conf_err "invalid package name: '$k'"
  done

  [[ $TIMEZONE =~ ^[A-Za-z0-9_+-]+(/[A-Za-z0-9_+-]+)*$ ]] || _conf_err "TIMEZONE invalid: '$TIMEZONE'"

  [[ $LOCALE =~ ^[A-Za-z_]+(\.[A-Za-z0-9-]+)?(@[A-Za-z]+)?$ ]] || _conf_err "LOCALE invalid: '$LOCALE'"

  [[ $KEYMAP =~ ^[A-Za-z0-9_.-]+$ ]] || _conf_err "KEYMAP invalid: '$KEYMAP'"

  ((${#CONF_ERRORS[@]} == 0))
}
