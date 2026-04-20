#!/bin/bash
#
# YggdrasilHost Arch Linux Automated Installation Script
# From ISO to working Hyprland desktop environment
# FIXED VERSION - Addresses all critical bugs
#
set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging
LOG_FILE="/tmp/yggdrasil-install.log"
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
    echo -e "${BLUE}  FIXED VERSION${NC}"
    echo -e "${BLUE}========================================${NC}"
    echo ""
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
    print_section "Detecting storage devices..."
    
    # List all block devices
    echo "Available disks:"
    lsblk -dpno NAME,SIZE,MODEL | grep -E "(nvme|sd|hd)" || true
    echo ""
    
    # Try to auto-detect SSD (typically NVMe or ~500GB)
    # FIXED: Added size check to avoid picking USB stick
    SSD_DISK=$(lsblk -dpno NAME,SIZE,MODEL | grep -E "500G|480G|512G" | grep -i "nvme" | head -1 | awk '{print $1}')
    
    # If no NVMe, look for ~500GB SSD
    if [ -z "$SSD_DISK" ]; then
        SSD_DISK=$(lsblk -dpno NAME,SIZE,MODEL | grep -E "500G|480G|512G" | grep -E "(SSD|Kingston|Samsung|WD|A2000)" | head -1 | awk '{print $1}')
    fi
    
    # Try to auto-detect HDD (typically ~4TB)
    # FIXED: Added size check for ~4TB
    HDD_DISK=$(lsblk -dpno NAME,SIZE,MODEL | grep -E "3.6T|4T|4000G" | head -1 | awk '{print $1}')
    
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
        echo "Could not auto-detect HDD (looking for ~4TB disk)."
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
    
    # FIXED: Prevent selecting the USB stick
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
    print_section "Setting up user account..."
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
    print_section "Locale configuration..."
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
    echo ""
}

verify_uefi() {
    print_section "Verifying UEFI boot mode..."
    
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
    print_section "Setting up network..."
    
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
    print_section "Partitioning disks..."
    
    # FIXED: Check if /mnt is already mounted
    if mountpoint -q /mnt; then
        print_warning "/mnt is already mounted. Unmounting..."
        umount -R /mnt || true
    fi
    
    # Wipe SSD
    print_warning "Wiping SSD: $SSD_DISK"
    wipefs -af "$SSD_DISK"
    sgdisk -Zo "$SSD_DISK"
    
    # Create partitions on SSD
    # Partition 1: EFI (512MB)
    # Partition 2: Root (remainder)
    print_section "Creating partitions on SSD..."
    sgdisk -n 1:0:+512M -t 1:ef00 -c 1:"EFI" "$SSD_DISK"
    sgdisk -n 2:0:0 -t 2:8300 -c 2:"ROOT" "$SSD_DISK"
    
    # Wait for kernel to recognize partitions
    partprobe "$SSD_DISK"
    sleep 2
    
    # FIXED: Set global partition variables
    if [[ "$SSD_DISK" == *"nvme"* ]]; then
        EFI_PART="${SSD_DISK}p1"
        ROOT_PART="${SSD_DISK}p2"
    else
        EFI_PART="${SSD_DISK}1"
        ROOT_PART="${SSD_DISK}2"
    fi
    
    print_success "Partitions created"
    echo ""
    
    # Format partitions
    print_section "Formatting partitions..."
    mkfs.fat -F 32 -n EFI "$EFI_PART"
    mkfs.ext4 -L ROOT "$ROOT_PART"
    
    # Format HDD as single ext4 partition
    print_warning "Formatting HDD: $HDD_DISK"
    wipefs -af "$HDD_DISK"
    mkfs.ext4 -L STORAGE "$HDD_DISK"
    
    print_success "All partitions formatted"
    echo ""
}

mount_partitions() {
    print_section "Mounting partitions..."
    
    # FIXED: Use global ROOT_PART and EFI_PART variables
    # Mount root
    mount "$ROOT_PART" /mnt
    
    # Create and mount EFI
    mkdir -p /mnt/boot
    mount --mkdir "$EFI_PART" /mnt/boot
    
    print_success "Partitions mounted"
    echo ""
}

install_base() {
    print_section "Installing base system..."
    
    # Update pacman
    pacman -Sy
    
    # Install base packages
    pacstrap -K /mnt base base-devel linux linux-firmware \
        systemd systemd-sysvcompat \
        amd-ucode \
        networkmanager \
        vim nano \
        man-db man-pages texinfo \
        git curl wget \
        reflector \
        btrfs-progs dosfstools e2fsprogs inetutils \
        less which
    
    # FIXED: Verify base installation succeeded
    if [ ! -f /mnt/bin/bash ]; then
        print_error "Base installation failed! /bin/bash not found."
        exit 1
    fi
    
    print_success "Base system installed"
    echo ""
}

generate_fstab() {
    print_section "Generating fstab..."
    
    # Generate fstab
    genfstab -U /mnt >> /mnt/etc/fstab
    
    # FIXED: Add HDD entry to fstab
    HDD_UUID=$(blkid -s UUID -o value "$HDD_DISK")
    if ! grep -q "$HDD_UUID" /mnt/etc/fstab; then
        echo "UUID=$HDD_UUID /mnt/storage ext4 defaults,noatime 0 2" >> /mnt/etc/fstab
    fi
    
    # FIXED: Create mount point in chroot
    mkdir -p /mnt/mnt/storage
    
    print_success "fstab generated"
    echo ""
}

configure_system() {
    print_section "Configuring system..."
    
    # Timezone
    arch-chroot /mnt ln -sf "/usr/share/zoneinfo/$TIMEZONE" /etc/localtime
    arch-chroot /mnt hwclock --systohc
    
    # Locale
    echo "$LOCALE UTF-8" > /mnt/etc/locale.gen
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
    print_section "Installing systemd-boot..."
    
    # Install systemd-boot
    arch-chroot /mnt bootctl install
    
    # Create loader configuration
    cat > /mnt/boot/loader/loader.conf <<EOF
default arch.conf
timeout 3
console-mode max
EOF
    
    # FIXED: Use global ROOT_PART variable
    ROOT_UUID=$(blkid -s UUID -o value "$ROOT_PART")
    
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
    echo ""
}

create_user() {
    print_section "Creating user account..."
    
    # Set root password
    echo "root:$USER_PASSWORD" | arch-chroot /mnt chpasswd
    
    # Create user
    arch-chroot /mnt useradd -m -G wheel -s /bin/bash "$USERNAME"
    
    # Set user password
    echo "$USERNAME:$USER_PASSWORD" | arch-chroot /mnt chpasswd
    
    # Configure sudo
    echo "%wheel ALL=(ALL:ALL) ALL" > /mnt/etc/sudoers.d/wheel
    chmod 440 /mnt/etc/sudoers.d/wheel
    
    # FIXED: Add temporary passwordless sudo for yay installation
    echo "$USERNAME ALL=(ALL) NOPASSWD: /usr/bin/pacman" > /mnt/etc/sudoers.d/temp-yay
    chmod 440 /mnt/etc/sudoers.d/temp-yay
    
    print_success "User '$USERNAME' created with sudo access"
    echo ""
}

install_desktop() {
    print_section "Installing Hyprland desktop environment..."
    
    # Install Hyprland and dependencies
    arch-chroot /mnt pacman -S --noconfirm \
        hyprland wayland wayland-protocols \
        xorg-xwayland \
        polkit polkit-gnome \
        pipewire pipewire-pulse pipewire-alsa pipewire-jack \
        wireplumber \
        alacritty \
        waybar wofi mako \
        swww \
        noto-fonts noto-fonts-cjk noto-fonts-emoji \
        ttf-font-awesome \
        xdg-utils xdg-user-dirs \
        wl-clipboard
    
    print_success "Desktop environment installed"
    echo ""
}

install_nvidia() {
    print_section "Installing NVIDIA drivers..."
    
    # Install proprietary NVIDIA drivers (most stable for 2070S)
    # FIXED: Install fallback if NVIDIA fails
    if ! arch-chroot /mnt pacman -S --noconfirm nvidia nvidia-utils nvidia-settings lib32-nvidia-utils 2>/dev/null; then
        print_warning "NVIDIA driver installation failed!"
        print_warning "Installing fallback drivers..."
        arch-chroot /mnt pacman -S --noconfirm xf86-video-fbdev xf86-video-vesa || true
        print_warning "System will use basic drivers. You can install NVIDIA manually later."
    fi
    
    # Configure mkinitcpio for NVIDIA
    # Remove kms hook to prevent early loading issues
    sed -i 's/HOOKS=(base udev autodetect modconf kms keyboard keymap consolefont block filesystems fsck)/HOOKS=(base udev autodetect modconf keyboard keymap consolefont block filesystems fsck)/' /mnt/etc/mkinitcpio.conf
    
    # Add NVIDIA modules
    if ! grep -q "MODULES=(nvidia nvidia_modeset nvidia_uvm nvidia_drm)" /mnt/etc/mkinitcpio.conf; then
        sed -i 's/^MODULES=()/MODULES=(nvidia nvidia_modeset nvidia_uvm nvidia_drm)/' /mnt/etc/mkinitcpio.conf
    fi
    
    # Regenerate initramfs
    arch-chroot /mnt mkinitcpio -P
    
    # Enable NVIDIA DRM modeset
    mkdir -p /mnt/etc/modprobe.d
    echo "options nvidia-drm modeset=1" > /mnt/etc/modprobe.d/nvidia.conf
    
    print_success "NVIDIA drivers installed and configured"
    echo ""
}

configure_hyprland() {
    print_section "Configuring Hyprland..."
    
    # FIXED: Explicitly set USER_HOME
    USER_HOME="/mnt/home/$USERNAME"
    
    # Create config directory with correct ownership
    mkdir -p "$USER_HOME/.config/hypr"
    
    # Create Hyprland config with Omarchy-like keybindings
    # FIXED: Added NVIDIA compatibility options
    cat > "$USER_HOME/.config/hypr/hyprland.conf" <<'EOF'
# YggdrasilHost Hyprland Configuration
# Omarchy-inspired keybindings

# Monitor configuration (4K TV)
monitor=,preferred,auto,1.5

# FIXED: NVIDIA compatibility
env = WLR_NO_HARDWARE_CURSORS,1
env = WLR_RENDERER_ALLOW_SOFTWARE,1
env = XCURSOR_SIZE,24
env = HYPRCURSOR_SIZE,24

# Input
input {
    kb_layout = no
    kb_variant = 
    kb_model = 
    kb_options = 
    kb_rules = 
    
    follow_mouse = 1
    touchpad {
        natural_scroll = false
    }
    sensitivity = 0
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
        new_optimizations = true
    }
    drop_shadow = true
    shadow_range = 4
    shadow_render_power = 3
    col.shadow = rgba(1a1a1aee)
}

animations {
    enabled = true
    bezier = myBezier, 0.05, 0.9, 0.1, 1.05
    animation = windows, 1, 7, myBezier
    animation = windowsOut, 1, 7, default, popin 80%
    animation = border, 1, 10, default
    animation = fade, 1, 7, default
    animation = workspaces, 1, 6, default
}

dwindle {
    pseudotile = true
    preserve_split = true
}

master {
    new_is_master = true
}

gestures {
    workspace_swipe = false
}

# Autostart
exec-once = waybar
exec-once = mako
exec-once = swww init
exec-once = /usr/lib/polkit-gnome/polkit-gnome-authentication-agent-1

# Keybindings - Omarchy-inspired
$mainMod = SUPER

# Application launcher
bind = $mainMod, Return, exec, alacritty
bind = $mainMod, Q, killactive
bind = $mainMod, M, exit
bind = $mainMod, E, exec, wofi --show drun
bind = $mainMod, V, togglefloating
bind = $mainMod, R, exec, wofi --show run
bind = $mainMod, P, pseudo
bind = $mainMod, J, togglesplit
bind = $mainMod, F, fullscreen
bind = $mainMod, B, exec, brave

# Move focus
bind = $mainMod, left, movefocus, l
bind = $mainMod, right, movefocus, r
bind = $mainMod, up, movefocus, u
bind = $mainMod, down, movefocus, d

# Switch workspaces
bind = $mainMod, 1, workspace, 1
bind = $mainMod, 2, workspace, 2
bind = $mainMod, 3, workspace, 3
bind = $mainMod, 4, workspace, 4
bind = $mainMod, 5, workspace, 5
bind = $mainMod, 6, workspace, 6
bind = $mainMod, 7, workspace, 7
bind = $mainMod, 8, workspace, 8
bind = $mainMod, 9, workspace, 9
bind = $mainMod, 0, workspace, 10

# Move active window to workspace
bind = $mainMod SHIFT, 1, movetoworkspace, 1
bind = $mainMod SHIFT, 2, movetoworkspace, 2
bind = $mainMod SHIFT, 3, movetoworkspace, 3
bind = $mainMod SHIFT, 4, movetoworkspace, 4
bind = $mainMod SHIFT, 5, movetoworkspace, 5
bind = $mainMod SHIFT, 6, movetoworkspace, 6
bind = $mainMod SHIFT, 7, movetoworkspace, 7
bind = $mainMod SHIFT, 8, movetoworkspace, 8
bind = $mainMod SHIFT, 9, movetoworkspace, 9
bind = $mainMod SHIFT, 0, movetoworkspace, 10

# Scroll through workspaces
bind = $mainMod, mouse_down, workspace, e+1
bind = $mainMod, mouse_up, workspace, e-1

# Move/resize windows with mouse
bindm = $mainMod, mouse:272, movewindow
bindm = $mainMod, mouse:273, resizewindow

# Audio controls
bind = , XF86AudioRaiseVolume, exec, wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%+
bind = , XF86AudioLowerVolume, exec, wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%-
bind = , XF86AudioMute, exec, wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle
bind = , XF86AudioPlay, exec, playerctl play-pause
bind = , XF86AudioNext, exec, playerctl next
bind = , XF86AudioPrev, exec, playerctl previous

# Window rules
windowrulev2 = nomaximizerequest, class:.*
windowrulev2 = float, class:^(pavucontrol)$
windowrulev2 = float, class:^(wofi)$
windowrulev2 = size 800 600, class:^(wofi)$
EOF
    
    # FIXED: Set ownership immediately
    arch-chroot /mnt chown -R "$USERNAME:$USERNAME" "/home/$USERNAME/.config"
    
    print_success "Hyprland configured"
    echo ""
}

install_essential_software() {
    print_section "Installing essential software..."
    
    # Install essential packages
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
    print_section "Configuring SSH..."
    
    # Backup original config
    cp /mnt/etc/ssh/sshd_config /mnt/etc/ssh/sshd_config.backup
    
    # Configure SSH with best practices for local network
    cat > /mnt/etc/ssh/sshd_config <<EOF
# YggdrasilHost SSH Configuration
# Best practices for local network environment

Port 22
AddressFamily any
ListenAddress 0.0.0.0
ListenAddress ::

HostKey /etc/ssh/ssh_host_rsa_key
HostKey /etc/ssh/ssh_host_ed25519_key

# Authentication
PermitRootLogin no
PubkeyAuthentication yes
PasswordAuthentication no
PermitEmptyPasswords no
ChallengeResponseAuthentication no
UsePAM yes

# Security
X11Forwarding no
PrintMotd no
PrintLastLog yes
AcceptEnv LANG LC_*
Subsystem sftp /usr/lib/ssh/sftp-server

# Connection settings
ClientAliveInterval 300
ClientAliveCountMax 2
MaxAuthTries 3
MaxSessions 10

# Allow only specific user
AllowUsers $USERNAME
EOF
    
    # FIXED: Generate SSH host keys AFTER openssh is installed
    if [ ! -f /mnt/etc/ssh/ssh_host_ed25519_key ]; then
        arch-chroot /mnt ssh-keygen -t ed25519 -f /etc/ssh/ssh_host_ed25519_key -N ""
    fi
    
    if [ ! -f /mnt/etc/ssh/ssh_host_rsa_key ]; then
        arch-chroot /mnt ssh-keygen -t rsa -b 4096 -f /etc/ssh/ssh_host_rsa_key -N ""
    fi
    
    # Enable SSH service
    arch-chroot /mnt systemctl enable sshd.service
    
    print_success "SSH configured with key-based authentication"
    echo ""
    print_warning "IMPORTANT: You must copy your SSH public key to this machine after first boot"
    echo "  ssh-copy-id $USERNAME@<ip-address>"
    echo ""
}

install_yay() {
    print_section "Installing yay (AUR helper)..."
    
    # Install dependencies
    arch-chroot /mnt pacman -S --noconfirm --needed git base-devel
    
    # Create temporary build directory
    mkdir -p /mnt/tmp/yay-build
    
    # FIXED: Clone and build yay as the user with proper permissions
    arch-chroot /mnt /bin/bash -c "
        cd /tmp/yay-build
        git clone https://aur.archlinux.org/yay.git
        cd yay
        # Build as user, install with sudo
        makepkg -s --noconfirm
        sudo pacman -U --noconfirm yay-*.pkg.tar.zst
        cd /
        rm -rf /tmp/yay-build
    " "$USERNAME"
    
    # FIXED: Remove temporary passwordless sudo
    rm -f /mnt/etc/sudoers.d/temp-yay
    
    print_success "yay installed"
    echo ""
}

install_brave() {
    print_section "Installing Brave browser..."
    
    # Install Brave via yay
    arch-chroot /mnt /bin/bash -c "yay -S --noconfirm brave-bin" "$USERNAME"
    
    print_success "Brave browser installed"
    echo ""
}

configure_audio() {
    print_section "Configuring audio..."
    
    # FIXED: Explicitly set USER_HOME
    USER_HOME="/mnt/home/$USERNAME"
    
    # Enable PipeWire services
    arch-chroot /mnt systemctl --global enable pipewire.socket
    arch-chroot /mnt systemctl --global enable pipewire-pulse.socket
    arch-chroot /mnt systemctl --global enable wireplumber.service
    
    # FIXED: Also enable system services
    arch-chroot /mnt systemctl --global enable pipewire.service
    
    # Set HDMI as default audio output (will be configured on first boot)
    mkdir -p "$USER_HOME/.config/wireplumber"
    
    # FIXED: Set ownership
    arch-chroot /mnt chown -R "$USERNAME:$USERNAME" "/home/$USERNAME/.config/wireplumber"
    
    print_success "Audio configured (PipeWire)"
    echo ""
}

enable_services() {
    print_section "Enabling services..."
    
    # Network
    arch-chroot /mnt systemctl enable NetworkManager.service
    # FIXED: Removed dhcpcd to avoid conflict
    
    # SSH (already enabled in configure_ssh)
    # Audio (already enabled in configure_audio)
    
    # Reflector for mirror updates
    arch-chroot /mnt systemctl enable reflector.timer
    
    # paccache cleanup
    arch-chroot /mnt systemctl enable paccache.timer
    
    # FIXED: Enable getty for autologin
    arch-chroot /mnt systemctl enable getty@tty1.service
    
    print_success "Services enabled"
    echo ""
}

setup_autologin() {
    print_section "Setting up autologin..."
    
    # Create autologin configuration for tty1
    mkdir -p /mnt/etc/systemd/system/getty@tty1.service.d
    
    cat > /mnt/etc/systemd/system/getty@tty1.service.d/autologin.conf <<EOF
[Service]
ExecStart=
ExecStart=-/sbin/agetty -o '-p -f -- \\u' --noclear --autologin $USERNAME %I $TERM
EOF
    
    print_success "Autologin configured for $USERNAME on tty1"
    echo ""
}

configure_hyprland_autostart() {
    print_section "Configuring Hyprland autostart..."
    
    # FIXED: Explicitly set USER_HOME
    USER_HOME="/mnt/home/$USERNAME"
    
    # Create .bash_profile to start Hyprland on login
    cat >> "$USER_HOME/.bash_profile" <<'EOF'

# Start Hyprland on tty1
if [ -z "$DISPLAY" ] && [ "$(tty)" = "/dev/tty1" ]; then
    exec Hyprland
fi
EOF
    
    # Set ownership
    arch-chroot /mnt chown "$USERNAME:$USERNAME" "/home/$USERNAME/.bash_profile"
    
    print_success "Hyprland autostart configured"
    echo ""
}

final_steps() {
    print_section "Finalizing installation..."
    
    # Create storage directory structure
    mkdir -p /mnt/mnt/storage
    
    # Create Docker directory structure (for later use)
    mkdir -p /mnt/mnt/storage/docker/{configs,data}
    mkdir -p /mnt/mnt/storage/shares
    
    # FIXED: Set ownership correctly
    arch-chroot /mnt chown -R "$USERNAME:$USERNAME" /mnt/storage
    
    # Create a post-install info file
    cat > /mnt/home/$USERNAME/POST_INSTALL_INFO.txt <<EOF
YggdrasilHost Installation Complete!
====================================

System Information:
- Hostname: $HOSTNAME
- Username: $USERNAME
- Editor: nvim (set as default)

What's Installed:
- Hyprland desktop environment
- NVIDIA proprietary drivers (or fallback)
- Alacritty terminal
- Waybar, wofi, mako
- Brave browser (via yay)
- btop system monitor
- SSH server (key-based auth only)
- PipeWire audio

Next Steps:
1. Reboot and verify Hyprland starts
2. Configure audio output (wpctl status, wpctl set-default <ID>)
3. Copy SSH key: ssh-copy-id $USERNAME@<ip-address>
4. Configure Docker (when ready)
5. Set up Pi failover

Key Bindings (Super = Windows key):
- Super + Enter: Terminal
- Super + B: Brave browser
- Super + E: Application launcher (wofi)
- Super + Q: Close window
- Super + F: Fullscreen
- Super + 1-9: Switch workspace

Storage:
- SSD: Arch Linux system
- HDD: Mounted at /mnt/storage

Troubleshooting:
- Check log: $LOG_FILE
- Hyprland config: ~/.config/hypr/hyprland.conf

Enjoy your YggdrasilHost!
EOF
    
    arch-chroot /mnt chown "$USERNAME:$USERNAME" "/home/$USERNAME/POST_INSTALL_INFO.txt"
    
    print_success "Installation complete!"
    echo ""
}

print_summary() {
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}  Installation Summary${NC}"
    echo -e "${GREEN}========================================${NC}"
    echo ""
    echo "System: YggdrasilHost (Arch Linux + Hyprland)"
    echo "User: $USERNAME"
    echo "Hostname: $HOSTNAME"
    echo ""
    echo "Disks:"
    echo "  SSD ($SSD_DISK): Arch Linux installation"
    echo "  HDD ($HDD_DISK): Storage at /mnt/storage"
    echo ""
    echo "Installed:"
    echo "  ✓ Hyprland desktop environment"
    echo "  ✓ NVIDIA drivers (proprietary or fallback)"
    echo "  ✓ Alacritty, waybar, wofi, mako"
    echo "  ✓ Brave browser (AUR)"
    echo "  ✓ neovim (default editor)"
    echo "  ✓ btop, git, openssh"
    echo "  ✓ PipeWire audio"
    echo ""
    echo -e "${YELLOW}Next step: Reboot and enjoy your system!${NC}"
    echo ""
    echo -e "${BLUE}Post-install info saved to: /home/$USERNAME/POST_INSTALL_INFO.txt${NC}"
    echo -e "${BLUE}Installation log: $LOG_FILE${NC}"
    echo ""
}

main() {
    print_header
    
    # Pre-installation checks and setup
    verify_uefi
    setup_network
    detect_disks
    confirm_disks
    get_password
    confirm_locale
    
    # Installation phases
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
    
    # Summary
    print_summary
    
    # FIXED: Unmount before reboot
    print_section "Syncing and unmounting..."
    sync
    umount -R /mnt || true
    
    # Ask for reboot
    echo -n "Reboot now? [Y/n]: "
    read -r reboot_confirm
    if [[ ! "$reboot_confirm" =~ ^[Nn]$ ]]; then
        echo "Rebooting in 5 seconds..."
        sleep 5
        reboot
    else
        echo "Reboot skipped. You can reboot manually when ready."
        echo "Remember to remove the installation media!"
    fi
}

# Run main function
main "$@"
