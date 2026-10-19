#!/bin/sh
#
# Kolon Chimera Linux Installer
# Simple, friendly installer for Chimera Linux
#

set -eu

VERSION="0.1.0"

# --------------------------------------------------
# Colors
# --------------------------------------------------

if [ -t 1 ]; then
    RED="$(printf '\033[31m')"
    GREEN="$(printf '\033[32m')"
    YELLOW="$(printf '\033[33m')"
    BLUE="$(printf '\033[34m')"
    CYAN="$(printf '\033[36m')"
    BOLD="$(printf '\033[1m')"
    RESET="$(printf '\033[0m')"
else
    RED=""
    GREEN=""
    YELLOW=""
    BLUE=""
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

ask() {
    printf "%s" "$1"
    read -r ANSWER
    printf "%s" "$ANSWER"
}

yesno() {
    while true; do
        printf "%s [y/N]: " "$1"
        read -r ANSWER

        case "$ANSWER" in
            y|Y|yes|YES)
                return 0
                ;;
            n|N|no|NO|"")
                return 1
                ;;
            *)
                echo "Please answer yes or no."
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

echo "A simple installer for Chimera Linux."
echo
echo "This installer will help you configure:"
echo "  • Disk"
echo "  • Hostname"
echo "  • User account"
echo "  • Passwords"
echo "  • Repository"
echo "  • Kernel"
echo "  • Bootloader"
echo "  • Desktop environment"
echo

# --------------------------------------------------
# Internet
# --------------------------------------------------

info "Checking internet connection..."

if command -v ping >/dev/null 2>&1 &&
   ping -c 1 -W 3 repo.chimera-linux.org >/dev/null 2>&1; then
    success "Internet connection works."
else
    warning "Could not verify internet access."
    echo "The installation may fail if the network is unavailable."
fi

pause

# --------------------------------------------------
# Disk selection
# --------------------------------------------------

clear

echo "${BOLD}1. Installation disk${RESET}"
echo
echo "Available disks:"
echo

lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINTS

echo

DISK=$(ask "Enter installation disk (example: /dev/sda): ")

[ -b "$DISK" ] || die "The selected disk does not exist."

echo
warning "Everything on the selected disk may be erased."
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
echo "     Creates GPT + EFI + root."
echo
echo "  2) Existing partitions"
echo "     Use partitions you already created."
echo

PARTMODE=$(ask "Choice [1-2]: ")

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

        info "Formatting EFI partition..."
        mkfs.fat -F32 "$ESP"

        info "Formatting root partition..."
        mkfs.ext4 -F "$ROOT"

        success "Disk prepared."
        ;;

    2)
        echo
        lsblk -f
        echo

        ESP=$(ask "EFI partition: ")
        ROOT=$(ask "Root partition: ")

        [ -b "$ESP" ] || die "EFI partition does not exist."
        [ -b "$ROOT" ] || die "Root partition does not exist."

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
echo "This is the name your computer will use on the network."
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

echo
printf "Repeat user password: "
stty -echo
read -r USERPASS2
stty echo
echo

[ "$USERPASS" = "$USERPASS2" ] ||
    die "Passwords do not match."

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

echo
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
echo "Choose a repository source."
echo
echo "  1) Official Chimera repository"
echo "  2) Custom repository URL"
echo

REPOCHOICE=$(ask "Choice [1-2]: ")

case "$REPOCHOICE" in
    1)
        MIRROR="https://repo.chimera-linux.org"
        ;;
    2)
        MIRROR=$(ask "Repository URL: ")

        [ -n "$MIRROR" ] ||
            die "Repository URL cannot be empty."
        ;;
    *)
        die "Invalid choice."
        ;;
esac

# --------------------------------------------------
# Kernel
# --------------------------------------------------

clear

echo "${BOLD}6. Kernel${RESET}"
echo
echo "  1) linux-lts"
echo "     Long-term support kernel."
echo
echo "  2) linux-stable"
echo "     Current stable kernel."
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
        die "Invalid kernel."
        ;;
esac

# --------------------------------------------------
# Bootloader
# --------------------------------------------------

clear

echo "${BOLD}7. Bootloader${RESET}"
echo

echo "Detected boot mode:"
if [ -d /sys/firmware/efi ]; then
    echo "  UEFI"
    BOOTMODE="UEFI"
else
    echo "  BIOS/Legacy"
    BOOTMODE="BIOS"
fi

echo
echo "  1) GRUB"
echo "  2) systemd-boot (UEFI only)"
echo

BOOT=$(ask "Choice [1-2]: ")

if [ "$BOOTMODE" = "BIOS" ] && [ "$BOOT" = "2" ]; then
    die "systemd-boot requires UEFI."
fi

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
echo "║             Installation summary           ║"
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
echo "Bootloader:  $([ "$BOOT" = "1" ] && echo "GRUB" || echo "systemd-boot")"
echo "Desktop:     ${DESKTOP_PACKAGE:-None}"
echo
echo "Passwords:   configured"
echo

echo "${YELLOW}The actual installation starts after confirmation.${RESET}"
echo

if ! yesno "Start installation?"; then
    echo "Installation cancelled."
    exit 0
fi

# --------------------------------------------------
# Mount filesystem
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

info "Installing base Chimera Linux system..."

chimera-bootstrap -l /media/root

success "Base system installed."

# --------------------------------------------------
# Repository configuration
# --------------------------------------------------

info "Configuring repository..."

mkdir -p /media/root/etc/apk/repositories.d

cat > /media/root/etc/apk/repositories.d/00-kolon-installer.list <<EOF
$MIRROR/current
EOF

# --------------------------------------------------
# Packages
# --------------------------------------------------

info "Installing basic packages..."

chimera-chroot /media/root /bin/sh <<EOF

set -e

apk update
apk upgrade --available

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

# --------------------------------------------------
# Desktop
# --------------------------------------------------

if [ -n "$DESKTOP_PACKAGE" ]; then
    info "Installing $DESKTOP_PACKAGE..."

    chimera-chroot /media/root /bin/sh <<EOF
apk add $DESKTOP_PACKAGE
EOF

    success "Desktop installed."
fi

# --------------------------------------------------
# User configuration
# --------------------------------------------------

info "Configuring user account..."

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

success "User configured."

# --------------------------------------------------
# Bootloader
# --------------------------------------------------

if [ "$BOOT" = "1" ]; then

    info "Installing GRUB..."

    if [ "$BOOTMODE" = "UEFI" ]; then

        chimera-chroot /media/root /bin/sh <<EOF

apk add grub-x86_64-efi
grub-install \
    --target=x86_64-efi \
    --efi-directory=/boot/efi \
    --bootloader-id=Chimera

update-grub

EOF

    else

        chimera-chroot /media/root /bin/sh <<EOF

apk add grub
grub-install "$DISK"
update-grub

EOF

    fi

elif [ "$BOOT" = "2" ]; then

    info "Installing systemd-boot..."

    chimera-chroot /media/root /bin/sh <<EOF

apk add systemd-boot
bootctl install

EOF

fi

# --------------------------------------------------
# Finish
# --------------------------------------------------

sync

success "Installation completed!"

echo
echo "${BOLD}${GREEN}"
echo "╔════════════════════════════════════════════╗"
echo "║          Welcome to Chimera Linux!         ║"
echo "╚════════════════════════════════════════════╝"
echo "${RESET}"

echo
echo "PC name:  $HOSTNAME"
echo "User:     $USERNAME"
echo "Kernel:   $KERNEL"
echo
echo "You can now reboot."
echo

umount -R /media/root 2>/dev/null || true

echo "${YELLOW}Remove the installation USB before rebooting.${RESET}"
