#!/bin/sh
#
# Kolon Chimera Linux simple installer
#
#   UEFI -> GPT + EFI System Partition + GRUB (x86_64-efi)
#   BIOS -> MBR + GRUB (i386-pc)
#
# Run from the Chimera Linux live ISO as root:
#   sh kolon-chimera-installer.sh
#

set -eu

VERSION="0.6.0"
MNT="/media/root"
OFFICIAL_REPO="https://repo.chimera-linux.org"

# State used by the cleanup trap
INSTALL_STARTED=0

# ==================================================
# Colors
# ==================================================

if [ -t 1 ]; then
    RED="$(printf '\033[31m')"
    GREEN="$(printf '\033[32m')"
    YELLOW="$(printf '\033[33m')"
    CYAN="$(printf '\033[36m')"
    BOLD="$(printf '\033[1m')"
    RESET="$(printf '\033[0m')"
else
    RED=""
    GREEN=""
    YELLOW=""
    CYAN=""
    BOLD=""
    RESET=""
fi

# ==================================================
# Helpers
# ==================================================

die() {
    printf '\n%sERROR:%s %s\n' "$RED" "$RESET" "$1" >&2
    exit 1
}

info() {
    printf '%s==>%s %s\n' "$CYAN" "$RESET" "$1"
}

success() {
    printf '%s✓%s %s\n' "$GREEN" "$RESET" "$1"
}

# Warnings go to stderr so they are never captured by $(...)
warning() {
    printf '%sWARNING:%s %s\n' "$YELLOW" "$RESET" "$1" >&2
}

cls() {
    if [ -t 1 ]; then
        clear 2>/dev/null || true
    fi
}

banner() {
    _bar="═══════════════════════════════════════════"
    _text="$1"
    _w=43
    _len=${#_text}
    _left=$(( (_w - _len) / 2 ))
    _right=$(( _w - _len - _left ))
    printf '%s%s' "$BOLD" "$CYAN"
    printf '╔%s╗\n' "$_bar"
    printf '║%*s%s%*s║\n' "$_left" "" "$_text" "$_right" ""
    printf '╚%s╝\n' "$_bar"
    printf '%s' "$RESET"
}

section() {
    cls
    printf '%s%s%s\n\n' "$BOLD" "$1" "$RESET"
}

pause() {
    printf '\nPress Enter to continue...'
    IFS= read -r _ || true
}

# Read one line from stdin into REPLY_LINE (dies on EOF)
read_line() {
    IFS= read -r REPLY_LINE || die "Input closed."
}

# ask "prompt: "  -> prints the answer
ask() {
    printf '%s' "$1" >&2
    read_line
    printf '%s' "$REPLY_LINE"
}

# ask_default "Prompt" "default" -> prints answer or default
ask_default() {
    _ans="$(ask "$1 [$2]: ")"
    printf '%s' "${_ans:-$2}"
}

ask_password() {
    printf '%s' "$1" >&2
    stty -echo 2>/dev/null || true
    if ! IFS= read -r PW_LINE; then
        stty echo 2>/dev/null || true
        die "Input closed."
    fi
    stty echo 2>/dev/null || true
    printf '\n' >&2
    printf '%s' "$PW_LINE"
}

# ask_new_password "Label" -> asks twice until both match and are non-empty
ask_new_password() {
    while true; do
        _p1="$(ask_password "$1 password: ")"

        if [ -z "$_p1" ]; then
            warning "Password cannot be empty."
            continue
        fi

        _p2="$(ask_password "Repeat $1 password: ")"

        if [ "$_p1" = "$_p2" ]; then
            printf '%s' "$_p1"
            return 0
        fi

        warning "Passwords do not match. Try again."
    done
}

yesno() {
    while true; do
        printf '%s [y/N]: ' "$1" >&2
        read_line

        case "$REPLY_LINE" in
            y|Y|yes|YES|Yes) return 0 ;;
            n|N|no|NO|No|"") return 1 ;;
            *) echo "Please answer yes or no." >&2 ;;
        esac
    done
}

# Parse "4G", "512M", "4GiB", "4GB" -> prints size in MiB
parse_size_mib() {
    _s="$(printf '%s' "$1" | tr 'a-z' 'A-Z' | tr -d '[:space:]')"
    _s="${_s%IB}"
    _s="${_s%B}"

    case "$_s" in
        *G) _n="${_s%G}"; _mult=1024 ;;
        *M) _n="${_s%M}"; _mult=1 ;;
        *)  return 1 ;;
    esac

    case "$_n" in
        ""|*[!0-9]*) return 1 ;;
    esac

    _n="$(printf '%s' "$_n" | sed 's/^0*//')"
    [ -n "$_n" ] || return 1

    printf '%s' $(( _n * _mult ))
}

valid_hostname() {
    printf '%s' "$1" |
        grep -Eq '^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$'
}

valid_username() {
    [ "$1" != "root" ] &&
        printf '%s' "$1" | grep -Eq '^[a-z_][a-z0-9_-]{0,31}$'
}

valid_timezone() {
    printf '%s' "$1" | grep -Eq '^[A-Za-z0-9_+/-]+$' &&
        ! printf '%s' "$1" | grep -q '\.\.'
}

# Partition device path: /dev/sda + 1 -> /dev/sda1, /dev/nvme0n1 + 1 -> /dev/nvme0n1p1
part_path() {
    case "$DISK" in
        *[0-9]) printf '%sp%s' "$DISK" "$1" ;;
        *)      printf '%s%s' "$DISK" "$1" ;;
    esac
}

wait_for_block() {
    _i=0
    while [ ! -b "$1" ]; do
        _i=$((_i + 1))
        [ "$_i" -le 20 ] || die "Device did not appear: $1"
        sleep 1
    done
}

is_mounted_at_root() {
    awk -v p="$1" '$1 == p && $2 == "/" { f = 1 } END { exit !f }' /proc/mounts
}

is_mounted() {
    awk -v p="$1" '$1 == p { f = 1 } END { exit !f }' /proc/mounts
}

# Portable replacement for "sed -i" (Chimera uses BSD sed, where -i needs
# a suffix argument and behaves differently from GNU sed).
# Usage: sed_inplace 'script' file
sed_inplace() {
    _sed_tmp="$2.kolon-tmp"
    sed "$1" "$2" > "$_sed_tmp" || { rm -f "$_sed_tmp"; return 1; }
    cat "$_sed_tmp" > "$2"
    rm -f "$_sed_tmp"
}

# Run a shell script (from stdin) inside the new system
in_chroot() {
    chimera-chroot "$MNT" /bin/sh -e
}

# Install packages if they exist in the repositories, warn about the rest
install_optional_pkgs() {
    _req="$1"

    in_chroot <<EOF
avail=""
for p in $_req; do
    if apk search -e "\$p" 2>/dev/null | grep -q .; then
        avail="\$avail \$p"
    else
        echo "WARNING: package not found, skipping: \$p"
    fi
done
if [ -n "\$avail" ]; then
    apk add \$avail
fi
EOF
}

# Enable the first existing dinit service from the list
enable_service() {
    _cands="$*"

    in_chroot <<EOF
mkdir -p /etc/dinit.d/boot.d
for s in $_cands; do
    if [ -e "/etc/dinit.d/\$s" ]; then
        ln -sf "../\$s" "/etc/dinit.d/boot.d/\$s"
        echo "Service enabled: \$s"
        exit 0
    fi
done
echo "WARNING: none of these services were found: $_cands"
EOF
}

cleanup() {
    _rc=$?
    stty echo 2>/dev/null || true

    if [ "$_rc" -ne 0 ] && [ "$INSTALL_STARTED" -eq 1 ]; then
        printf '\n%sInstallation failed.%s\n' "$RED" "$RESET" >&2
        echo "Filesystems may still be mounted under $MNT for inspection." >&2
        echo "Unmount manually with: umount -R $MNT" >&2
    fi
}

trap cleanup EXIT
trap 'exit 130' INT TERM

# ==================================================
# Root / architecture checks
# ==================================================

[ "$(id -u)" -eq 0 ] || die "Run this installer as root."

ARCH="$(uname -m)"

[ "$ARCH" = "x86_64" ] ||
    die "This installer currently supports x86_64 only."

for cmd in \
    lsblk blkid mount umount mkfs.ext4 mkswap swapoff \
    sfdisk wipefs blockdev awk sed grep tr \
    chimera-bootstrap chimera-chroot
do
    command -v "$cmd" >/dev/null 2>&1 ||
        die "Required command not found: $cmd"
done

# ==================================================
# Welcome
# ==================================================

cls
banner "Kolon Chimera Linux simple installer"
printf '%s%s%s\n' "$CYAN" "                    v$VERSION" "$RESET"
echo
echo "Chimera Linux x86_64 installer"
echo
echo "Features:"
echo "  • UEFI (GPT + EFI) and BIOS (MBR)"
echo "  • Swap and optional hibernation"
echo "  • Custom hostname, user, passwords, mirror, kernel"
echo "  • Optional desktop environment"
echo "  • opendoas"

pause

# ==================================================
# 1. Boot mode
# ==================================================

section "1. Boot mode"

if [ -d /sys/firmware/efi ]; then
    DEFAULT_BOOT=1
    echo "Detected: UEFI firmware"
else
    DEFAULT_BOOT=2
    echo "Detected: BIOS / Legacy firmware"
fi

echo
echo "  1) UEFI    (GPT + EFI System Partition)"
echo "  2) BIOS    (MBR)"
echo

BOOTCHOICE="$(ask_default "Choice [1-2]" "$DEFAULT_BOOT")"

case "$BOOTCHOICE" in
    1) BOOTMODE="UEFI" ;;
    2) BOOTMODE="BIOS" ;;
    *) die "Invalid boot mode." ;;
esac

if [ "$BOOTMODE" = "UEFI" ]; then
    command -v mkfs.vfat >/dev/null 2>&1 ||
        die "mkfs.vfat (dosfstools) is required for UEFI."

    [ -d /sys/firmware/efi ] ||
        warning "The live system was NOT booted in UEFI mode. GRUB will still install a removable fallback, but check your firmware settings."
fi

success "Boot mode: $BOOTMODE"

# ==================================================
# 2. Disk
# ==================================================

section "2. Installation disk"

lsblk -o NAME,SIZE,TYPE,FSTYPE,MODEL,MOUNTPOINTS
echo

DISK="$(ask "Installation disk (example: /dev/sda, /dev/nvme0n1): ")"
DISK="$(printf '%s' "$DISK" | tr -d '[:space:]')"

case "$DISK" in
    /dev/*) ;;
    *) die "Invalid disk path (must start with /dev/)." ;;
esac

[ -b "$DISK" ] || die "Disk does not exist: $DISK"

DISK_TYPE="$(lsblk -dno TYPE "$DISK" 2>/dev/null || true)"

case "$DISK_TYPE" in
    disk|loop) ;;
    *) die "$DISK is not a whole disk (type: ${DISK_TYPE:-unknown}). Select the disk, not a partition." ;;
esac

# Refuse to touch the disk we are running from
for part in $(lsblk -nlo PATH "$DISK"); do
    if is_mounted_at_root "$part"; then
        die "$part is the running system's root. Choose another disk."
    fi
done

DISK_MIB=$(( $(blockdev --getsize64 "$DISK") / 1048576 ))

echo
success "Selected disk: $DISK (${DISK_MIB} MiB)"
echo
warning "ALL DATA ON $DISK WILL BE DESTROYED."

yesno "Continue with $DISK?" || { echo "Installation cancelled."; exit 0; }

# ==================================================
# 3. Swap
# ==================================================

section "3. Swap"

RAM_MIB="$(awk '/^MemTotal:/ { print int($2 / 1024) }' /proc/meminfo)"
RAM_GIB=$(( (RAM_MIB + 1023) / 1024 ))

echo "Detected RAM: ${RAM_MIB} MiB"
echo
echo "  1) No swap"
echo "  2) Swap without hibernation"
echo "  3) Swap + hibernation (swap should be >= RAM)"
echo

SWAPCHOICE="$(ask "Choice [1-3]: ")"

SWAP_MODE="NONE"
SWAP_SIZE=""
SWAP_MIB=0

case "$SWAPCHOICE" in
    1)
        SWAP_MODE="NONE"
        ;;
    2|3)
        if [ "$SWAPCHOICE" = "2" ]; then
            SWAP_MODE="SWAP"
            SWAP_DEFAULT="4G"
        else
            SWAP_MODE="HIBERNATE"
            SWAP_DEFAULT="${RAM_GIB}G"
        fi

        while true; do
            SWAP_SIZE="$(ask_default "Swap size (e.g. 4G, 512M)" "$SWAP_DEFAULT")"

            if SWAP_MIB="$(parse_size_mib "$SWAP_SIZE")" && [ "$SWAP_MIB" -ge 256 ]; then
                break
            fi

            warning "Invalid swap size. Use a number with M or G (minimum 256M)."
        done

        if [ "$SWAP_MODE" = "HIBERNATE" ] && [ "$SWAP_MIB" -lt "$RAM_MIB" ]; then
            warning "Swap (${SWAP_MIB} MiB) is smaller than RAM (${RAM_MIB} MiB). Hibernation may fail."
            yesno "Continue anyway?" || die "Aborted. Re-run and choose a larger swap."
        fi
        ;;
    *)
        die "Invalid swap choice."
        ;;
esac

# Disk space check: ESP + swap + at least 8 GiB for root
NEEDED_MIB=$(( SWAP_MIB + 8192 ))
[ "$BOOTMODE" = "UEFI" ] && NEEDED_MIB=$(( NEEDED_MIB + 512 ))

[ "$DISK_MIB" -ge "$NEEDED_MIB" ] ||
    die "Disk is too small. Need at least ${NEEDED_MIB} MiB, have ${DISK_MIB} MiB."

case "$SWAP_MODE" in
    NONE)      success "Swap disabled." ;;
    SWAP)      success "Swap enabled: $SWAP_SIZE" ;;
    HIBERNATE) success "Swap + hibernation enabled: $SWAP_SIZE" ;;
esac

# ==================================================
# 4. Hostname
# ==================================================

section "4. PC name (hostname)"

while true; do
    HOSTNAME="$(ask_default "PC name" "chimera")"
    valid_hostname "$HOSTNAME" && break
    warning "Invalid hostname. Use letters, digits and '-' (max 63 chars)."
done

# ==================================================
# 5. User and passwords
# ==================================================

section "5. User account"

while true; do
    USERNAME="$(ask_default "Username" "kolon")"
    valid_username "$USERNAME" && break
    warning "Invalid username. Use lowercase letters, digits, '_' or '-'; must not be 'root'."
done

echo
USERPASS="$(ask_new_password "User")"
echo
ROOTPASS="$(ask_new_password "Root")"

# ==================================================
# 6. Timezone
# ==================================================

section "6. Timezone"

while true; do
    TIMEZONE="$(ask_default "Timezone (e.g. UTC, Europe/Berlin, America/New_York)" "UTC")"
    valid_timezone "$TIMEZONE" && break
    warning "Invalid timezone string."
done

# ==================================================
# 7. Repository
# ==================================================

section "7. Repository"

echo "  1) Official Chimera repository ($OFFICIAL_REPO)"
echo "  2) Custom mirror"
echo

REPOCHOICE="$(ask "Choice [1-2]: ")"

case "$REPOCHOICE" in
    1)
        MIRROR="$OFFICIAL_REPO"
        ;;
    2)
        while true; do
            MIRROR="$(ask "Mirror URL (https://...): ")"
            MIRROR="$(printf '%s' "$MIRROR" | tr -d '[:space:]' | sed 's|/*$||')"

            printf '%s' "$MIRROR" | grep -Eq '^https?://[^/]+' && break
            warning "Mirror URL must start with http:// or https://"
        done
        ;;
    *)
        die "Invalid repository choice."
        ;;
esac

# ==================================================
# 8. Kernel
# ==================================================

section "8. Kernel"

echo "  1) linux-lts"
echo "  2) linux-stable"
echo

KERNELCHOICE="$(ask "Choice [1-2]: ")"

case "$KERNELCHOICE" in
    1) KERNEL="linux-lts" ;;
    2) KERNEL="linux-stable" ;;
    *) die "Invalid kernel choice." ;;
esac

# ==================================================
# 9. Desktop environment
# ==================================================

section "9. Desktop environment"

echo "  1) None (console only)"
echo "  2) KDE Plasma"
echo "  3) GNOME"
echo "  4) XFCE"
echo

DESKTOPCHOICE="$(ask "Choice [1-4]: ")"

DESKTOP_NAME="none"
DESKTOP_PKGS=""
DESKTOP_DM=""

case "$DESKTOPCHOICE" in
    1)
        ;;
    2)
        DESKTOP_NAME="KDE Plasma"
        DESKTOP_PKGS="plasma-desktop-meta plasma-desktop konsole sddm"
        DESKTOP_DM="sddm"
        ;;
    3)
        DESKTOP_NAME="GNOME"
        DESKTOP_PKGS="gnome gdm"
        DESKTOP_DM="gdm"
        ;;
    4)
        DESKTOP_NAME="XFCE"
        DESKTOP_PKGS="xfce4-session xfce4-panel xfdesktop xfwm4 xfce4-settings xfce4-terminal thunar lightdm lightdm-gtk-greeter"
        DESKTOP_DM="lightdm"
        ;;
    *)
        die "Invalid desktop choice."
        ;;
esac

# ==================================================
# Summary
# ==================================================

cls
banner "INSTALLATION SUMMARY"
echo
echo "Architecture: $ARCH"
echo "Boot mode:    $BOOTMODE"
echo "Disk:         $DISK"

if [ "$BOOTMODE" = "UEFI" ]; then
    echo "Partitions:   GPT (EFI 512M + root$([ "$SWAP_MODE" != "NONE" ] && printf ' + swap'))"
else
    echo "Partitions:   MBR (root$([ "$SWAP_MODE" != "NONE" ] && printf ' + swap'))"
fi

if [ "$SWAP_MODE" = "NONE" ]; then
    echo "Swap:         disabled"
else
    echo "Swap:         $SWAP_SIZE"
    if [ "$SWAP_MODE" = "HIBERNATE" ]; then
        echo "Hibernation:  enabled"
    else
        echo "Hibernation:  disabled"
    fi
fi

echo
echo "Hostname:     $HOSTNAME"
echo "Username:     $USERNAME"
echo "Timezone:     $TIMEZONE"
echo "Repository:   $MIRROR"
echo "Kernel:       $KERNEL"
echo "Desktop:      $DESKTOP_NAME"
echo
warning "The selected disk ($DISK) will be completely erased."
echo

yesno "Start installation?" || { echo "Installation cancelled."; exit 0; }

# ==================================================
# Network check (before anything is destroyed)
# ==================================================

section "10. Network"

info "Checking connection to $MIRROR ..."

network_ok() {
    if command -v curl >/dev/null 2>&1; then
        curl -fsSI --max-time 15 "$MIRROR" >/dev/null 2>&1
    elif command -v wget >/dev/null 2>&1; then
        wget -q --spider -T 15 "$MIRROR" >/dev/null 2>&1
    elif command -v ping >/dev/null 2>&1; then
        _host="${MIRROR#*://}"
        _host="${_host%%/*}"
        _host="${_host%%:*}"
        ping -c 1 -W 3 "$_host" >/dev/null 2>&1
    else
        return 0
    fi
}

if network_ok; then
    success "Repository is reachable."
else
    warning "Could not reach $MIRROR."
    yesno "Continue anyway?" || die "Check your network connection and try again."
fi

# ==================================================
# Partitioning
# ==================================================

INSTALL_STARTED=1

section "11. Partitioning"

info "Unmounting anything on $DISK and $MNT ..."

umount -R "$MNT" 2>/dev/null || true

for part in $(lsblk -nlo PATH "$DISK" | sort -r); do
    swapoff "$part" 2>/dev/null || true
    umount "$part" 2>/dev/null || true

    if is_mounted "$part"; then
        die "Could not unmount $part. Unmount it manually and retry."
    fi
done

sync

info "Wiping old signatures..."

for part in $(lsblk -nlo PATH "$DISK" | sort -r); do
    wipefs -af "$part" >/dev/null 2>&1 || true
done

wipefs -af "$DISK" >/dev/null

ESP=""
SWAP=""

# Layout (sizes in 512-byte sectors; 1 MiB = 2048 sectors)
SWAP_SECTORS=$(( SWAP_MIB * 2048 ))

if [ "$BOOTMODE" = "UEFI" ]; then

    info "Creating GPT partition table..."

    if [ "$SWAP_MODE" != "NONE" ]; then
        sfdisk --quiet "$DISK" <<EOF
label: gpt
start=2048, size=1048576, type=U, name="EFI System Partition"
size=$SWAP_SECTORS, type=S, name="Chimera Swap"
type=L, name="Chimera Root"
EOF
        ESP="$(part_path 1)"
        SWAP="$(part_path 2)"
        ROOT="$(part_path 3)"
    else
        sfdisk --quiet "$DISK" <<EOF
label: gpt
start=2048, size=1048576, type=U, name="EFI System Partition"
type=L, name="Chimera Root"
EOF
        ESP="$(part_path 1)"
        ROOT="$(part_path 2)"
    fi

else

    info "Creating MBR partition table..."

    if [ "$SWAP_MODE" != "NONE" ]; then
        sfdisk --quiet "$DISK" <<EOF
label: dos
start=2048, size=$SWAP_SECTORS, type=S
type=L, bootable
EOF
        SWAP="$(part_path 1)"
        ROOT="$(part_path 2)"
    else
        sfdisk --quiet "$DISK" <<EOF
label: dos
start=2048, type=L, bootable
EOF
        ROOT="$(part_path 1)"
    fi

fi

sync

blockdev --rereadpt "$DISK" 2>/dev/null || true
command -v partprobe >/dev/null 2>&1 && partprobe "$DISK" 2>/dev/null || true
command -v udevadm >/dev/null 2>&1 && udevadm settle 2>/dev/null || true

wait_for_block "$ROOT"
[ -z "$ESP" ]  || wait_for_block "$ESP"
[ -z "$SWAP" ] || wait_for_block "$SWAP"

if [ -n "$ESP" ]; then
    info "Formatting EFI partition ($ESP)..."
    mkfs.vfat -F 32 -n EFI "$ESP" >/dev/null
fi

if [ -n "$SWAP" ]; then
    info "Formatting swap ($SWAP)..."
    mkswap -L swap "$SWAP" >/dev/null
fi

info "Formatting root ($ROOT)..."
mkfs.ext4 -F -q -L Chimera "$ROOT"

success "Partitioning complete."

# ==================================================
# Mounting
# ==================================================

section "12. Mounting"

mkdir -p "$MNT"

info "Mounting root..."
mount "$ROOT" "$MNT"

if [ "$BOOTMODE" = "UEFI" ]; then
    info "Mounting EFI..."
    mkdir -p "$MNT/boot/efi"
    mount "$ESP" "$MNT/boot/efi"

    # Needed for grub-install to create the NVRAM boot entry
    if [ -d /sys/firmware/efi/efivars ] &&
       ! mountpoint -q /sys/firmware/efi/efivars 2>/dev/null; then
        mount -t efivarfs efivarfs /sys/firmware/efi/efivars 2>/dev/null || true
    fi
fi

success "Filesystems mounted."

# ==================================================
# Bootstrap
# ==================================================

section "13. Installing Chimera base system"

info "Bootstrapping Chimera Linux (this may take a while)..."

# Honoured by chimera-bootstrap/apk when a custom mirror is chosen
CHIMERA_REPO_URL="$MIRROR" chimera-bootstrap "$MNT"

success "Base system installed."

# Make sure DNS works inside the chroot
if [ ! -s "$MNT/etc/resolv.conf" ] && [ -r /etc/resolv.conf ]; then
    cp -L /etc/resolv.conf "$MNT/etc/resolv.conf" 2>/dev/null || true
fi

# ==================================================
# Repository configuration
# ==================================================

if [ "$MIRROR" != "$OFFICIAL_REPO" ]; then
    info "Configuring custom mirror..."

    MIRROR_ESC="$(printf '%s' "$MIRROR" | sed 's/[&|\\]/\\&/g')"

    for f in "$MNT"/etc/apk/repositories.d/*.list; do
        [ -f "$f" ] || continue
        sed_inplace "s|$OFFICIAL_REPO|$MIRROR_ESC|g" "$f"
    done

    success "Mirror configured."
fi

# ==================================================
# System configuration (before kernel install)
# ==================================================

section "14. Configuring system"

info "Setting hostname..."
printf '%s\n' "$HOSTNAME" > "$MNT/etc/hostname"

info "Setting timezone..."
in_chroot <<EOF
if [ -f "/usr/share/zoneinfo/$TIMEZONE" ]; then
    ln -sf "/usr/share/zoneinfo/$TIMEZONE" /etc/localtime
    echo "Timezone set to $TIMEZONE"
else
    echo "WARNING: timezone '$TIMEZONE' not found, keeping default."
fi
EOF

info "Creating /etc/fstab..."

ROOT_UUID="$(blkid -s UUID -o value "$ROOT")"
[ -n "$ROOT_UUID" ] || die "Could not determine root UUID."

printf 'UUID=%s  /  ext4  defaults,noatime  0 1\n' "$ROOT_UUID" > "$MNT/etc/fstab"

if [ "$BOOTMODE" = "UEFI" ]; then
    EFI_UUID="$(blkid -s UUID -o value "$ESP")"
    [ -n "$EFI_UUID" ] || die "Could not determine EFI UUID."

    printf 'UUID=%s  /boot/efi  vfat  defaults,umask=0077  0 2\n' "$EFI_UUID" \
        >> "$MNT/etc/fstab"
fi

SWAP_UUID=""

if [ "$SWAP_MODE" != "NONE" ]; then
    SWAP_UUID="$(blkid -s UUID -o value "$SWAP")"
    [ -n "$SWAP_UUID" ] || die "Could not determine swap UUID."

    printf 'UUID=%s  none  swap  sw  0 0\n' "$SWAP_UUID" >> "$MNT/etc/fstab"
fi

success "fstab configured."

# Resume device must be known before the initramfs is generated
if [ "$SWAP_MODE" = "HIBERNATE" ]; then
    info "Configuring resume for hibernation..."

    mkdir -p "$MNT/etc/initramfs-tools/conf.d"
    printf 'RESUME=UUID=%s\n' "$SWAP_UUID" > "$MNT/etc/initramfs-tools/conf.d/resume"
fi

# ==================================================
# Packages
# ==================================================

section "15. Installing packages"

info "Updating package database..."

in_chroot <<'EOF'
apk update
apk upgrade --available
EOF

info "Installing kernel and base utilities..."

in_chroot <<EOF
apk add "$KERNEL" opendoas bash nano curl wget git
EOF

info "Installing network manager..."
install_optional_pkgs "networkmanager"
enable_service networkmanager NetworkManager

success "Base packages installed."

# ==================================================
# doas
# ==================================================

info "Configuring doas..."

printf 'permit persist :wheel\n' > "$MNT/etc/doas.conf"
chmod 600 "$MNT/etc/doas.conf"

success "doas configured."

# ==================================================
# Users
# ==================================================

info "Creating user '$USERNAME'..."

in_chroot <<EOF
groups=""
for g in wheel audio video input network plugdev; do
    if getent group "\$g" >/dev/null 2>&1; then
        groups="\${groups:+\$groups,}\$g"
    fi
done

if command -v useradd >/dev/null 2>&1; then
    useradd -m -s /bin/bash ${USERNAME}
    if [ -n "\$groups" ]; then
        usermod -aG "\$groups" ${USERNAME}
    fi
else
    adduser -D -s /bin/bash ${USERNAME}
    for g in \$(echo "\$groups" | tr ',' ' '); do
        addgroup ${USERNAME} "\$g" || true
    done
fi
EOF

# Passwords are piped through stdin: never on a command line or in a file.
printf '%s:%s\n' "root" "$ROOTPASS" | chimera-chroot "$MNT" chpasswd
printf '%s:%s\n' "$USERNAME" "$USERPASS" | chimera-chroot "$MNT" chpasswd

# Do not keep passwords around longer than needed
USERPASS=""
ROOTPASS=""

success "Users configured."

# ==================================================
# Desktop
# ==================================================

if [ -n "$DESKTOP_PKGS" ]; then
    section "16. Desktop environment ($DESKTOP_NAME)"

    info "Installing desktop packages..."
    install_optional_pkgs "$DESKTOP_PKGS"

    info "Enabling display manager ($DESKTOP_DM)..."
    enable_service "$DESKTOP_DM"

    success "Desktop environment installed."
fi

# ==================================================
# Bootloader
# ==================================================

section "17. Bootloader"

info "Installing GRUB package..."

if [ "$BOOTMODE" = "UEFI" ]; then
    in_chroot <<'EOF'
apk add grub-x86_64-efi
EOF
    install_optional_pkgs "efibootmgr"
else
    in_chroot <<'EOF'
apk add grub-i386-pc
EOF
fi

# Hibernation: append resume= to the kernel command line (keep existing options)
if [ "$SWAP_MODE" = "HIBERNATE" ]; then
    info "Adding resume= to GRUB kernel command line..."

    GRUBCFG="$MNT/etc/default/grub"
    mkdir -p "$MNT/etc/default"

    if [ -f "$GRUBCFG" ] && grep -q '^GRUB_CMDLINE_LINUX_DEFAULT=' "$GRUBCFG"; then
        sed_inplace "s|^\(GRUB_CMDLINE_LINUX_DEFAULT=\"[^\"]*\)\"|\1 resume=UUID=$SWAP_UUID\"|" "$GRUBCFG"
    else
        printf 'GRUB_CMDLINE_LINUX_DEFAULT="resume=UUID=%s"\n' "$SWAP_UUID" >> "$GRUBCFG"
    fi
fi

info "Generating initramfs..."

in_chroot <<'EOF'
update-initramfs -c -k all
EOF

info "Installing GRUB to disk..."

if [ "$BOOTMODE" = "UEFI" ]; then
    in_chroot <<'EOF'
if ! grub-install --target=x86_64-efi --efi-directory=/boot/efi \
        --bootloader-id=Chimera --recheck; then
    echo "WARNING: could not create NVRAM entry, relying on the removable fallback."
fi

# Fallback path (EFI/BOOT/BOOTX64.EFI) so the system boots even without NVRAM entry
grub-install --target=x86_64-efi --efi-directory=/boot/efi --removable --recheck

update-grub
EOF
else
    in_chroot <<EOF
grub-install --target=i386-pc --recheck "$DISK"
update-grub
EOF
fi

success "GRUB installed."

# ==================================================
# Finish
# ==================================================

info "Syncing filesystems..."
sync

info "Unmounting..."
umount -R "$MNT" 2>/dev/null || true
sync

INSTALL_STARTED=0

cls
banner "INSTALLATION COMPLETE"
printf '%s' "$GREEN"
echo
echo "Chimera Linux installation finished."
printf '%s' "$RESET"
echo
echo "Architecture: $ARCH"
echo "Boot mode:    $BOOTMODE"
echo "Disk:         $DISK"

if [ "$SWAP_MODE" = "NONE" ]; then
    echo "Swap:         disabled"
elif [ "$SWAP_MODE" = "SWAP" ]; then
    echo "Swap:         $SWAP_SIZE (hibernation disabled)"
else
    echo "Swap:         $SWAP_SIZE (hibernation enabled)"
fi

echo
echo "Hostname:     $HOSTNAME"
echo "Username:     $USERNAME"
echo "Kernel:       $KERNEL"
echo "Desktop:      $DESKTOP_NAME"
echo

warning "Remove the installation USB before rebooting."
echo

if yesno "Reboot now?"; then
    reboot
else
    echo
    echo "Reboot later with:"
    echo
    echo "    reboot"
fi
