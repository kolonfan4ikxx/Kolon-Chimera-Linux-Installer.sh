#!/bin/sh
#
# Kolon Chimera Linux Installer
# UEFI: GPT + EFI
# BIOS: MBR
#

set -eu

VERSION="0.5.0"

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
# Functions
# ==================================================

die() {
    echo
    echo "${RED}ERROR:${RESET} $1"
    exit 1
}

info() {
    echo "${CYAN}==>${RESET} $1"
}

success() {
    echo "${GREEN}✓${RESET} $1"
}

warning() {
    echo "${YELLOW}WARNING:${RESET} $1"
}

pause() {
    printf "\nPress Enter to continue..."
    read -r _
}

ask() {
    printf "%s" "$1" >&2
    read -r ANSWER
    printf "%s" "$ANSWER"
}

ask_password() {
    printf "%s" "$1" >&2
    stty -echo
    read -r ANSWER
    stty echo
    printf "\n" >&2
    printf "%s" "$ANSWER"
}

yesno() {
    while true; do
        printf "%s [y/N]: " "$1" >&2
        read -r ANSWER

        case "$ANSWER" in
            y|Y|yes|YES)
                return 0
                ;;
            n|N|no|NO|"")
                return 1
                ;;
            *)
                echo "Please answer yes or no." >&2
                ;;
        esac
    done
}

# ==================================================
# Root check
# ==================================================

if [ "$(id -u)" -ne 0 ]; then
    die "Run this installer as root."
fi

# ==================================================
# Architecture check
# ==================================================

ARCH="$(uname -m)"

case "$ARCH" in
    x86_64)
        ;;
    *)
        die "This installer currently supports x86_64 only."
        ;;
esac

# ==================================================
# Dependency check
# ==================================================

for cmd in \
    lsblk \
    blkid \
    mount \
    umount \
    mkfs.ext4 \
    mkswap \
    sfdisk \
    partprobe \
    blockdev \
    chimera-bootstrap \
    chimera-chroot
do
    command -v "$cmd" >/dev/null 2>&1 ||
        die "Required command not found: $cmd"
done

# ==================================================
# Header
# ==================================================

clear

echo "${BOLD}${CYAN}"
echo "╔════════════════════════════════════════════╗"
echo "║       Kolon Chimera Linux Installer        ║"
echo "║                  v$VERSION                 ║"
echo "╚════════════════════════════════════════════╝"
echo "${RESET}"

echo
echo "Chimera Linux x86_64 installer"
echo
echo "Supported:"
echo "  • UEFI → GPT + EFI"
echo "  • BIOS → MBR"
echo "  • Swap"
echo "  • Optional hibernation"
echo "  • opendoas"
echo

pause

# ==================================================
# Boot mode
# ==================================================

clear

echo "${BOLD}1. Boot mode${RESET}"
echo

echo "  1) UEFI"
echo "     GPT + EFI System Partition"
echo

echo "  2) BIOS / Legacy"
echo "     MBR"
echo

BOOTMODE="$(ask "Choice [1-2]: ")"

case "$BOOTMODE" in
    1)
        BOOTMODE="UEFI"
        ;;
    2)
        BOOTMODE="BIOS"
        ;;
    *)
        die "Invalid boot mode."
        ;;
esac

success "Selected boot mode: $BOOTMODE"

pause

# ==================================================
# Network
# ==================================================

clear

echo "${BOLD}2. Network${RESET}"
echo

info "Checking network..."

if command -v ping >/dev/null 2>&1; then
    if ping -c 1 -W 3 repo.chimera-linux.org >/dev/null 2>&1; then
        success "Network is reachable."
    else
        warning "Could not reach repo.chimera-linux.org."
        echo "Check your network before continuing."
    fi
else
    warning "ping is not available."
fi

pause

# ==================================================
# Disk
# ==================================================

clear

echo "${BOLD}3. Installation disk${RESET}"
echo

lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINTS

echo

DISK="$(ask "Installation disk (example: /dev/sdc): ")"
DISK="$(printf '%s' "$DISK" | tr -d '[:space:]')"

[ -b "$DISK" ] ||
    die "Disk does not exist: $DISK"

case "$DISK" in
    /dev/*)
        ;;
    *)
        die "Invalid disk path."
        ;;
esac

echo
success "Selected disk: $DISK"
echo

warning "ALL DATA ON $DISK WILL BE DESTROYED."

if ! yesno "Continue with $DISK?"; then
    echo "Installation cancelled."
    exit 0
fi

# ==================================================
# Swap
# ==================================================

clear

echo "${BOLD}4. Swap${RESET}"
echo

echo "Choose swap configuration:"
echo
echo "  1) No swap"
echo "  2) Swap without hibernation"
echo "  3) Swap + hibernation"
echo

SWAPCHOICE=$(ask "Choice [1-3]: ")

case "$SWAPCHOICE" in
    1)
        SWAP_MODE="NONE"
        SWAP_SIZE=""
        ;;
    2)
        SWAP_MODE="SWAP"
        SWAP_SIZE=$(ask "Swap size [4G]: ")
        SWAP_SIZE=${SWAP_SIZE:-4G}
        ;;
    3)
        SWAP_MODE="HIBERNATE"
        SWAP_SIZE=$(ask "Swap size [8G]: ")
        SWAP_SIZE=${SWAP_SIZE:-8G}
        ;;
    *)
        die "Invalid swap choice."
        ;;
esac

echo

case "$SWAP_MODE" in
    NONE)
        success "Swap disabled."
        ;;
    SWAP)
        success "Swap enabled: $SWAP_SIZE"
        ;;
    HIBERNATE)
        success "Swap + hibernation enabled: $SWAP_SIZE"
        ;;
esac

pause

# ==================================================
# Hostname
# ==================================================

clear

echo "${BOLD}5. PC name${RESET}"
echo

HOSTNAME="$(ask "PC name [chimera]: ")"
HOSTNAME=${HOSTNAME:-chimera}

case "$HOSTNAME" in
    *[!a-zA-Z0-9_-]*)
        die "Invalid hostname."
        ;;
esac

# ==================================================
# User
# ==================================================

clear

echo "${BOLD}6. User account${RESET}"
echo

USERNAME="$(ask "Username [kolon]: ")"
USERNAME=${USERNAME:-kolon}

case "$USERNAME" in
    *[!a-zA-Z0-9_-]*)
        die "Invalid username."
        ;;
esac

# ==================================================
# User password
# ==================================================

echo

USERPASS="$(ask_password "User password: ")"

[ -n "$USERPASS" ] ||
    die "User password cannot be empty."

USERPASS2="$(ask_password "Repeat user password: ")"

[ "$USERPASS" = "$USERPASS2" ] ||
    die "User passwords do not match."

# ==================================================
# Root password
# ==================================================

echo

ROOTPASS="$(ask_password "Root password: ")"

[ -n "$ROOTPASS" ] ||
    die "Root password cannot be empty."

ROOTPASS2="$(ask_password "Repeat root password: ")"

[ "$ROOTPASS" = "$ROOTPASS2" ] ||
    die "Root passwords do not match."

# ==================================================
# Repository
# ==================================================

clear

echo "${BOLD}7. Repository${RESET}"
echo

echo "  1) Official Chimera repository"
echo "  2) Custom mirror"
echo

REPOCHOICE="$(ask "Choice [1-2]: ")"

case "$REPOCHOICE" in
    1)
        MIRROR="https://repo.chimera-linux.org"
        ;;
    2)
        MIRROR="$(ask "Mirror URL: ")"

        [ -n "$MIRROR" ] ||
            die "Mirror URL cannot be empty."
        ;;
    *)
        die "Invalid repository choice."
        ;;
esac

# ==================================================
# Kernel
# ==================================================

clear

echo "${BOLD}8. Kernel${RESET}"
echo

echo "  1) linux-lts"
echo "  2) linux-stable"
echo

KERNELCHOICE="$(ask "Choice [1-2]: ")"

case "$KERNELCHOICE" in
    1)
        KERNEL="linux-lts"
        ;;
    2)
        KERNEL="linux-stable"
        ;;
    *)
        die "Invalid kernel choice."
        ;;
esac

# ==================================================
# Desktop
# ==================================================

clear

echo "${BOLD}9. Desktop environment${RESET}"
echo

echo "  1) None"
echo "  2) KDE Plasma"
echo "  3) GNOME"
echo "  4) XFCE"
echo

DESKTOPCHOICE="$(ask "Choice [1-4]: ")"

case "$DESKTOPCHOICE" in
    1)
        DESKTOP=""
        ;;
    2)
        DESKTOP="plasma-desktop-meta"
        ;;
    3)
        DESKTOP="gnome"
        ;;
    4)
        DESKTOP="xfce4-session xfce4-panel xfdesktop xfwm4"
        ;;
    *)
        die "Invalid desktop choice."
        ;;
esac

# ==================================================
# Summary
# ==================================================

clear

echo "${BOLD}${CYAN}"
echo "╔════════════════════════════════════════════╗"
echo "║             INSTALLATION SUMMARY           ║"
echo "╚════════════════════════════════════════════╝"
echo "${RESET}"

echo
echo "Architecture: $ARCH"
echo "Boot mode:    $BOOTMODE"
echo "Disk:         $DISK"

if [ "$BOOTMODE" = "UEFI" ]; then
    echo "Partition:    GPT"
else
    echo "Partition:    MBR"
fi

echo

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
echo "Repository:   $MIRROR"
echo "Kernel:       $KERNEL"

if [ -n "$DESKTOP" ]; then
    echo "Desktop:      $DESKTOP"
else
    echo "Desktop:      none"
fi

echo
warning "The selected disk will be completely erased."
echo

if ! yesno "Start installation?"; then
    echo "Installation cancelled."
    exit 0
fi

# ==================================================
# Partitioning
# ==================================================

clear

echo "${BOLD}10. Partitioning${RESET}"
echo

info "Unmounting existing partitions from $DISK..."

# Don't fail if nothing is mounted.
umount "${DISK}"* 2>/dev/null || true

sync

# --------------------------------------------------
# UEFI / GPT
# --------------------------------------------------

if [ "$BOOTMODE" = "UEFI" ]; then

    command -v sgdisk >/dev/null 2>&1 ||
        die "sgdisk is required for GPT partitioning."

    command -v mkfs.vfat >/dev/null 2>&1 ||
        die "mkfs.vfat is required for UEFI."

    info "Creating GPT..."

    sgdisk --zap-all "$DISK"

    # EFI
    sgdisk \
        -n 1:0:+512M \
        -t 1:EF00 \
        -c 1:"EFI System Partition" \
        "$DISK"

    PARTNUM=2

    # Swap
    if [ "$SWAP_MODE" != "NONE" ]; then

        SWAP_BYTES="$(numfmt --from=iec "$SWAP_SIZE")"
        SWAP_SECTORS=$((SWAP_BYTES / 512))

        [ "$SWAP_SECTORS" -gt 0 ] ||
            die "Invalid swap size."

        sgdisk \
            -n "${PARTNUM}:0:+${SWAP_SECTORS}S" \
            -t "${PARTNUM}:8200" \
            -c "${PARTNUM}:Chimera Swap" \
            "$DISK"

        SWAPNUM="$PARTNUM"
        PARTNUM=$((PARTNUM + 1))
    fi

    # Root
    sgdisk \
        -n "${PARTNUM}:0:0" \
        -t "${PARTNUM}:8300" \
        -c "${PARTNUM}:Chimera Root" \
        "$DISK"

    ROOTNUM="$PARTNUM"

    sync

    partprobe "$DISK" 2>/dev/null || true
    sleep 2

    case "$DISK" in
        /dev/nvme*|/dev/mmcblk*)
            ESP="${DISK}p1"
            ROOT="${DISK}p${ROOTNUM}"

            if [ "$SWAP_MODE" != "NONE" ]; then
                SWAP="${DISK}p${SWAPNUM}"
            fi
            ;;
        *)
            ESP="${DISK}1"
            ROOT="${DISK}${ROOTNUM}"

            if [ "$SWAP_MODE" != "NONE" ]; then
                SWAP="${DISK}${SWAPNUM}"
            fi
            ;;
    esac

    [ -b "$ESP" ] || die "EFI partition not found: $ESP"
    [ -b "$ROOT" ] || die "Root partition not found: $ROOT"

    if [ "$SWAP_MODE" != "NONE" ]; then
        [ -b "$SWAP" ] || die "Swap partition not found: $SWAP"
    fi

    info "Formatting EFI..."

    mkfs.vfat -F 32 "$ESP"

    if [ "$SWAP_MODE" != "NONE" ]; then
        info "Formatting swap..."
        mkswap "$SWAP"
    fi

    info "Formatting root..."

    mkfs.ext4 -F "$ROOT"

# --------------------------------------------------
# BIOS / MBR
# --------------------------------------------------

else

    info "Creating MBR..."

    DISK_SECTORS="$(blockdev --getsz "$DISK")"

    FIRST_SECTOR=2048

    if [ "$SWAP_MODE" != "NONE" ]; then

        SWAP_BYTES="$(numfmt --from=iec "$SWAP_SIZE")"
        SWAP_SECTORS=$((SWAP_BYTES / 512))

        [ "$SWAP_SECTORS" -gt 0 ] ||
            die "Invalid swap size."

        SWAP_START="$FIRST_SECTOR"
        ROOT_START=$((SWAP_START + SWAP_SECTORS))

        ROOT_SIZE=$((DISK_SECTORS - ROOT_START))

        [ "$ROOT_SIZE" -gt 2048 ] ||
            die "Not enough space for root partition."

        sfdisk "$DISK" <<EOF
label: dos
unit: sectors

start=$SWAP_START,size=$SWAP_SECTORS,type=82
start=$ROOT_START,size=$ROOT_SIZE,type=83,bootable
EOF

        case "$DISK" in
            /dev/nvme*|/dev/mmcblk*)
                SWAP="${DISK}p1"
                ROOT="${DISK}p2"
                ;;
            *)
                SWAP="${DISK}1"
                ROOT="${DISK}2"
                ;;
        esac

    else

        sfdisk "$DISK" <<EOF
label: dos
unit: sectors

start=$FIRST_SECTOR,type=83,bootable
EOF

        case "$DISK" in
            /dev/nvme*|/dev/mmcblk*)
                ROOT="${DISK}p1"
                ;;
            *)
                ROOT="${DISK}1"
                ;;
        esac

    fi

    sync

    partprobe "$DISK" 2>/dev/null || true
    sleep 2

    [ -b "$ROOT" ] ||
        die "Root partition not found: $ROOT"

    if [ "$SWAP_MODE" != "NONE" ]; then
        [ -b "$SWAP" ] ||
            die "Swap partition not found: $SWAP"
    fi

    if [ "$SWAP_MODE" != "NONE" ]; then
        info "Formatting swap..."
        mkswap "$SWAP"
    fi

    info "Formatting root..."

    mkfs.ext4 -F "$ROOT"

fi

success "Partitioning complete."

# ==================================================
# Mount
# ==================================================

clear

echo "${BOLD}11. Mounting${RESET}"
echo

mkdir -p /media/root

info "Mounting root..."

mount "$ROOT" /media/root

if [ "$BOOTMODE" = "UEFI" ]; then

    mkdir -p /media/root/boot/efi

    info "Mounting EFI..."

    mount "$ESP" /media/root/boot/efi

fi

success "Filesystems mounted."

# ==================================================
# Bootstrap
# ==================================================

clear

echo "${BOLD}12. Installing Chimera${RESET}"
echo

info "Bootstrapping Chimera Linux..."

chimera-bootstrap /media/root

success "Base system installed."

# ==================================================
# Repository configuration
# ==================================================

info "Configuring repository..."

mkdir -p /media/root/etc/apk/repositories.d

cat > /media/root/etc/apk/repositories.d/00-kolon-installer.list <<EOF
set CHIMERA_REPO_URL=$MIRROR
EOF

success "Repository configured."

# ==================================================
# Update
# ==================================================

info "Updating package database..."

chimera-chroot /media/root /bin/sh <<'EOF'
set -e

apk update
apk upgrade --available
EOF

# ==================================================
# Packages
# ==================================================

info "Installing kernel and utilities..."

chimera-chroot /media/root /bin/sh <<EOF
set -e

apk add \
    "$KERNEL" \
    opendoas \
    bash \
    nano \
    curl \
    wget \
    git
EOF

success "Base packages installed."

# ==================================================
# Doas
# ==================================================

info "Configuring doas..."

cat > /media/root/etc/doas.conf <<EOF
permit persist :wheel
EOF

chmod 600 /media/root/etc/doas.conf

success "doas configured."

# ==================================================
# Hostname
# ==================================================

info "Setting hostname..."

printf '%s\n' "$HOSTNAME" > /media/root/etc/hostname

# ==================================================
# User
# ==================================================

info "Creating user..."

# Pass passwords through environment instead of putting
# them directly into the shell command line.
USERPASS="$USERPASS" ROOTPASS="$ROOTPASS" \
USERNAME="$USERNAME" \
chimera-chroot /media/root /bin/sh <<'EOF'
set -e

echo "root:$ROOTPASS" | chpasswd

if ! id "$USERNAME" >/dev/null 2>&1; then
    adduser -D -s /bin/bash "$USERNAME"
fi

echo "$USERNAME:$USERPASS" | chpasswd

addgroup "$USERNAME" wheel 2>/dev/null || true
addgroup "$USERNAME" network 2>/dev/null || true
addgroup "$USERNAME" audio 2>/dev/null || true
addgroup "$USERNAME" video 2>/dev/null || true
EOF

success "User configured."

# ==================================================
# fstab
# ==================================================

info "Creating /etc/fstab..."

ROOT_UUID="$(blkid -s UUID -o value "$ROOT")"

[ -n "$ROOT_UUID" ] ||
    die "Could not determine root UUID."

cat > /media/root/etc/fstab <<EOF
UUID=$ROOT_UUID    /    ext4    defaults    0 1
EOF

if [ "$BOOTMODE" = "UEFI" ]; then

    EFI_UUID="$(blkid -s UUID -o value "$ESP")"

    [ -n "$EFI_UUID" ] ||
        die "Could not determine EFI UUID."

    cat >> /media/root/etc/fstab <<EOF
UUID=$EFI_UUID    /boot/efi    vfat    defaults    0 2
EOF

fi

if [ "$SWAP_MODE" != "NONE" ]; then

    SWAP_UUID="$(blkid -s UUID -o value "$SWAP")"

    [ -n "$SWAP_UUID" ] ||
        die "Could not determine swap UUID."

    cat >> /media/root/etc/fstab <<EOF
UUID=$SWAP_UUID    none    swap    defaults    0 0
EOF

fi

success "fstab configured."

# ==================================================
# Desktop
# ==================================================

if [ -n "$DESKTOP" ]; then

    info "Installing desktop environment..."

    # Split package list safely.
    chimera-chroot /media/root /bin/sh -c \
        "apk add $DESKTOP"

    success "Desktop environment installed."

fi

# ==================================================
# Hibernation
# ==================================================

if [ "$SWAP_MODE" = "HIBERNATE" ]; then

    SWAP_UUID="$(blkid -s UUID -o value "$SWAP")"

    [ -n "$SWAP_UUID" ] ||
        die "Could not determine swap UUID."

    info "Configuring hibernation..."

    mkdir -p /media/root/etc/default

    if [ -f /media/root/etc/default/grub ]; then

        if grep -q '^GRUB_CMDLINE_LINUX_DEFAULT=' \
            /media/root/etc/default/grub; then

            sed -i \
                "s|^GRUB_CMDLINE_LINUX_DEFAULT=.*|GRUB_CMDLINE_LINUX_DEFAULT=\"resume=UUID=$SWAP_UUID\"|" \
                /media/root/etc/default/grub

        else

            printf '%s\n' \
                "GRUB_CMDLINE_LINUX_DEFAULT=\"resume=UUID=$SWAP_UUID\"" \
                >> /media/root/etc/default/grub

        fi

    else

        cat > /media/root/etc/default/grub <<EOF
GRUB_CMDLINE_LINUX_DEFAULT="resume=UUID=$SWAP_UUID"
EOF

    fi

    success "Hibernation configured."

fi

# ==================================================
# Initramfs
# ==================================================

info "Generating initramfs..."

chimera-chroot /media/root /bin/sh <<'EOF'
set -e

update-initramfs -c -k all
EOF

success "Initramfs generated."

# ==================================================
# GRUB
# ==================================================

info "Installing GRUB..."

if [ "$BOOTMODE" = "UEFI" ]; then

    chimera-chroot /media/root /bin/sh <<'EOF'
set -e

apk add grub-x86_64-efi

grub-install \
    --target=x86_64-efi \
    --efi-directory=/boot/efi \
    --bootloader-id=Chimera

update-grub
EOF

else

    chimera-chroot /media/root /bin/sh <<EOF
set -e

apk add grub-i386-pc

grub-install \
    --target=i386-pc \
    "$DISK"

update-grub
EOF

fi

success "GRUB installed."

# ==================================================
# Final filesystem sync
# ==================================================

info "Syncing filesystem..."

sync

info "Unmounting..."

umount -R /media/root 2>/dev/null || true

sync

# ==================================================
# Complete
# ==================================================

clear

echo "${BOLD}${GREEN}"
echo "╔════════════════════════════════════════════╗"
echo "║          INSTALLATION COMPLETE             ║"
echo "╚════════════════════════════════════════════╝"
echo "${RESET}"

echo
echo "Chimera Linux installation finished."
echo
echo "Architecture: $ARCH"
echo "Boot mode:    $BOOTMODE"
echo "Disk:         $DISK"

if [ "$SWAP_MODE" = "NONE" ]; then
    echo "Swap:         disabled"
elif [ "$SWAP_MODE" = "SWAP" ]; then
    echo "Swap:         $SWAP_SIZE"
    echo "Hibernation:  disabled"
else
    echo "Swap:         $SWAP_SIZE"
    echo "Hibernation:  enabled"
fi

echo
echo "Hostname:     $HOSTNAME"
echo "Username:     $USERNAME"
echo "Kernel:       $KERNEL"
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
