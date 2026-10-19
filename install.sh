#!/bin/sh
#
# Kolon Chimera Linux Installer
# Simple interactive installer for Chimera Linux
#

set -eu

VERSION="0.1.1"

# --------------------------------------------------
# Colors
# --------------------------------------------------

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

# --------------------------------------------------
# Functions
# --------------------------------------------------

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

# IMPORTANT:
# The prompt goes to stderr.
# This prevents command substitution from putting
# the prompt text into variables.
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

# --------------------------------------------------
# Root check
# --------------------------------------------------

if [ "$(id -u)" != "0" ]; then
    die "Please run this installer as root."
fi

# --------------------------------------------------
# Header
# --------------------------------------------------

clear

echo "${BOLD}${CYAN}"
echo "╔════════════════════════════════════════════╗"
echo "║       Kolon Chimera Linux Installer        ║"
echo "║                  v$VERSION                 ║"
echo "╚════════════════════════════════════════════╝"
echo "${RESET}"

echo "Simple interactive installer for Chimera Linux."
echo
echo "The installer will configure:"
echo "  • Installation disk"
echo "  • Partitioning"
echo "  • PC name"
echo "  • User account"
echo "  • User password"
echo "  • Root password"
echo "  • Repository"
echo "  • Kernel"
echo "  • Bootloader"
echo "  • Desktop environment"
echo

pause

# --------------------------------------------------
# Internet
# --------------------------------------------------

clear

echo "${BOLD}Network${RESET}"
echo

info "Checking internet connection..."

if command -v ping >/dev/null 2>&1 &&
   ping -c 1 -W 3 repo.chimera-linux.org >/dev/null 2>&1; then
    success "Internet connection works."
else
    warning "Could not verify internet access."
    echo "Make sure you have a working network connection."
fi

pause

# --------------------------------------------------
# Disk
# --------------------------------------------------

clear

echo "${BOLD}1. Installation disk${RESET}"
echo
echo "Available disks:"
echo

lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINTS

echo

DISK=$(ask "Enter installation disk (example: /dev/sda): ")

# Remove accidental whitespace
DISK=$(printf '%s' "$DISK" | tr -d '[:space:]')

[ -b "$DISK" ] || die "The selected disk does not exist: $DISK"

echo
success "Selected disk: $DISK"
echo

warning "Automatic partitioning will erase the selected disk."
echo

if ! yesno "Use $DISK?"; then
    echo "Installation cancelled."
    exit 0
fi

# --------------------------------------------------
# Partitioning
# --------------------------------------------------

clear

echo "${BOLD}2. Disk partitioning${RESET}"
echo
echo "Choose how to prepare the disk:"
echo
echo "  1) Automatic"
echo "     GPT + EFI + root"
echo
echo "  2) Existing partitions"
echo "     Use partitions that already exist"
echo

PARTMODE=$(ask "Choice [1-2]: ")
PARTMODE=$(printf '%s' "$PARTMODE" | tr -d '[:space:]')

case "$PARTMODE" in

    1)
        echo
        warning "Automatic partitioning will erase $DISK."
        echo

        if ! yesno "Are you absolutely sure?"; then
            echo "Installation cancelled."
            exit 0
        fi

        command -v sgdisk >/dev/null 2>&1 ||
            die "sgdisk is required for automatic partitioning."

        command -v mkfs.vfat >/dev/null 2>&1 ||
            die "mkfs.vfat is required."

        command -v mkfs.ext4 >/dev/null 2>&1 ||
            die "mkfs.ext4 is required."

        info "Creating GPT partition table..."

        sgdisk --zap-all "$DISK"
        sgdisk -n 1:0:+512M -t 1:ef00 "$DISK"
        sgdisk -n 2:0:0 -t 2:8300 "$DISK"

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

        info "Waiting for kernel to detect partitions..."

        if command -v partprobe >/dev/null 2>&1; then
            partprobe "$DISK" || true
        fi

        sleep 2

        info "Formatting EFI partition..."
        mkfs.vfat -F32 "$ESP"

        info "Formatting root partition..."
        mkfs.ext4 -F "$ROOT"

        success "Disk prepared."
        ;;

    2)
        echo
        echo "Existing partitions:"
        echo

        lsblk -f

        echo

        ESP=$(ask "EFI partition: ")
        ROOT=$(ask "Root partition: ")

        ESP=$(printf '%s' "$ESP" | tr -d '[:space:]')
        ROOT=$(printf '%s' "$ROOT" | tr -d '[:space:]')

        [ -b "$ESP" ] || die "EFI partition does not exist: $ESP"
        [ -b "$ROOT" ] || die "Root partition does not exist: $ROOT"

        success "Existing partitions selected."
        ;;

    *)
        die "Invalid choice."
        ;;
esac

pause

# --------------------------------------------------
# Hostname
# --------------------------------------------------

clear

echo "${BOLD}3. PC name${RESET}"
echo
echo "This is the hostname of your computer."
echo

HOSTNAME=$(ask "PC name [chimera]: ")
HOSTNAME=${HOSTNAME:-chimera}

case "$HOSTNAME" in
    *[!a-zA-Z0-9_-]*)
        die "PC name may contain only letters, numbers, '-' and '_'."
        ;;
esac

# --------------------------------------------------
# User
# --------------------------------------------------

clear

echo "${BOLD}4. User account${RESET}"
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

[ -n "$USERPASS" ] || die "User password cannot be empty."

printf "Repeat user password: "
stty -echo
read -r USERPASS2
stty echo
echo

[ "$USERPASS" = "$USERPASS2" ] ||
    die "User passwords do not match."

# --------------------------------------------------
# Root password
# --------------------------------------------------

echo

printf "Root password: "
stty -echo
read -r ROOTPASS
stty echo
echo

[ -n "$ROOTPASS" ] || die "Root password cannot be empty."

printf "Repeat root password: "
stty -echo
read -r ROOTPASS2
stty echo
echo

[ "$ROOTPASS" = "$ROOTPASS2" ] ||
    die "Root passwords do not match."

# --------------------------------------------------
# Repository
# --------------------------------------------------

clear

echo "${BOLD}5. Repository${RESET}"
echo
echo "Choose a Chimera Linux mirror:"
echo
echo "  1) Official"
echo "     Prague"
echo
echo "  2) Warsaw"
echo
echo "  3) Umea"
echo
echo "  4) Brisbane"
echo
echo "  5) Hanoi"
echo
echo "  6) Custom URL"
echo

REPOCHOICE=$(ask "Choice [1-6]: ")
REPOCHOICE=$(printf '%s' "$REPOCHOICE" | tr -d '[:space:]')

case "$REPOCHOICE" in
    1)
        MIRROR="https://repo.chimera-linux.org"
        ;;
    2)
        MIRROR="https://chimera.sakamoto.pl"
        ;;
    3)
        MIRROR="https://mirror.accum.se/mirror/chimera-linux.org"
        ;;
    4)
        MIRROR="https://au.mirror.7bit.org/chimera"
        ;;
    5)
        MIRROR="https://mirror.meowsmp.net/chimera-linux"
        ;;
    6)
        MIRROR=$(ask "Repository URL: ")
        MIRROR=$(printf '%s' "$MIRROR" | tr -d '[:space:]')

        [ -n "$MIRROR" ] ||
            die "Repository URL cannot be empty."
        ;;
    *)
        die "Invalid repository choice."
        ;;
esac

# --------------------------------------------------
# Kernel
# --------------------------------------------------

clear

echo "${BOLD}6. Kernel${RESET}"
echo

echo "  1) linux-lts"
echo "     Long-term support kernel"
echo
echo "  2) linux-stable"
echo "     Current stable kernel"
echo

KERNELCHOICE=$(ask "Choice [1-2]: ")
KERNELCHOICE=$(printf '%s' "$KERNELCHOICE" | tr -d '[:space:]')

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

# --------------------------------------------------
# Bootloader
# --------------------------------------------------

clear

echo "${BOLD}7. Bootloader${RESET}"
echo

if [ -d /sys/firmware/efi ]; then
    BOOTMODE="UEFI"
    echo "Detected boot mode: UEFI"
else
    BOOTMODE="BIOS"
    echo "Detected boot mode: BIOS/Legacy"
fi

echo

echo "  1) GRUB"
echo "  2) systemd-boot"
echo

BOOT=$(ask "Choice [1-2]: ")
BOOT=$(printf '%s' "$BOOT" | tr -d '[:space:]')

if [ "$BOOTMODE" = "BIOS" ] && [ "$BOOT" = "2" ]; then
    die "systemd-boot requires UEFI."
fi

case "$BOOT" in
    1|2)
        ;;
    *)
        die "Invalid bootloader choice."
        ;;
esac

# --------------------------------------------------
# Desktop
# --------------------------------------------------

clear

echo "${BOLD}8. Desktop environment${RESET}"
echo

echo "  1) None"
echo "  2) GNOME"
echo "  3) KDE Plasma"
echo "  4) XFCE"
echo "  5) Sway"
echo

DESKTOP=$(ask "Choice [1-5]: ")
DESKTOP=$(printf '%s' "$DESKTOP" | tr -d '[:space:]')

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

# --------------------------------------------------
# Summary
# --------------------------------------------------

clear

echo "${BOLD}${CYAN}"
echo "╔════════════════════════════════════════════╗"
echo "║             INSTALLATION SUMMARY           ║"
echo "╚════════════════════════════════════════════╝"
echo "${RESET}"

echo
echo "Disk:        $DISK"
echo "EFI:         $ESP"
echo "Root:        $ROOT"
echo
echo "PC name:     $HOSTNAME"
echo "Username:    $USERNAME"
echo "Repository:  $MIRROR"
echo "Kernel:      $KERNEL"

if [ "$BOOT" = "1" ]; then
    echo "Bootloader:  GRUB"
else
    echo "Bootloader:  systemd-boot"
fi

if [ -n "$DESKTOP_PACKAGE" ]; then
    echo "Desktop:     $DESKTOP_PACKAGE"
else
    echo "Desktop:     None"
fi

echo
echo "Passwords:   configured"
echo

warning "The installation will now modify the selected disk."
echo

if ! yesno "Start installation?"; then
    echo "Installation cancelled."
    exit 0
fi

# --------------------------------------------------
# Mount
# --------------------------------------------------

clear

info "Mounting root filesystem..."

mkdir -p /media/root

mount "$ROOT" /media/root

mkdir -p /media/root/boot/efi

if [ "$BOOTMODE" = "UEFI" ]; then
    mount "$ESP" /media/root/boot/efi
fi

success "Filesystem mounted."

# --------------------------------------------------
# Bootstrap
# --------------------------------------------------

info "Bootstrapping Chimera Linux..."

chimera-bootstrap -l /media/root

success "Base system installed."

# --------------------------------------------------
# Repository
# --------------------------------------------------

info "Configuring repository mirror..."

mkdir -p /media/root/etc/apk/repositories.d

cat > /media/root/etc/apk/repositories.d/00-kolon-installer.list <<EOF
set CHIMERA_REPO_URL=$MIRROR
EOF

success "Repository configured."

# --------------------------------------------------
# Basic packages
# --------------------------------------------------

info "Updating package database..."

chimera-chroot /media/root /bin/sh <<EOF
set -e

apk update
apk upgrade --available
EOF

info "Installing basic packages..."

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

# --------------------------------------------------
# Remove live-only package
# --------------------------------------------------

info "Removing live-only components..."

chimera-chroot /media/root /bin/sh <<EOF
apk del base-live || true
EOF

# --------------------------------------------------
# Desktop
# --------------------------------------------------

if [ -n "$DESKTOP_PACKAGE" ]; then

    info "Installing $DESKTOP_PACKAGE..."

    chimera-chroot /media/root /bin/sh <<EOF
set -e
apk add $DESKTOP_PACKAGE
EOF

    success "Desktop installed."
fi

# --------------------------------------------------
# User
# --------------------------------------------------

info "Creating user account..."

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

success "User account configured."

# --------------------------------------------------
# Initramfs
# --------------------------------------------------

info "Generating initramfs..."

chimera-chroot /media/root /bin/sh <<EOF
set -e
update-initramfs -c -k all
EOF

success "Initramfs generated."

# --------------------------------------------------
# Bootloader
# --------------------------------------------------

if [ "$BOOT" = "1" ]; then

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

grub-install "$DISK"

update-grub
EOF

    fi

    success "GRUB installed."

elif [ "$BOOT" = "2" ]; then

    info "Installing systemd-boot..."

    chimera-chroot /media/root /bin/sh <<EOF
set -e

apk add systemd-boot
bootctl install
EOF

    success "systemd-boot installed."

fi

# --------------------------------------------------
# Sync
# --------------------------------------------------

info "Writing changes to disk..."

sync

# --------------------------------------------------
# Unmount
# --------------------------------------------------

info "Unmounting filesystem..."

umount -R /media/root 2>/dev/null || true

# --------------------------------------------------
# Finish
# --------------------------------------------------

clear

echo "${BOLD}${GREEN}"
echo "╔════════════════════════════════════════════╗"
echo "║          INSTALLATION COMPLETE             ║"
echo "╚════════════════════════════════════════════╝"
echo "${RESET}"

echo
echo "Chimera Linux has been installed."
echo
echo "PC name:  $HOSTNAME"
echo "User:     $USERNAME"
echo "Kernel:   $KERNEL"
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
