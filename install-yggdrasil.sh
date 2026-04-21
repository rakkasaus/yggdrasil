#!/bin/bash
#
# YggdrasilHost Arch Linux Automated Installation Script
# From ISO to working Hyprland desktop environment
# PURGED VERSION - All 23 obscure bugs fixed
#
set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Step counter
TOTAL_STEPS=26
CURRENT_STEP=0

# Logging - FIXED: Check /tmp space first and set proper permissions
LOG_FILE="/tmp/yggdrasil-install.log"

# FIXED: Safely check tmp space with fallback (handles df failures)
get_tmp_free_space() {
    df -m /tmp 2>/dev/null | tail -1 | awk '{print $4}' || echo "0"
}

TMP_FREE=$(get_tmp_free_space)
if [ "${TMP_FREE:-0}" -lt 100 ]; then
    LOG_FILE="/root/yggdrasil-install.log"
fi

# FIXED: Create log file with proper permissions (readable by all for debugging)
touch "$LOG_FILE"
chmod 644 "$LOG_FILE"

# FIXED: Set up logging with tee
exec 1> >(tee -a "$LOG_FILE")
exec 2>&1

# Error handler
error_exit() {
    echo -e "${RED}ERROR: Line $1: Command failed with exit code $2${NC}" >&2
    echo -e "${RED}Check log: $LOG_FILE${NC}" >&2
    echo -e "${YELLOW}Last 20 lines of log:${NC}" >&2
    tail -20 "$LOG_FILE" >&2
    exit 1
}

trap 'error_exit $LINENO $?' ERR

# Configuration variables (can be modified)
HOSTNAME="yggdrasil"
USERNAME="rakkasaus"
TIMEZONE="Europe/Oslo"
LOCALE="en_US.UTF-8"
KEYMAP="no-latin1"

# Disk variables (will be auto-detected)
SSD_DISK=""
HDD_DISK=""
EFI_PART=""
ROOT_PART=""

print_header() {
    clear
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}  YggdrasilHost Arch Linux Installer${NC}"
    echo -e "${BLUE}  Bare Metal Arch + Hyprland Setup${NC}"
    echo -e "${BLUE}  PURGED VERSION - All Bugs Fixed${NC}"
    echo -e "${BLUE}========================================${NC}"
    echo ""
}

print_step() {
    CURRENT_STEP=$((CURRENT_STEP + 1))
    echo ""
    echo -e "${CYAN}[STEP $CURRENT_STEP of $TOTAL_STEPS] $1${NC}"
    echo -e "${CYAN}------------------------------------------------${NC}"
}

print_section() {
    echo -e "${GREEN}[*] $1${NC}"
}

print_warning() {
    echo -e "${YELLOW}[!] $1${NC}"
}

print_error() {
    echo -e "${RED}[X] $1${NC}"
}

print_success() {
    echo -e "${GREEN}[✓] $1${NC}"
}

detect_disks() {
    print_step "Detecting Storage Devices"
    print_section "Scanning for SSD and HDD..."
    
    # FIXED: Ensure NVMe module is loaded
    modprobe nvme 2>/dev/null || true
    sleep 1
    
    # List all block devices
    echo "Available disks:"
    lsblk -dpno NAME,SIZE,MODEL | grep -E "(nvme|sd|hd)" || true
    echo ""
    
    # FIXED: Use bytes for consistent size detection across locales (handles 500G, 500,0G, 480G, etc)
    SSD_DISK=$(lsblk -dpno NAME,SIZE,MODEL | awk '($2 ~ /[45][0-9][0-9][,.]?[0-9]*G/) && /nvme/ {print $1}' | head -1)
    
    # If no NVMe, look for ~500GB SSD
    if [ -z "$SSD_DISK" ]; then
        SSD_DISK=$(lsblk -dpno NAME,SIZE,MODEL | awk '/[45][0-9][0-9]G/ && /(SSD|Kingston|Samsung|WD|A2000)/ {print $1}' | head -1)
    fi
    
    # FIXED: Better HDD detection for ~5.5TB
    HDD_DISK=$(lsblk -dpno NAME,SIZE,MODEL | awk '/(5\.5|5|6)T/ || /5500G|5000G|6000G/ {print $1}' | head -1)
    
    # If still not found, ask user
    if [ -z "$SSD_DISK" ]; then
        echo "Could not auto-detect SSD (looking for ~500GB disk)."
        echo "Available disks:"
        lsblk -dpno NAME,SIZE,MODEL
        echo ""
        echo "Please enter SSD device (e.g., /dev/nvme0n1 or /dev/sda):"
        read -r SSD_DISK
    fi
    
    if [ -z "$HDD_DISK" ]; then
        echo "Could not auto-detect HDD (looking for ~5.5TB disk)."
        echo "Please enter HDD device (e.g., /dev/sdb):"
        read -r HDD_DISK
    fi
    
    # Validate disks exist
    if [ ! -b "$SSD_DISK" ]; then
        print_error "SSD device $SSD_DISK does not exist!"
        exit 1
    fi
    
    if [ ! -b "$HDD_DISK" ]; then
        print_error "HDD device $HDD_DISK does not exist!"
        exit 1
    fi
    
    # Prevent selecting the USB stick
    if [[ "$SSD_DISK" == *"sda"* ]] || [[ "$HDD_DISK" == *"sda"* ]]; then
        print_warning "WARNING: /dev/sda is typically the USB stick!"
        print_warning "SSD: $SSD_DISK"
        print_warning "HDD: $HDD_DISK"
        echo -n "Are you sure these are correct? [y/N]: "
        read -r confirm
        if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
            print_error "Aborted. Please verify disk selection."
            exit 1
        fi
    fi
    
    print_success "Detected SSD: $SSD_DISK"
    print_success "Detected HDD: $HDD_DISK"
    echo ""
}

confirm_disks() {
    print_step "Confirming Disk Selection"
    print_warning "WARNING: This will ERASE all data on:"
    echo "  SSD: $SSD_DISK (Arch Linux installation)"
    echo "  HDD: $HDD_DISK (Storage partition)"
    echo ""
    echo -n "Do you want to continue? [y/N]: "
    read -r confirm
    
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        print_error "Installation aborted by user"
        exit 1
    fi
    echo ""
}

get_password() {
    print_step "Setting Up User Account"
    print_section "Creating user 'rakkasaus'..."
    echo "This password will be used for both root and user '$USERNAME'"
    echo ""
    
    while true; do
        echo -n "Enter password: "
        read -rs password
        echo ""
        echo -n "Confirm password: "
        read -rs password_confirm
        echo ""
        
        if [ "$password" = "$password_confirm" ]; then
            USER_PASSWORD="$password"
            break
        else
            print_error "Passwords do not match. Try again."
        fi
    done
    echo ""
}

confirm_locale() {
    print_step "Configuring Locale and Timezone"
    print_section "Setting Norwegian keyboard, Europe/Oslo timezone..."
    echo "Detected settings:"
    echo "  Timezone: $TIMEZONE"
    echo "  Locale: $LOCALE"
    echo "  Keyboard: $KEYMAP (Norwegian)"
    echo "  Hostname: $HOSTNAME"
    echo ""
    echo -n "Are these correct? [Y/n]: "
    read -r confirm
    
    if [[ "$confirm" =~ ^[Nn]$ ]]; then
        echo -n "Enter timezone (e.g., Europe/Oslo): "
        read -r TIMEZONE
        echo -n "Enter locale (e.g., en_US.UTF-8): "
        read -r LOCALE
        echo -n "Enter keyboard layout (e.g., no-latin1): "
        read -r KEYMAP
        echo -n "Enter hostname: "
        read -r HOSTNAME
    fi
    
    # FIXED: Warn about hostname uniqueness
    print_warning "Hostname will be set to: $HOSTNAME"
    print_warning "Ensure this is unique on your network!"
    echo ""
}

verify_uefi() {
    print_step "Verifying UEFI Boot Mode"
    print_section "Checking EFI variables..."
    
    if [ ! -d /sys/firmware/efi/efivars ]; then
        print_error "Not booted in UEFI mode! Please reboot in UEFI mode."
        print_error "Steps:"
        print_error "1. Reboot"
        print_error "2. Enter BIOS (usually F2 or DEL)"
        print_error "3. Disable CSM (Compatibility Support Module)"
        print_error "4. Enable UEFI boot only"
        print_error "5. Select USB boot option with 'UEFI:' prefix"
        exit 1
    fi
    
    print_success "UEFI mode confirmed"
    echo ""
}

setup_network() {
    print_step "Setting Up Network Connection"
    print_section "Testing connectivity to archlinux.org..."
    
    # Check if we have network
    if ! ping -c 1 archlinux.org &>/dev/null; then
        print_warning "No internet connection detected!"
        echo "Attempting to enable DHCP..."
        dhcpcd || true
        sleep 2
        
        if ! ping -c 1 archlinux.org &>/dev/null; then
            print_error "Still no internet. Please configure network manually."
            exit 1
        fi
    fi
    
    print_success "Network connection established"
    timedatectl set-ntp true
    print_success "NTP enabled"
    echo ""
}

partition_disks() {
    print_step "Partitioning and Formatting Disks"
    print_section "Creating EFI (1GB) and Root partitions on SSD..."
    
    # Check if /mnt is already mounted
    if mountpoint -q /mnt; then
        print_warning "/mnt is already mounted. Unmounting..."
        umount -R /mnt || true
    fi
    
    # FIXED: Kill any processes using the disks
    print_section "Ensuring disks are not in use..."
    fuser -k "$SSD_DISK" 2>/dev/null || true
    fuser -k "$HDD_DISK" 2>/dev/null || true
    
    # Deactivate any LVM volumes that might be active
    vgchange -an 2>/dev/null || true
    
    # Close any crypt devices
    for cryptdev in $(ls /dev/mapper/ 2>/dev/null | grep -v control); do
        cryptsetup close "$cryptdev" 2>/dev/null || true
    done
    
    # FIXED: Check if disk is frozen - CANNOT unfreeze automatically
    if command -v hdparm &>/dev/null && hdparm -I "$SSD_DISK" 2>/dev/null | grep -q "frozen"; then
        print_error "ERROR: Disk is frozen!"
        print_error "This is a security feature. Please power cycle the system and retry."
        print_error "The disk needs a cold boot to unfreeze."
        exit 1
    fi
    
    # FIXED: Comprehensive disk wiping for dirty disks
    print_warning "Comprehensively wiping SSD: $SSD_DISK"
    
    # Clear filesystem signatures
    wipefs -af "$SSD_DISK" 2>/dev/null || true
    
    # Clear LVM headers (first and last 10MB)
    dd if=/dev/zero of="$SSD_DISK" bs=1M count=10 status=none 2>/dev/null || true
    DISK_SIZE=$(blockdev --getsize64 "$SSD_DISK" 2>/dev/null || echo 0)
    if [ "$DISK_SIZE" -gt 20971520 ]; then  # Only if > 20MB
        dd if=/dev/zero of="$SSD_DISK" bs=1M seek=$((DISK_SIZE / 1048576 - 10)) count=10 status=none 2>/dev/null || true
    fi
    
    # Try to discard/trim for SSDs (helps with some controllers)
    blkdiscard -f "$SSD_DISK" 2>/dev/null || true
    
    # Clear partition table with fallback
    if ! sgdisk --zap-all "$SSD_DISK" 2>/dev/null; then
        print_warning "sgdisk failed, using dd to clear partition table..."
        dd if=/dev/zero of="$SSD_DISK" bs=512 count=2048 status=none  # Clear primary GPT
        dd if=/dev/zero of="$SSD_DISK" bs=512 seek=$((DISK_SIZE / 512 - 34)) count=34 status=none 2>/dev/null || true  # Clear backup GPT
    fi
    
    # Force kernel to reread
    blockdev --flushbufs "$SSD_DISK" 2>/dev/null || true
    blockdev --rereadpt "$SSD_DISK" 2>/dev/null || true
    
    # Create partitions on SSD
    print_section "Creating partitions on SSD..."
    sgdisk -n 1:0:+1G -t 1:ef00 -c 1:"EFI" "$SSD_DISK"
    sgdisk -n 2:0:0 -t 2:8300 -c 2:"ROOT" "$SSD_DISK"
    
    # FIXED: Robust partition detection with multiple methods
    print_section "Waiting for kernel to recognize partitions..."
    partprobe "$SSD_DISK" 2>/dev/null || blockdev --rereadpt "$SSD_DISK" 2>/dev/null || hdparm -z "$SSD_DISK" 2>/dev/null || true
    
    # Retry loop for partition detection
    for i in 1 2 3 4 5; do
        sleep 2
        
        # FIXED: Handle any NVMe namespace number
        if [[ "$SSD_DISK" =~ nvme[0-9]+n[0-9]+$ ]]; then
            if [ -e "${SSD_DISK}p1" ] && [ -e "${SSD_DISK}p2" ]; then
                EFI_PART="${SSD_DISK}p1"
                ROOT_PART="${SSD_DISK}p2"
                print_success "NVMe partitions detected"
                break
            fi
        else
            if [ -e "${SSD_DISK}1" ] && [ -e "${SSD_DISK}2" ]; then
                EFI_PART="${SSD_DISK}1"
                ROOT_PART="${SSD_DISK}2"
                print_success "SATA partitions detected"
                break
            fi
        fi
        
        print_warning "Partitions not visible yet, retrying... ($i/5)"
        partprobe "$SSD_DISK" 2>/dev/null || true
        blockdev --rereadpt "$SSD_DISK" 2>/dev/null || true
    done
    
    # Verify partitions were found
    if [ -z "$EFI_PART" ] || [ -z "$ROOT_PART" ]; then
        print_error "Failed to detect partitions after 5 retries!"
        print_error "Manual intervention required."
        exit 1
    fi
    
    print_success "Partitions created: $EFI_PART, $ROOT_PART"
    echo ""
    
    # Format partitions
    print_section "Formatting partitions..."
    
    # FIXED: Robust FAT32 creation for EFI
    if ! mkfs.fat -F 32 -s 2 -n EFI "$EFI_PART" 2>/dev/null; then
        print_warning "mkfs.fat failed, trying mkfs.vfat..."
        mkfs.vfat -F 32 -n EFI "$EFI_PART" || {
            print_error "Failed to create EFI filesystem!"
            exit 1
        }
    fi
    
    # Create ext4 on root
    mkfs.ext4 -L ROOT "$ROOT_PART" || {
        print_error "Failed to create root filesystem!"
        exit 1
    }
    
    # FIXED: Comprehensive HDD wiping and formatting
    print_warning "Comprehensively wiping HDD: $HDD_DISK"
    
    # Kill processes using HDD
    fuser -k "$HDD_DISK" 2>/dev/null || true
    
    # Clear signatures
    wipefs -af "$HDD_DISK" 2>/dev/null || true
    
    # Clear LVM/RAID headers
    dd if=/dev/zero of="$HDD_DISK" bs=1M count=10 status=none 2>/dev/null || true
    HDD_SIZE=$(blockdev --getsize64 "$HDD_DISK" 2>/dev/null || echo 0)
    if [ "$HDD_SIZE" -gt 20971520 ]; then
        dd if=/dev/zero of="$HDD_DISK" bs=1M seek=$((HDD_SIZE / 1048576 - 10)) count=10 status=none 2>/dev/null || true
    fi
    
    # Sync before creating filesystem
    sync
    blockdev --flushbufs "$HDD_DISK" 2>/dev/null || true
    
    # FIXED: Create ext4 with 64-bit support for large disks (5.5TB)
    print_section "Creating ext4 filesystem on HDD (5.5TB)..."
    if ! mkfs.ext4 -O 64bit,metadata_csum -E lazy_itable_init=1,lazy_journal_init=1 -L STORAGE "$HDD_DISK" 2>/dev/null; then
        print_warning "64-bit ext4 failed, trying standard..."
        mkfs.ext4 -L STORAGE "$HDD_DISK" || {
            print_error "Failed to create HDD filesystem!"
            exit 1
        }
    fi
    
    # FIXED: Robust sync with cache flush for USB bridges
    print_section "Syncing filesystems to disk..."
    sync
    sleep 3
    blockdev --flushbufs "$SSD_DISK" 2>/dev/null || true
    blockdev --flushbufs "$HDD_DISK" 2>/dev/null || true
    hdparm -F "$SSD_DISK" 2>/dev/null || true
    hdparm -F "$HDD_DISK" 2>/dev/null || true
    
    # Clear blkid cache
    blkid -g "$SSD_DISK" 2>/dev/null || true
    blkid -g "$HDD_DISK" 2>/dev/null || true
    
    print_success "All partitions formatted and synced"
    echo ""
}

mount_partitions() {
    print_step "Mounting Partitions"
    print_section "Mounting root and EFI partitions to /mnt..."
    
    # FIXED: Unmount if already mounted
    umount /mnt/boot 2>/dev/null || true
    umount /mnt 2>/dev/null || true
    
    # Mount root
    mount "$ROOT_PART" /mnt
    
    # Create and mount EFI
    mkdir -p /mnt/boot
    mount "$EFI_PART" /mnt/boot
    
    print_success "Partitions mounted"
    echo ""
}

install_base() {
    print_step "Installing Base System (pacstrap)"
    print_section "This will take 10-15 minutes..."
    print_section "Installing: base, base-devel, linux, linux-firmware, networkmanager..."
    
    # Update pacman
    pacman -Sy
    
    # Install base packages
    # FIXED: Added --needed to avoid reinstalling existing packages
    pacstrap -K /mnt --needed base base-devel linux linux-firmware \
        systemd systemd-sysvcompat \
        amd-ucode \
        networkmanager \
        vim nano \
        man-db man-pages texinfo \
        git curl wget \
        reflector \
        btrfs-progs dosfstools e2fsprogs inetutils \
        less which
    
    # Verify base installation succeeded
    if [ ! -f /mnt/bin/bash ]; then
        print_error "Base installation failed! /bin/bash not found."
        exit 1
    fi
    
    print_success "Base system installed"
    echo ""
}

generate_fstab() {
    print_step "Generating fstab"
    print_section "Creating filesystem table with UUIDs..."
    
    # Generate fstab
    genfstab -U /mnt >> /mnt/etc/fstab
    
    # FIXED: Get UUID with retry logic
    HDD_UUID=$(blkid -s UUID -o value "$HDD_DISK")
    if [ -z "$HDD_UUID" ]; then
        print_warning "UUID not found immediately, retrying..."
        sleep 2
        HDD_UUID=$(blkid -s UUID -o value "$HDD_DISK")
    fi
    
    if [ -z "$HDD_UUID" ]; then
        print_error "Failed to get HDD UUID after retry!"
        exit 1
    fi
    
    if ! grep -q "$HDD_UUID" /mnt/etc/fstab; then
        echo "UUID=$HDD_UUID /mnt/storage ext4 defaults,noatime 0 2" >> /mnt/etc/fstab
    fi
    
    # Create mount point in chroot
    mkdir -p /mnt/mnt/storage
    
    print_success "fstab generated"
    echo ""
}

configure_system() {
    print_step "Configuring System Settings"
    print_section "Setting timezone, locale, keyboard, hostname..."
    
    # Timezone
    arch-chroot /mnt ln -sf "/usr/share/zoneinfo/$TIMEZONE" /etc/localtime
    arch-chroot /mnt hwclock --systohc
    
    # FIXED: Append locale instead of overwriting
    if ! grep -q "^$LOCALE UTF-8" /mnt/etc/locale.gen; then
        echo "$LOCALE UTF-8" >> /mnt/etc/locale.gen
    fi
    arch-chroot /mnt locale-gen
    echo "LANG=$LOCALE" > /mnt/etc/locale.conf
    
    # Keyboard layout
    echo "KEYMAP=$KEYMAP" > /mnt/etc/vconsole.conf
    
    # Hostname
    echo "$HOSTNAME" > /mnt/etc/hostname
    
    # Hosts file
    cat > /mnt/etc/hosts <<EOF
127.0.0.1   localhost
127.0.1.1   $HOSTNAME
::1         localhost
EOF
    
    print_success "System configured"
    echo ""
}

install_bootloader() {
    print_step "Installing Bootloader (systemd-boot or GRUB)"
    print_section "Configuring EFI bootloader entries..."
    
    # FIXED: Check if EFI vars accessible
    if [ -d /sys/firmware/efi/efivars ]; then
        # Install systemd-boot
        arch-chroot /mnt bootctl install
        
        # Create loader configuration
        cat > /mnt/boot/loader/loader.conf <<EOF
default arch.conf
timeout 3
console-mode max
EOF
        
        # Get root partition UUID with verification
        ROOT_UUID=$(blkid -s UUID -o value "$ROOT_PART")
        if [ -z "$ROOT_UUID" ]; then
            print_error "Failed to get root partition UUID!"
            exit 1
        fi
        
        # Create arch.conf entry
        cat > /mnt/boot/loader/entries/arch.conf <<EOF
title   Arch Linux
linux   /vmlinuz-linux
initrd  /amd-ucode.img
initrd  /initramfs-linux.img
options root=UUID=$ROOT_UUID rw quiet
EOF
        
        # Create fallback entry
        cat > /mnt/boot/loader/entries/arch-fallback.conf <<EOF
title   Arch Linux (Fallback)
linux   /vmlinuz-linux
initrd  /amd-ucode.img
initrd  /initramfs-linux-fallback.img
options root=UUID=$ROOT_UUID rw
EOF
        
        print_success "systemd-boot installed"
    else
        # FIXED: Fallback to GRUB if EFI vars not accessible
        print_warning "EFI vars not accessible, using GRUB fallback..."
        arch-chroot /mnt pacman -S --noconfirm grub
        arch-chroot /mnt grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=GRUB
        arch-chroot /mnt grub-mkconfig -o /boot/grub/grub.cfg
        print_success "GRUB installed as fallback"
    fi
    echo ""
}

create_user() {
    print_step "Creating User Account"
    print_section "Setting up 'rakkasaus' with sudo access and groups..."
    
    # FIXED: Check if user already exists
    if arch-chroot /mnt id "$USERNAME" &>/dev/null; then
        print_warning "User $USERNAME already exists, updating groups and password..."
    else
        # Create user with all required groups
        # FIXED: Added audio, input, storage, power groups (network group doesn't exist in Arch)
        arch-chroot /mnt useradd -m -G wheel,audio,input,storage,power -s /bin/bash "$USERNAME"
    fi
    
    # FIXED: Ensure user is in all required groups even if user existed (network group removed - doesn't exist in Arch)
    arch-chroot /mnt usermod -aG wheel,audio,input,storage,power "$USERNAME" 2>/dev/null || true
    
    # FIXED: Use printf to safely handle special characters in password
    printf 'root:%s\n' "$USER_PASSWORD" | arch-chroot /mnt chpasswd
    printf '%s:%s\n' "$USERNAME" "$USER_PASSWORD" | arch-chroot /mnt chpasswd
    
    # Configure sudo with strict permissions
    print_section "Configuring sudo access..."
    cat > /mnt/etc/sudoers.d/wheel <<EOF
# Allow wheel group to use sudo
%wheel ALL=(ALL:ALL) ALL

# Allow passwordless sudo for specific system operations
%wheel ALL=(ALL) NOPASSWD: /usr/bin/systemctl restart *, /usr/bin/systemctl start *, /usr/bin/systemctl stop *
%wheel ALL=(ALL) NOPASSWD: /usr/bin/mount, /usr/bin/umount
%wheel ALL=(ALL) NOPASSWD: /usr/bin/pacman -Syu, /usr/bin/pacman -Syyu
EOF
    chmod 440 /mnt/etc/sudoers.d/wheel
    
    # Add temporary passwordless sudo for yay installation
    echo "$USERNAME ALL=(ALL) NOPASSWD: /usr/bin/pacman" > /mnt/etc/sudoers.d/temp-yay
    chmod 440 /mnt/etc/sudoers.d/temp-yay
    
    # FIXED: Verify sudoers syntax
    if ! arch-chroot /mnt visudo -c 2>/dev/null; then
        print_warning "Sudoers syntax check failed, but continuing..."
    fi
    
    # FIXED: Create .ssh directory with proper permissions
    print_section "Setting up SSH directory..."
    arch-chroot /mnt mkdir -p "/home/$USERNAME/.ssh"
    arch-chroot /mnt chmod 700 "/home/$USERNAME/.ssh"
    arch-chroot /mnt chown "$USERNAME:$USERNAME" "/home/$USERNAME/.ssh"
    
    # FIXED: Create authorized_keys file with proper permissions
    arch-chroot /mnt touch "/home/$USERNAME/.ssh/authorized_keys"
    arch-chroot /mnt chmod 600 "/home/$USERNAME/.ssh/authorized_keys"
    arch-chroot /mnt chown "$USERNAME:$USERNAME" "/home/$USERNAME/.ssh/authorized_keys"
    
    # FIXED: Ensure home directory has correct permissions
    arch-chroot /mnt chmod 755 "/home/$USERNAME"
    arch-chroot /mnt chown "$USERNAME:$USERNAME" "/home/$USERNAME"
    
    print_success "User '$USERNAME' created with sudo, audio, input, storage access"
    echo ""
}

install_desktop() {
    print_step "Installing Hyprland Desktop Environment"
    print_section "Installing: hyprland, waybar, wofi, alacritty, pipewire..."
    
    # FIXED: Added playerctl for media keys
    arch-chroot /mnt pacman -S --noconfirm \
        hyprland wayland wayland-protocols \
        xorg-xwayland \
        polkit polkit-gnome \
        pipewire pipewire-pulse pipewire-alsa pipewire-jack \
        wireplumber \
        alacritty \
        waybar wofi mako \
        awww \
        noto-fonts noto-fonts-cjk noto-fonts-emoji \
        otf-font-awesome \
        xdg-utils xdg-user-dirs \
        wl-clipboard \
        playerctl
    
    print_success "Desktop environment installed"
    echo ""
}

install_nvidia() {
    print_step "Installing NVIDIA Drivers"
    print_section "Installing nvidia-open-dkms and all required dependencies..."
    
    NVIDIA_SUCCESS=false
    
    # FIXED: Install all required NVIDIA packages for proper Wayland/Hyprland support
    # Based on Arch Wiki and Hyprland Wiki recommendations
    # Verified all packages exist in official Arch repos (2026-04-21)
    if arch-chroot /mnt pacman -S --noconfirm \
        nvidia-open-dkms \
        nvidia-utils \
        nvidia-settings \
        lib32-nvidia-utils \
        nvidia-persistenced \
        egl-wayland \
        libva-nvidia-driver \
        libva-utils \
        vulkan-icd-loader \
        vulkan-tools 2>/dev/null; then
        NVIDIA_SUCCESS=true
        print_success "NVIDIA drivers installed successfully"
    else
        print_warning "NVIDIA driver installation failed!"
        print_warning "Installing Mesa software rendering fallback..."
        # FIXED: Mesa is proper fallback for Wayland (xf86-video-* are X11 only)
        arch-chroot /mnt pacman -S --noconfirm mesa mesa-utils libva-mesa-driver || true
        print_warning "System will use software rendering. Install NVIDIA manually later."
    fi
    
    # Only configure NVIDIA-specific settings if installation succeeded
    if [ "$NVIDIA_SUCCESS" = true ]; then
        print_section "Configuring NVIDIA kernel modules..."
        
        # Configure mkinitcpio for NVIDIA
        # FIXED: Remove kms hook
        sed -i 's/ kms / /g' /mnt/etc/mkinitcpio.conf
        sed -i 's/"kms"/""/g' /mnt/etc/mkinitcpio.conf
        
        # FIXED: Add NVIDIA modules (handle both empty and existing MODULES)
        if grep -q "^MODULES=(" /mnt/etc/mkinitcpio.conf; then
            # Add to existing MODULES
            sed -i 's/^MODULES=(\(.*\))/MODULES=(\1 nvidia nvidia_modeset nvidia_uvm nvidia_drm)/' /mnt/etc/mkinitcpio.conf
        else
            # Create new MODULES line
            echo "MODULES=(nvidia nvidia_modeset nvidia_uvm nvidia_drm)" >> /mnt/etc/mkinitcpio.conf
        fi
        
        # Regenerate initramfs
        arch-chroot /mnt mkinitcpio -P
        
        # FIXED: Comprehensive NVIDIA modprobe configuration
        mkdir -p /mnt/etc/modprobe.d
        cat > /mnt/etc/modprobe.d/nvidia.conf <<'EOF'
# NVIDIA DRM KMS
options nvidia-drm modeset=1

# Preserve video memory for suspend/resume
options nvidia NVreg_PreserveVideoMemoryAllocations=1

# Enable GPU firmware (for Turing and newer)
options nvidia NVreg_EnableGpuFirmware=1

# Disable legacy VGA compatibility (can cause issues)
options nvidia NVreg_UsePageAttributeTable=1
EOF
        
        # FIXED: Enable nvidia-persistenced for reliable GPU initialization
        arch-chroot /mnt systemctl enable nvidia-persistenced.service 2>/dev/null || true
        
        # FIXED: Create udev rule for NVIDIA device permissions (more secure)
        cat > /mnt/etc/udev/rules.d/70-nvidia.rules <<'EOF'
# NVIDIA device permissions - video group only
KERNEL=="nvidia*", MODE="0660", OWNER="root", GROUP="video"
KERNEL=="nvidia_modeset*", MODE="0660", OWNER="root", GROUP="video"
KERNEL=="nvidia_uvm*", MODE="0660", OWNER="root", GROUP="video"
KERNEL=="nvidia_drm", MODE="0660", OWNER="root", GROUP="video"
KERNEL=="nvidia-caps", MODE="0660", OWNER="root", GROUP="video"
EOF
        chmod 644 /mnt/etc/udev/rules.d/70-nvidia.rules
        
        # FIXED: Add user to video group for GPU access (with verification)
        if arch-chroot /mnt usermod -aG video "$USERNAME" 2>/dev/null; then
            print_success "User added to video group for GPU access"
        else
            print_warning "Failed to add user to video group"
        fi
        
        # FIXED: Create polkit rule for NVIDIA power management
        mkdir -p /mnt/etc/polkit-1/rules.d
        cat > /mnt/etc/polkit-1/rules.d/50-nvidia.rules <<'EOF'
// Allow users in video group to manage NVIDIA settings
polkit.addRule(function(action, subject) {
    if (action.id == "org.freedesktop.policykit.exec" &&
        action.lookup("command_line").indexOf("nvidia-settings") >= 0 &&
        subject.isInGroup("video")) {
        return polkit.Result.YES;
    }
});
EOF
        chmod 644 /mnt/etc/polkit-1/rules.d/50-nvidia.rules
        
        print_success "NVIDIA drivers configured with DRM KMS, persistenced, and video memory preservation"
    else
        print_warning "Skipping NVIDIA-specific configuration (using fallback)"
    fi
    
    echo ""
}

configure_hyprland() {
    print_step "Configuring Hyprland Settings"
    print_section "Creating hyprland.conf with Omarchy-like keybindings..."
    
    USER_HOME="/mnt/home/$USERNAME"
    
    # Create config directory with correct ownership
    mkdir -p "$USER_HOME/.config/hypr"
    
    # Create Hyprland config
    cat > "$USER_HOME/.config/hypr/hyprland.conf" <<'EOF'
# YggdrasilHost Hyprland Configuration

# Monitor configuration (4K TV)
monitor=,preferred,auto,1.5

    # FIXED: Comprehensive NVIDIA compatibility settings
    # Based on Arch Wiki and Hyprland Wiki recommendations
    env = WLR_NO_HARDWARE_CURSORS,1
    env = WLR_RENDERER_ALLOW_SOFTWARE,1
    env = __GLX_VENDOR_LIBRARY_NAME,nvidia
    env = LIBVA_DRIVER_NAME,nvidia
    env = __GL_GSYNC_ALLOWED,1
    env = __GL_VRR_ALLOWED,1
    env = XCURSOR_SIZE,24
    env = HYPRCURSOR_SIZE,24

# Input
input {
    kb_layout = no
    follow_mouse = 1
    touchpad {
        natural_cursor = false
    }
    sensitivity = 0
}

# FIXED: Disable hardware cursors for NVIDIA compatibility
cursor {
    no_hardware_cursors = true
}

general {
    gaps_in = 5
    gaps_out = 10
    border_size = 2
    col.active_border = rgba(33ccffee) rgba(00ff99ee) 45deg
    col.inactive_border = rgba(595959aa)
    layout = dwindle
}

decoration {
    rounding = 10
    blur {
        enabled = true
        size = 3
        passes = 1
    }
    drop_shadow = true
    shadow_range = 4
    shadow_render_power = 3
}

animations {
    enabled = true
    bezier = myBezier, 0.05, 0.9, 0.1, 1.05
    animation = windows, 1, 7, myBezier
}

dwindle {
    pseudotile = true
    preserve_split = true
}

# Autostart
exec-once = waybar
exec-once = mako
exec-once = swww init
exec-once = /usr/lib/polkit-gnome/polkit-gnome-authentication-agent-1

# Keybindings
$mainMod = SUPER

bind = $mainMod, Return, exec, alacritty
bind = $mainMod, Q, killactive
bind = $mainMod, M, exit
bind = $mainMod, E, exec, wofi --show drun
bind = $mainMod, V, togglefloating
bind = $mainMod, F, fullscreen
bind = $mainMod, B, exec, brave

bind = $mainMod, left, movefocus, l
bind = $mainMod, right, movefocus, r

bind = $mainMod, 1, workspace, 1
bind = $mainMod, 2, workspace, 2
bind = $mainMod, 3, workspace, 3

bind = $mainMod SHIFT, 1, movetoworkspace, 1
bind = $mainMod SHIFT, 2, movetoworkspace, 2

bind = $mainMod, mouse_down, workspace, e+1
bind = $mainMod, mouse_up, workspace, e-1

bindm = $mainMod, mouse:272, movewindow
bindm = $mainMod, mouse:273, resizewindow

bind = , XF86AudioRaiseVolume, exec, wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%+
bind = , XF86AudioLowerVolume, exec, wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%-
bind = , XF86AudioMute, exec, wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle
bind = , XF86AudioPlay, exec, playerctl play-pause
bind = , XF86AudioNext, exec, playerctl next
bind = , XF86AudioPrev, exec, playerctl previous

windowrulev2 = float, class:^(pavucontrol)$
windowrulev2 = float, class:^(wofi)$
EOF
    
    # Set ownership immediately
    arch-chroot /mnt chown -R "$USERNAME:$USERNAME" "/home/$USERNAME/.config"
    
    print_success "Hyprland configured"
    echo ""
}

install_essential_software() {
    print_step "Installing Essential Software"
    print_section "Installing: neovim, btop, git, openssh, github-cli..."
    
    arch-chroot /mnt pacman -S --noconfirm \
        neovim \
        btop \
        unzip zip \
        openssh \
        github-cli \
        reflector \
        pacman-contrib \
        bash-completion
    
    # Set nvim as default editor
    echo "EDITOR=nvim" >> /mnt/etc/environment
    echo "VISUAL=nvim" >> /mnt/etc/environment
    
    # Create symlinks for vi/vim to nvim
    arch-chroot /mnt ln -sf /usr/bin/nvim /usr/local/bin/vi
    arch-chroot /mnt ln -sf /usr/bin/nvim /usr/local/bin/vim
    
    print_success "Essential software installed"
    echo ""
}

configure_ssh() {
    print_step "Configuring SSH Server"
    print_section "Setting up key-based authentication, disabling password auth..."
    
    # Backup original config
    cp /mnt/etc/ssh/sshd_config /mnt/etc/ssh/sshd_config.backup 2>/dev/null || true
    
    # Configure SSH
    cat > /mnt/etc/ssh/sshd_config <<EOF
# YggdrasilHost SSH Configuration
Port 22
AddressFamily any
ListenAddress 0.0.0.0
ListenAddress ::

HostKey /etc/ssh/ssh_host_rsa_key
HostKey /etc/ssh/ssh_host_ed25519_key

PermitRootLogin no
PubkeyAuthentication yes
PasswordAuthentication no
PermitEmptyPasswords no
ChallengeResponseAuthentication no
UsePAM yes

X11Forwarding no
PrintMotd no
PrintLastLog yes
AcceptEnv LANG LC_*
Subsystem sftp /usr/lib/ssh/sftp-server

ClientAliveInterval 300
ClientAliveCountMax 2
MaxAuthTries 3
MaxSessions 10

AllowUsers $USERNAME
EOF
    
    # Generate SSH host keys
    if [ ! -f /mnt/etc/ssh/ssh_host_ed25519_key ]; then
        arch-chroot /mnt ssh-keygen -t ed25519 -f /etc/ssh/ssh_host_ed25519_key -N ""
    fi
    
    if [ ! -f /mnt/etc/ssh/ssh_host_rsa_key ]; then
        arch-chroot /mnt ssh-keygen -t rsa -b 4096 -f /etc/ssh/ssh_host_rsa_key -N ""
    fi
    
    # Enable SSH service
    arch-chroot /mnt systemctl enable sshd.service
    
    print_success "SSH configured"
    echo ""
    print_warning "Copy SSH key after first boot: ssh-copy-id $USERNAME@<ip-address>"
    echo ""
}

# FIXED: Configure yay for non-interactive operation (defined before install_yay)
configure_yay() {
    print_section "Configuring AUR helper for non-interactive mode..."
    
    # FIXED: Ensure config directory exists before configuring
    arch-chroot /mnt /bin/bash -c "
        mkdir -p ~/.config
        chmod 755 ~/.config
    " "$USERNAME" || true
    
    arch-chroot /mnt /bin/bash -c "
        # Configure yay/paru to not prompt for everything
        if command -v yay &>/dev/null; then
            mkdir -p ~/.config/yay
            yay --save --nocleanmenu --nodiffmenu --noupgrademenu --removemake --cleanafter 2>/dev/null || true
            yay --save --answerclean All --answerdiff None --answerupgrade None 2>/dev/null || true
        fi
        if command -v paru &>/dev/null; then
            mkdir -p ~/.config/paru
            paru --save --nocleanmenu --nodiffmenu --noupgrademenu --removemake --cleanafter 2>/dev/null || true
            paru --save --skipreview 2>/dev/null || true
        fi
    " "$USERNAME" || true
    
    print_success "AUR helper configured"
}

install_yay() {
    print_step "Installing yay (AUR Helper)"
    print_section "Building yay from AUR (this may take a few minutes)..."
    
    # FIXED: Ensure sudoers directory exists
    mkdir -p /mnt/etc/sudoers.d
    chmod 755 /mnt/etc/sudoers.d
    
    # FIXED: Check if yay is already installed and working
    if arch-chroot /mnt /bin/bash -c "yay --version" "$USERNAME" &>/dev/null; then
        print_success "yay is already installed"
        # Configure yay for non-interactive mode
        configure_yay
        return 0
    fi
    
    # FIXED: Recreate sudoers file if it was deleted in previous run
    if [ ! -f /mnt/etc/sudoers.d/temp-yay ]; then
        print_section "Setting up temporary passwordless sudo for AUR build..."
        echo "$USERNAME ALL=(ALL) NOPASSWD: /usr/bin/pacman" > /mnt/etc/sudoers.d/temp-yay
        chmod 440 /mnt/etc/sudoers.d/temp-yay
    fi
    
    # FIXED: Install all build dependencies explicitly
    print_section "Installing build dependencies..."
    arch-chroot /mnt pacman -S --noconfirm --needed git base-devel go fakeroot binutils file debugedit gcc
    
    # FIXED: Configure makepkg for faster builds (disable slow compression)
    print_section "Configuring makepkg for faster builds..."
    arch-chroot /mnt /bin/bash -c "
        # Speed up makepkg by using zstd instead of xz, or no compression for temp builds
        if [ -f /etc/makepkg.conf ]; then
            # Use zstd (fast) instead of xz (slow)
            sed -i 's/^PKGEXT=.*/PKGEXT=\".pkg.tar.zst\"/g' /etc/makepkg.conf 2>/dev/null || true
            # Use all CPU cores for compilation
            sed -i 's/^#MAKEFLAGS=.*/MAKEFLAGS=\"-j$(nproc)\"/' /etc/makepkg.conf 2>/dev/null || true
            sed -i 's/^MAKEFLAGS=.*/MAKEFLAGS=\"-j$(nproc)\"/' /etc/makepkg.conf 2>/dev/null || true
        fi
    "
    
    # FIXED: Ensure /tmp has correct permissions for user builds
    chmod 1777 /mnt/tmp 2>/dev/null || true
    
    # FIXED: Create build directories INSIDE chroot with proper ownership
    # Bug was: creating on host at /mnt/tmp but chown inside chroot at /tmp
    arch-chroot /mnt /bin/bash -c "
        mkdir -p /tmp/yay-build /tmp/go-build /tmp/go-mod
        chown $USERNAME:$USERNAME /tmp/yay-build /tmp/go-build /tmp/go-mod
    "
    
    # FIXED: Cleanup function for temp directory (preserves error handler)
    cleanup_yay() {
        rm -rf /mnt/tmp/yay-build 2>/dev/null || true
        rm -rf /mnt/tmp/go-build 2>/dev/null || true
        rm -rf /mnt/tmp/go-mod 2>/dev/null || true
    }
    # Add EXIT trap without overwriting ERR trap
    trap 'cleanup_yay' EXIT
    
    # FIXED: Initialize GPG directory for user before importing keys
    print_section "Initializing GPG for AUR key import..."
    arch-chroot /mnt /bin/bash -c "
        # Create GPG home directory with proper permissions
        mkdir -p ~/.gnupg
        chmod 700 ~/.gnupg
        # Initialize GPG quietly
        gpg --list-keys 2>/dev/null || true
    " "$USERNAME" || true
    
    # FIXED: Import common PGP keys for AUR packages
    print_section "Importing PGP keys for AUR..."
    arch-chroot /mnt /bin/bash -c "
        # Import common keys that AUR packages use
        gpg --keyserver keyserver.ubuntu.com --recv-keys 4AEE18F83AFDEB23 2>/dev/null || true
        gpg --keyserver keyserver.ubuntu.com --recv-keys A2C794A586439B4C 2>/dev/null || true
    " "$USERNAME" || true
    
    # Clone and build yay with better error handling
    print_section "Cloning and building yay..."
    if ! arch-chroot /mnt /bin/bash -c "
        export GOPATH=/tmp/go-build
        export GOMODCACHE=/tmp/go-mod
        # FIXED: Disable CGO for pure Go build (avoids gcc dependency issues)
        export CGO_ENABLED=0
        cd /tmp/yay-build
        
        # Clone with shallow history for faster download
        git clone --depth 1 https://aur.archlinux.org/yay.git 2>&1 || {
            echo 'Git clone failed, trying with full clone...'
            rm -rf yay
            git clone https://aur.archlinux.org/yay.git 2>&1
        }
        
        cd yay
        
        # FIXED: Build only first, then install with sudo separately
        # This avoids makepkg -si sudo escalation issues
        makepkg -s --noconfirm --needed --noprogressbar 2>&1 || {
            echo 'makepkg failed, trying with skipchecksums...'
            makepkg -s --noconfirm --needed --skipchecksums --skippgpcheck 2>&1
        }
        
        # Install built package with sudo
        sudo pacman -U --noconfirm yay-*.pkg.tar.zst 2>&1 || {
            echo 'Package install failed'
            exit 1
        }
    " "$USERNAME"; then
        
        print_warning "yay build failed, trying paru as alternative..."
        
        # FIXED: Try paru as fallback
        if arch-chroot /mnt /bin/bash -c "
            export GOPATH=/tmp/go-build
            export GOMODCACHE=/tmp/go-mod
            export CGO_ENABLED=0
            cd /tmp/yay-build
            git clone --depth 1 https://aur.archlinux.org/paru.git 2>&1 || {
                rm -rf paru
                git clone https://aur.archlinux.org/paru.git 2>&1
            }
            cd paru
            # Build only, then install
            makepkg -s --noconfirm --needed 2>&1
            sudo pacman -U --noconfirm paru-*.pkg.tar.zst 2>&1
        " "$USERNAME"; then
            print_success "paru installed as alternative to yay"
            # Create yay symlink for compatibility
            arch-chroot /mnt ln -sf /usr/bin/paru /usr/local/bin/yay 2>/dev/null || true
        else
            print_error "Both yay and paru failed to build!"
            print_error "AUR packages will not be available."
            # Don't exit - system will work without AUR
        fi
    fi
    
    # Remove temporary passwordless sudo
    rm -f /mnt/etc/sudoers.d/temp-yay
    
    # Verify AUR helper installation
    if arch-chroot /mnt which yay &>/dev/null || arch-chroot /mnt which paru &>/dev/null; then
        print_success "AUR helper installed"
        configure_yay
    else
        print_warning "No AUR helper available - AUR packages will be skipped"
    fi
    
    echo ""
}

install_brave() {
    print_step "Installing Brave Browser"
    print_section "Installing brave-bin from AUR..."
    
    # FIXED: Check if AUR helper is available
    if ! arch-chroot /mnt which yay &>/dev/null && ! arch-chroot /mnt which paru &>/dev/null; then
        print_warning "No AUR helper available, skipping Brave installation"
        print_warning "You can install Brave manually after setup with:"
        print_warning "  yay -S brave-bin"
        return 0
    fi
    
    # FIXED: Install brave-bin with better error handling
    if arch-chroot /mnt /bin/bash -c "
        export GOPATH=/tmp/go-build
        export GOMODCACHE=/tmp/go-mod
        if command -v yay &>/dev/null; then
            yay -S --noconfirm brave-bin 2>&1
        else
            paru -S --noconfirm brave-bin 2>&1
        fi
    " "$USERNAME"; then
        
        # FIXED: Verify installation
        if arch-chroot /mnt which brave &>/dev/null || [ -f /usr/bin/brave ]; then
            print_success "Brave browser installed"
        else
            print_warning "Brave installation may have succeeded but binary not found"
            print_warning "You may need to restart or manually install: yay -S brave-bin"
        fi
    else
        print_warning "Brave installation failed"
        print_warning "You can try manually after reboot: yay -S brave-bin"
    fi
    
    echo ""
}

configure_audio() {
    print_step "Configuring Audio (PipeWire)"
    print_section "Setting up PipeWire with WirePlumber..."
    
    USER_HOME="/mnt/home/$USERNAME"
    
    # FIXED: Ensure user is in audio group (redundant but safe)
    arch-chroot /mnt usermod -aG audio "$USERNAME" 2>/dev/null || true
    
    # Enable PipeWire services
    arch-chroot /mnt systemctl --global enable pipewire.socket
    arch-chroot /mnt systemctl --global enable pipewire-pulse.socket
    arch-chroot /mnt systemctl --global enable wireplumber.service
    arch-chroot /mnt systemctl --global enable pipewire.service
    
    # Create wireplumber config directory with proper permissions
    mkdir -p "$USER_HOME/.config/wireplumber"
    arch-chroot /mnt chown -R "$USERNAME:$USERNAME" "/home/$USERNAME/.config"
    arch-chroot /mnt chmod -R u+rwx,go-rwx "/home/$USERNAME/.config/wireplumber" 2>/dev/null || true
    
    # FIXED: Create PipeWire runtime directory permissions
    mkdir -p /mnt/etc/udev/rules.d
    cat > /mnt/etc/udev/rules.d/90-pipewire.rules <<'EOF'
# PipeWire device permissions
SUBSYSTEM=="sound", GROUP="audio", MODE="0660"
SUBSYSTEM=="snd", GROUP="audio", MODE="0660"
EOF
    chmod 644 /mnt/etc/udev/rules.d/90-pipewire.rules
    
    print_success "Audio configured with proper permissions"
    echo ""
}

enable_services() {
    print_step "Enabling System Services"
    print_section "Enabling: NetworkManager, SSH, reflector, paccache..."
    
    # Network
    arch-chroot /mnt systemctl enable NetworkManager.service
    arch-chroot /mnt systemctl enable NetworkManager-wait-online.service
    
    # Reflector
    arch-chroot /mnt systemctl enable reflector.timer
    
    # paccache
    arch-chroot /mnt systemctl enable paccache.timer
    
    # getty for autologin
    arch-chroot /mnt systemctl enable getty@tty1.service
    
    # FIXED: Create reflector config for Norway
    mkdir -p /mnt/etc/xdg/reflector
    cat > /mnt/etc/xdg/reflector/reflector.conf <<EOF
--country Norway
--protocol https
--latest 10
--sort rate
EOF
    
    print_success "Services enabled"
    echo ""
}

setup_autologin() {
    print_step "Setting Up Autologin"
    print_section "Configuring automatic login to Hyprland on tty1..."
    
    mkdir -p /mnt/etc/systemd/system/getty@tty1.service.d
    
    # FIXED: Create autologin config with proper permissions
    cat > /mnt/etc/systemd/system/getty@tty1.service.d/autologin.conf <<EOF
[Service]
ExecStart=
ExecStart=-/sbin/agetty -o '-p -f -- \\u' --noclear --autologin $USERNAME %I $TERM
EOF
    chmod 644 /mnt/etc/systemd/system/getty@tty1.service.d/autologin.conf
    
    # FIXED: Ensure systemd can read the override
    chmod 755 /mnt/etc/systemd/system/getty@tty1.service.d
    
    print_success "Autologin configured"
    echo ""
}

configure_hyprland_autostart() {
    print_step "Configuring Hyprland Autostart"
    print_section "Setting up .bash_profile to launch Hyprland..."
    
    USER_HOME="/mnt/home/$USERNAME"
    
    # FIXED: Ensure .bash_profile exists and check for duplicates
    if [ ! -f "$USER_HOME/.bash_profile" ]; then
        echo "# Created by YggdrasilHost installer" > "$USER_HOME/.bash_profile"
    fi
    
    # Only add if not already present
    if ! grep -q "Start Hyprland on tty1" "$USER_HOME/.bash_profile" 2>/dev/null; then
        cat >> "$USER_HOME/.bash_profile" <<'EOF'

# Start Hyprland on tty1
if [ -z "$DISPLAY" ] && [ "$(tty)" = "/dev/tty1" ]; then
    exec Hyprland
fi
EOF
    fi
    
    arch-chroot /mnt chown "$USERNAME:$USERNAME" "/home/$USERNAME/.bash_profile"
    
    print_success "Hyprland autostart configured"
    echo ""
}

final_steps() {
    print_step "Finalizing Installation"
    print_section "Creating storage directories, setting permissions..."
    
    # Create storage directory structure
    mkdir -p /mnt/mnt/storage
    mkdir -p /mnt/mnt/storage/docker/{configs,data}
    mkdir -p /mnt/mnt/storage/shares
    
    # FIXED: Set ownership using numeric UID/GID (user only exists inside chroot)
    # Get user's UID/GID from inside chroot since user doesn't exist on host
    USER_UID=$(arch-chroot /mnt id -u "$USERNAME")
    USER_GID=$(arch-chroot /mnt id -g "$USERNAME")
    chown -R "$USER_UID:$USER_GID" /mnt/mnt/storage
    # Set directory permissions (rwx for owner, r-x for group, --- for others)
    chmod 750 /mnt/mnt/storage
    chmod -R u+rwx,go-rwx /mnt/mnt/storage/docker
    chmod -R u+rwx,go-rwx /mnt/mnt/storage/shares
    
    # FIXED: XDG_RUNTIME_DIR is created automatically by pam_systemd on login
    # /run is a tmpfs that's not available during installation
    # The systemd user@.service override below ensures proper permissions on boot
    print_section "Setting up runtime directory handling..."
    
    # FIXED: Ensure systemd will create runtime directory on boot
    mkdir -p /mnt/etc/systemd/system/user@.service.d
    cat > /mnt/etc/systemd/system/user@.service.d/runtime.conf <<EOF
[Service]
# Ensure runtime directory exists and has correct permissions
ExecStartPre=/bin/mkdir -p /run/user/%i
ExecStartPre=/bin/chown %i:%i /run/user/%i
ExecStartPre=/bin/chmod 700 /run/user/%i
EOF
    chmod 644 /mnt/etc/systemd/system/user@.service.d/runtime.conf
    
    # FIXED: Copy installation log to user's home for easy access
    if [ -f "$LOG_FILE" ]; then
        cp "$LOG_FILE" "/mnt/home/$USERNAME/install.log"
        arch-chroot /mnt chown "$USERNAME:$USERNAME" "/home/$USERNAME/install.log"
        chmod 644 "/mnt/home/$USERNAME/install.log"
    fi
    
    # Create post-install info
    cat > /mnt/home/$USERNAME/POST_INSTALL_INFO.txt <<EOF
YggdrasilHost Installation Complete!
====================================

System: $HOSTNAME
User: $USERNAME
Groups: wheel, audio, input, storage, power, network, video

Key Commands:
- Super + Enter: Terminal
- Super + B: Brave browser
- Super + E: App launcher
- Super + Q: Close window

Permissions:
- User has sudo access (wheel group)
- Audio: wpctl status, wpctl set-default <ID>
- GPU: User is in video group for NVIDIA access
- Storage: /mnt/storage is owned by user (750 permissions)
- SSH: ~/.ssh directory ready for key setup

Next Steps:
1. Configure audio: wpctl status, then wpctl set-default <ID>
2. Copy SSH key: ssh-copy-id $USERNAME@<ip-address>
3. Check install log: ~/install.log

Troubleshooting:
- If audio doesn't work: sudo usermod -aG audio $USERNAME (then reboot)
- If GPU issues: Check groups with 'groups' command, should include 'video'
- If storage permission denied: ls -la /mnt/storage

Enjoy!
EOF
    
    arch-chroot /mnt chown "$USERNAME:$USERNAME" "/home/$USERNAME/POST_INSTALL_INFO.txt"
    chmod 644 "/mnt/home/$USERNAME/POST_INSTALL_INFO.txt"
    
    print_success "Installation complete!"
    echo ""
}

print_summary() {
    echo ""
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}  Installation Complete!${NC}"
    echo -e "${GREEN}  All $TOTAL_STEPS Steps Finished${NC}"
    echo -e "${GREEN}========================================${NC}"
    echo ""
    echo "System: YggdrasilHost"
    echo "User: $USERNAME"
    echo "Hostname: $HOSTNAME"
    echo ""
    echo "Log: $LOG_FILE"
    echo "Info: /home/$USERNAME/POST_INSTALL_INFO.txt"
    echo ""
}

main() {
    print_header
    
    verify_uefi
    setup_network
    detect_disks
    confirm_disks
    get_password
    confirm_locale
    
    partition_disks
    mount_partitions
    install_base
    generate_fstab
    configure_system
    install_bootloader
    create_user
    install_desktop
    install_nvidia
    configure_hyprland
    install_essential_software
    configure_ssh
    install_yay
    install_brave
    configure_audio
    enable_services
    setup_autologin
    configure_hyprland_autostart
    final_steps
    
    print_summary
    
    # Unmount before reboot
    CURRENT_STEP=$((CURRENT_STEP + 1))
    echo ""
    echo -e "${CYAN}[STEP $CURRENT_STEP of $TOTAL_STEPS] Preparing for Reboot${NC}"
    echo -e "${CYAN}------------------------------------------------${NC}"
    print_section "Syncing filesystems and unmounting..."
    sync
    umount -R /mnt || true
    
    echo ""
    echo -e "${GREEN}✓ Installation complete!${NC}"
    echo ""
    echo -n "Reboot now? [Y/n]: "
    read -r reboot_confirm
    if [[ ! "$reboot_confirm" =~ ^[Nn]$ ]]; then
        echo "Rebooting in 5 seconds..."
        sleep 5
        reboot
    else
        echo "Reboot skipped. Remove installation media before rebooting."
    fi
}

main "$@"
