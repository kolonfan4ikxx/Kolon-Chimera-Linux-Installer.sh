#!/bin/sh
#
# Kolon Chimera Linux Installer
# UEFI: GPT + EFI
# BIOS: MBR
#

set -eu

VERSION="0.3.0"

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

# Prompt is printed to stderr so command substitution
# receives only the user's answer.
ask() {
    printf "%s" "$1" >&2
    read -r ANSWER
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

if [ "$(id -u)" != "0" ]; then
    die "Please run this installer as root."
fi

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
echo "Simple interactive installer for Chimera Linux."
echo
echo "Supported:"
echo "  • UEFI → GPT + EFI"
echo "  • BIOS → MBR"
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

BOOTMODE=$(ask "Choice [1-2]: ")

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

echo
success "Selected boot mode: $BOOTMODE"

pause

# ==================================================
# Network
# ==================================================

clear

echo "${BOLD}2. Network${RESET}"
echo

info "Checking internet connection..."

if command -v ping >/dev/null 2>&1 &&
   ping -c 1 -W 3 repo.chimera-linux.org >/dev/null 2>&1; then
    success "Internet connection works."
else
    warning "Could not verify internet access."
    echo "Make sure your network connection works."
fi

pause

# ==================================================
# Disk
# ==================================================

clear

echo "${BOLD}3. Installation disk${RESET}"
echo

echo "Available disks:"
echo

lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINTS

echo

DISK=$(ask "Installation disk (example: /dev/sdc): ")

# Remove whitespace accidentally entered around path.
DISK=$(printf '%s' "$DISK" | tr -d '[:space:]')

[ -b "$DISK" ] ||
    die "The selected disk does not exist: $DISK"

echo
success "Selected disk: $DISK"
echo

warning "ALL DATA ON $DISK WILL BE DESTROYED."
echo

if ! yesno "Use $DISK?"; then
    echo "Installation cancelled."
    exit 0
fi

# ==================================================
# Partitioning
# ==================================================

clear

echo "${BOLD}4. Partitioning${RESET}"
echo

command -v fdisk >/dev/null 2>&1 ||
    die "fdisk is required."

command -v mkfs.ext4 >/dev/null 2>&1 ||
    die "mkfs.ext4 is required."

if [ "$BOOTMODE" = "UEFI" ]; then

    command -v sgdisk >/dev/null 2>&1 ||
        die "sgdisk is required for GPT partitioning."

    if command -v mkfs.vfat >/dev/null 2>&1; then
        MKFS_VFAT="mkfs.vfat"
    elif command -v mkfs.fat >/dev/null 2>&1; then
        MKFS_VFAT="mkfs.fat"
    else
        die "mkfs.vfat or mkfs.fat is required."
    fi

    echo "UEFI layout:"
    echo
    echo "  $DISK"
    echo "  ├── 512 MiB EFI System Partition"
    echo "  └── ext4 root"
    echo

    warning "Automatic partitioning will erase $DISK."
    echo

    if ! yesno "Continue?"; then
        echo "Installation cancelled."
        exit 0
    fi

    info "Creating GPT partition table..."

    sgdisk --zap-all "$DISK"

    sgdisk \
        -n 1:0:+512M \
        -t 1:ef00 \
        -c 1:"EFI System Partition" \
        "$DISK"

    sgdisk \
        -n 2:0:0 \
        -t 2:8300 \
        -c 2:"Chimera Linux root" \
        "$DISK"

    sync

    case "$DISK" in
        /dev/nvme*|/dev/mmcblk*)
            ESP="${DISK}p1"
            ROOT="${DISK}p2"
            ;;
        *)
            ESP="${DISK}1"
            ROOT="${DISK}2"
            ;;
    esac

    if command -v partprobe >/dev/null 2>&1; then
        partprobe "$DISK" || true
    fi

    sleep 2

    [ -b "$ESP" ] ||
        die "EFI partition was not created: $ESP"

    [ -b "$ROOT" ] ||
        die "Root partition was not created: $ROOT"

    info "Formatting EFI partition..."

    "$MKFS_VFAT" -F 32 "$ESP"

    info "Formatting root partition..."

    mkfs.ext4 -F "$ROOT"

    success "GPT + EFI partitioning complete."

else

    echo "BIOS layout:"
    echo
    echo "  $DISK"
    echo "  ├── MBR"
    echo "  └── ext4 root"
    echo

    warning "Automatic partitioning will erase $DISK."
    echo

    if ! yesno "Continue?"; then
        echo "Installation cancelled."
        exit 0
    fi

    info "Creating MBR / DOS partition table..."

    fdisk "$DISK" <<EOF
o
n
p
1


a
1
w
EOF

    sync

    case "$DISK" in
        /dev/nvme*|/dev/mmcblk*)
            ROOT="${DISK}p1"
            ;;
        *)
            ROOT="${DISK}1"
            ;;
    esac

    if command -v partprobe >/dev/null 2>&1; then
        partprobe "$DISK" || true
    fi

    sleep 2

    [ -b "$ROOT" ] ||
        die "Root partition was not created: $ROOT"

    info "Formatting root partition..."

    mkfs.ext4 -F "$ROOT"

    success "MBR partitioning complete."

fi

pause

# ==================================================
# Hostname
# ==================================================

clear

echo "${BOLD}5. PC name${RESET}"
echo

HOSTNAME=$(ask "PC name [chimera]: ")
HOSTNAME=${HOSTNAME:-chimera}

case "$HOSTNAME" in
    *[!a-zA-Z0-9_-]*)
        die "PC name may contain only letters, numbers, '-' and '_'."
        ;;
esac

# ==================================================
# User
# ==================================================

clear

echo "${BOLD}6. User account${RESET}"
echo

USERNAME=$(ask "Username [kolon]: ")
USERNAME=${USERNAME:-kolon}

case "$USERNAME" in
    *[!a-zA-Z0-9_-]*)
        die "Username may contain only letters, numbers, '-' and '_'."
        ;;
esac

echo

printf "User password: "
stty -echo
read -r USERPASS
stty echo
echo

[ -n "$USERPASS" ] ||
    die "User password cannot be empty."

printf "Repeat user password: "
stty -echo
read -r USERPASS2
stty echo
echo

[ "$USERPASS" = "$USERPASS2" ] ||
    die "User passwords do not match."

# ==================================================
# Root password
# ==================================================

echo

printf "Root password: "
stty -echo
read -r ROOTPASS
stty echo
echo

[ -n "$ROOTPASS" ] ||
    die "Root password cannot be empty."

printf "Repeat root password: "
stty -echo
read -r ROOTPASS2
stty echo
echo

[ "$ROOTPASS" = "$ROOTPASS2" ] ||
    die "Root passwords do not match."

# ==================================================
# Repository
# ==================================================

clear

echo "${BOLD}7. Repository${RESET}"
echo

echo "  1) Official Chimera repository"
echo "  2) Custom repository URL"
echo

REPO=$(ask "Choice [1-2]: ")

case "$REPO" in
    1)
        MIRROR="https://repo.chimera-linux.org"
        ;;
    2)
        MIRROR=$(ask "Repository URL: ")

        [ -n "$MIRROR" ] ||
            die "Repository URL cannot be empty."
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
echo "     Long-term support kernel"
echo

echo "  2) linux-stable"
echo "     Current stable kernel"
echo

KERNELCHOICE=$(ask "Choice [1-2]: ")

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
echo "  2) GNOME"
echo "  3) KDE Plasma"
echo "  4) XFCE"
echo "  5) Sway"
echo

DESKTOP=$(ask "Choice [1-5]: ")

case "$DESKTOP" in
    1)
        DESKTOP_PACKAGE=""
        ;;
    2)
        DESKTOP_PACKAGE="gnome"
        ;;
    3)
        DESKTOP_PACKAGE="kde"
        ;;
    4)
        DESKTOP_PACKAGE="xfce"
        ;;
    5)
        DESKTOP_PACKAGE="sway"
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
echo "Boot mode:   $BOOTMODE"

if [ "$BOOTMODE" = "UEFI" ]; then
    echo "Partition:   GPT"
    echo "EFI:         $ESP"
else
    echo "Partition:   MBR / DOS"
fi

echo "Root:        $ROOT"
echo "Disk:        $DISK"
echo
echo "PC name:     $HOSTNAME"
echo "Username:    $USERNAME"
echo "Repository:  $MIRROR"
echo "Kernel:      $KERNEL"
echo "Bootloader:  GRUB"

if [ -n "$DESKTOP_PACKAGE" ]; then
    echo "Desktop:     $DESKTOP_PACKAGE"
else
    echo "Desktop:     None"
fi

echo
echo "Passwords:   configured"
echo

warning "The selected disk will be erased."
echo

if ! yesno "Start installation?"; then
    echo "Installation cancelled."
    exit 0
fi

# ==================================================
# Mount
# ==================================================

clear

info "Mounting root filesystem..."

mkdir -p /media/root

mount "$ROOT" /media/root

if [ "$BOOTMODE" = "UEFI" ]; then
    mkdir -p /media/root/boot/efi
    mount "$ESP" /media/root/boot/efi
fi

success "Filesystem mounted."

# ==================================================
# Bootstrap
# ==================================================

info "Bootstrapping Chimera Linux..."

chimera-bootstrap -l /media/root

success "Base Chimera Linux installed."

# ==================================================
# Repository
# ==================================================

info "Configuring repository..."

mkdir -p /media/root/etc/apk/repositories.d

cat > /media/root/etc/apk/repositories.d/00-kolon-installer.list <<EOF
set CHIMERA_REPO_URL=$MIRROR
EOF

success "Repository configured."

# ==================================================
# Base packages
# ==================================================

info "Updating package database..."

chimera-chroot /media/root /bin/sh <<EOF
set -e

apk update
apk upgrade --available
EOF

info "Installing kernel and basic tools..."

chimera-chroot /media/root /bin/sh <<EOF
set -e

apk add \
    $KERNEL \
    bash \
    nano \
    curl \
    wget \
    git \
    sudo \
    doas
EOF

success "Basic packages installed."

# ==================================================
# Desktop
# ==================================================

if [ -n "$DESKTOP_PACKAGE" ]; then

    info "Installing $DESKTOP_PACKAGE..."

    chimera-chroot /media/root /bin/sh <<EOF
set -e

apk add $DESKTOP_PACKAGE
EOF

    success "Desktop installed."

fi

# ==================================================
# User
# ==================================================

info "Configuring hostname and users..."

chimera-chroot /media/root /bin/sh <<EOF
set -e

echo "$HOSTNAME" > /etc/hostname

echo "root:$ROOTPASS" | chpasswd

adduser -D -s /bin/bash "$USERNAME"
echo "$USERNAME:$USERPASS" | chpasswd

addgroup "$USERNAME" wheel
addgroup "$USERNAME" video
addgroup "$USERNAME" audio
EOF

success "Users configured."

# ==================================================
# Initramfs
# ==================================================

info "Generating initramfs..."

chimera-chroot /media/root /bin/sh <<EOF
set -e

update-initramfs -c -k all
EOF

success "Initramfs generated."

# ==================================================
# GRUB
# ==================================================

info "Installing GRUB..."

if [ "$BOOTMODE" = "UEFI" ]; then

    chimera-chroot /media/root /bin/sh <<EOF
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
# Finish
# ==================================================

info "Syncing filesystem..."

sync

info "Unmounting filesystem..."

umount -R /media/root 2>/dev/null || true

clear

echo "${BOLD}${GREEN}"
echo "╔════════════════════════════════════════════╗"
echo "║          INSTALLATION COMPLETE             ║"
echo "╚════════════════════════════════════════════╝"
echo "${RESET}"

echo
echo "Chimera Linux has been installed."
echo
echo "Boot mode:  $BOOTMODE"
echo "Disk:       $DISK"
echo "Root:       $ROOT"
echo "PC name:    $HOSTNAME"
echo "User:       $USERNAME"
echo "Kernel:     $KERNEL"
echo

warning "Remove the installation USB before rebooting."
echo

if yesno "Reboot now?"; then
    reboot
else
    echo
    echo "You can reboot later with:"
    echo
    echo "    reboot"
fi
