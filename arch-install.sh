#!/bin/bash

# Arch Linux Installation Script with Hyprland Setup
# Run this script from the Arch Linux installation ISO

set -e  # Exit on any error

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Function to print colored output
print_status() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Function to prompt for user input
prompt_input() {
    local prompt="$1"
    local var_name="$2"
    local default="$3"
    
    if [ -n "$default" ]; then
        read -p "$prompt [$default]: " input
        eval "$var_name=\"\${input:-$default}\""
    else
        read -p "$prompt: " input
        eval "$var_name=\"$input\""
    fi
}

# Function to prompt for password
prompt_password() {
    local prompt="$1"
    local var_name="$2"
    local password
    local password_confirm
    
    while true; do
        read -s -p "$prompt: " password
        echo
        read -s -p "Confirm password: " password_confirm
        echo
        
        if [ "$password" = "$password_confirm" ]; then
            eval "$var_name=\"$password\""
            break
        else
            print_error "Passwords do not match. Please try again."
        fi
    done
}

# Check if running as root
check_root() {
    if [ "$EUID" -ne 0 ]; then
        print_error "This script must be run as root"
        exit 1
    fi
}

# Check internet connection
check_internet() {
    print_status "Checking internet connection..."
    if ping -c 1 archlinux.org &> /dev/null; then
        print_success "Internet connection is working"
    else
        print_error "No internet connection. Please check your network settings."
        exit 1
    fi
}

# Update system clock
update_clock() {
    print_status "Updating system clock..."
    timedatectl set-ntp true
    print_success "System clock updated"
}

# List available disks
list_disks() {
    print_status "Available disks:"
    lsblk -dp -o NAME,SIZE,MODEL | grep -E "^/dev/(sd|nvme|vd)"
}

# Partition disk
partition_disk() {
    local disk="$1"
    
    print_status "Partitioning disk $disk..."
    print_warning "This will DESTROY ALL DATA on $disk!"
    
    read -p "Are you sure you want to continue? (yes/no): " confirm
    if [ "$confirm" != "yes" ]; then
        print_error "Aborted by user"
        exit 1
    fi
    
    # Unmount any existing partitions
    umount -R /mnt 2>/dev/null || true
    
    # Wipe disk
    wipefs -af "$disk"
    
    # Create GPT partition table
    parted -s "$disk" mklabel gpt
    
    # Create partitions
    parted -s "$disk" mkpart primary fat32 1MiB 513MiB      # EFI partition (512MB)
    parted -s "$disk" set 1 esp on
    parted -s "$disk" mkpart primary ext4 513MiB 100%    
    print_success "Disk partitioned successfully"

        
    # Set partition variables based on disk type
    if [[ "$disk" == *"nvme"* ]]; then
        EFI_PART="${disk}p1"
        CRYPT_PART="${disk}2"
    else
        EFI_PART="${disk}1"
        CRYPT_PART="${disk}2"
    fi

       
    # Wait for partitions to be recognized
    sleep 2
    partprobe "$disk"
    sleep 2

    print_status "Setting up LUKS encryption..."
    echo -n "$PASSWORD" | cryptsetup luksFormat "$CRYPT_PART" -
    echo -n "$PASSWORD" | cryptsetup open "$CRYPT_PART" cryptroot -
}

# Format partitions
format_partitions() {
    print_status "Formatting partitions..."
    
    # Format EFI partition
    mkfs.fat -F32 -n EFI "$EFI_PART"
    
    # Format encrypted partition
    mkfs.ext4 -L ROOT /dev/mapper/cryptroot    
    print_success "Partitions formatted successfully"
}

# Mount partitions
mount_partitions() {
    print_status "Mounting partitions..."
    
    # Mount root
    mount /dev/mapper/cryptroot /mnt
    
    # Create mount points
    mkdir -p /mnt/boot
    
    # Mount EFI
    mount "$EFI_PART" /mnt/boot
    
    print_success "Partitions mounted successfully"
}

# Install base system
install_base_system() {
    print_status "Installing base system..."
    
    # Update keyring
    pacman -Sy --noconfirm archlinux-keyring
    
    # Install base packages with zen kernel
    pacstrap /mnt base base-devel linux-zen linux-zen-headers linux-firmware networkmanager \
             os-prober ntfs-3g dosfstools mtools nano sudo git curl wget \
             pipewire pipewire-alsa pipewire-pulse pipewire-jack wireplumber zsh
    
    print_success "Base system installed"
}

# Generate fstab
generate_fstab() {
    print_status "Generating fstab..."
    genfstab -U /mnt >> /mnt/etc/fstab
    print_success "fstab generated"
}

# Configure system in chroot
configure_system() {
    print_status "Configuring system..."
    
    # Create configuration script for chroot
    cat > /mnt/configure_system.sh << 'EOF'
#!/bin/bash


sed -i 's/^HOOKS=.*/HOOKS=(base udev autodetect keyboard keymap consolefont modconf block encrypt filesystems fsck)/' /etc/mkinitcpio.conf
mkinitcpio -P

# Set timezone
ln -sf /usr/share/zoneinfo/$TIMEZONE /etc/localtime
hwclock --systohc

# Set locale
echo "$LOCALE.UTF-8 UTF-8" >> /etc/locale.gen
locale-gen
echo "LANG=$LOCALE.UTF-8" > /etc/locale.conf

# Set keyboard layout
echo "KEYMAP=$KEYMAP" > /etc/vconsole.conf

# Set hostname
echo "$HOSTNAME" > /etc/hostname

# Configure hosts file
cat > /etc/hosts << EOL
127.0.0.1   localhost
::1         localhost
127.0.1.1   $HOSTNAME.localdomain $HOSTNAME
EOL

# Set root password
echo "root:$PASSWORD" | chpasswd

# Create user
useradd -m -G wheel,audio,video,optical,storage -s /bin/zsh "$USERNAME"
echo "$USERNAME:$PASSWORD" | chpasswd

# Configure sudo
sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers

# Enable NetworkManager
systemctl enable NetworkManager

# Configure systemd-boot
bootctl install

# Get the UUID of the root partition
UUID_CRYPT=$(blkid -s UUID -o value $CRYPT_PART)
ROOT_UUID=$(blkid -s UUID -o value /dev/mapper/cryptroot)

# Create boot entry
cat > /boot/loader/entries/arch.conf << EOL
title   Arch Linux
linux   /vmlinuz-linux-zen
initrd  /initramfs-linux-zen.img
options cryptdevice=UUID=$UUID_CRYPT:cryptroot root=UUID=$ROOT_UUID rw
EOL

# Configure boot loader
cat > /boot/loader/loader.conf << EOL
default arch
timeout 3
console-mode max
editor  no
EOL

EOF

    # Pass variables to script
    sed -i "s|\$TIMEZONE|$TIMEZONE|g" /mnt/configure_system.sh
    sed -i "s|\$LOCALE|$LOCALE|g" /mnt/configure_system.sh
    sed -i "s|\$KEYMAP|$KEYMAP|g" /mnt/configure_system.sh
    sed -i "s|\$HOSTNAME|$HOSTNAME|g" /mnt/configure_system.sh
    sed -i "s|\$USERNAME|$USERNAME|g" /mnt/configure_system.sh
    sed -i "s|\$PASSWORD|$PASSWORD|g" /mnt/configure_system.sh
    sed -i "s|\$ROOT_PART|$ROOT_PART|g" /mnt/configure_system.sh

    # Make script executable and run in chroot
    chmod +x /mnt/configure_system.sh
    arch-chroot /mnt /configure_system.sh
    rm /mnt/configure_system.sh
    
    print_success "System configured"
}

# Extended system setup with Hyprland
setup_extended_system() {
    print_status "Setting up extended system with Hyprland..."
    
    # Create extended setup script for chroot
    cat > /mnt/setup_extended.sh << 'EOF'
#!/bin/bash

# Update system
pacman -Syu --noconfirm

# Install essential packages
pacman -S --noconfirm wayland xorg-xwayland hyprland hyprpaper hyprlock waybar swaync \
                      rofi-wayland thunar nwg-look kitty polkit hyprpolkitagent \
                      ttf-jetbrains-mono-nerd pipewire-pulse wireplumber \
                      pavucontrol playerctl brightnessctl grim slurp \
                      wl-clipboard papirus-icon-theme lsd blueman jq fzf \
                      zoxide bat

# Install AUR helper (yay)
cd /tmp
sudo -u $USERNAME git clone https://aur.archlinux.org/yay.git
cd yay
sudo -u $USERNAME makepkg -si --noconfirm
cd /

# Install AUR packages as user
sudo -u $USERNAME yay -S --noconfirm visual-studio-code-bin goxlr-utility-bin google-chrome-bin

# Setup Oh My Zsh for user
sudo -u $USERNAME sh -c "$(curl -fsSL https://raw.github.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended

# Install powerlevel10k
sudo -u $USERNAME git clone --depth=1 https://github.com/romkatv/powerlevel10k.git /home/$USERNAME/.oh-my-zsh/custom/themes/powerlevel10k

# Install zsh plugins
sudo -u $USERNAME git clone https://github.com/zsh-users/zsh-autosuggestions /home/$USERNAME/.oh-my-zsh/custom/plugins/zsh-autosuggestions
sudo -u $USERNAME git clone https://github.com/zsh-users/zsh-syntax-highlighting.git /home/$USERNAME/.oh-my-zsh/custom/plugins/zsh-syntax-highlighting

sudo -u $USERNAME git clone --depth=1 https://github.com/marlonrichert/zsh-autocomplete.git /home/$USERNAME/.oh-my-zsh/custom/plugins/zsh-autocomplete


# Configure .zshrc
cat > /home/$USERNAME/.zshrc << 'ZSHEOF'
export ZSH="$HOME/.oh-my-zsh"
ZSH_THEME="powerlevel10k/powerlevel10k"
plugins=(git zsh-autosuggestions zsh-syntax-highlighting zsh-autocomplete)
source $ZSH/oh-my-zsh.sh

alias cat="bat"
alias cd="z"
alias cl="clear"
alias ls="lsd"
ZSHEOF
chown $USERNAME:$USERNAME /home/$USERNAME/.zshrc

# Configure PAM for hyprlock
cat << 'PAMCONF' > /etc/pam.d/hyprlock
#%PAM-1.0
auth     include   login
account  include   login
password include   login
session  include   login
PAMCONF

# Enable autologin on tty1 for $USERNAME
mkdir -p /etc/systemd/system/getty@tty1.service.d
cat << AUTOLOGIN > /etc/systemd/system/getty@tty1.service.d/override.conf
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin $USERNAME --noclear %I \$TERM
AUTOLOGIN

# Create systemd user service for Hyprland
sudo -u $USERNAME mkdir -p /home/$USERNAME/.config/systemd/user
cat << 'HYPRSVC' > /home/$USERNAME/.config/systemd/user/hyprland.service
[Unit]
Description=Hyprland Wayland compositor
After=graphical.target

[Service]
ExecStart=/usr/bin/Hyprland
Restart=always
RestartSec=1
Environment=DISPLAY=:0
Environment=XDG_RUNTIME_DIR=/run/user/%U
TTYPath=/dev/tty1
TTYReset=yes
TTYVHangup=yes
StandardInput=tty
WorkingDirectory=%h

[Install]
WantedBy=default.target
HYPRSVC

# Enable Hyprland systemd user service for $USERNAME
sudo -u $USERNAME systemctl --user enable hyprland.service

# Disable other TTYs
sudo systemctl mask getty@tty2.service getty@tty3.service getty@tty4.service getty@tty5.service getty@tty6.service


# Enable services
systemctl enable pipewire
systemctl enable wireplumber


sudo -u $USERNAME git clone --depth=1 https://github.com/cedricreitz/arch-setup.git /home/$USERNAME/arch-auto-setup
sudo -u $USERNAME cp -r /home/$USERNAME/arch-auto-setup/.config /home/$USERNAME/.config
rm -rf /home/$USERNAME/arch-auto-setup
chown -R $USERNAME:$USERNAME /home/$USERNAME/.config

echo "Extended setup completed!"
EOF

    # Pass username to script
    sed -i "s|\$USERNAME|$USERNAME|g" /mnt/setup_extended.sh
    
    # Make script executable and run in chroot
    chmod +x /mnt/setup_extended.sh
    arch-chroot /mnt /setup_extended.sh
    rm /mnt/setup_extended.sh
    
    print_success "Extended system setup completed"
}

# Main installation function
main() {
    clear
    echo "========================================="
    echo "    Arch Linux Installation Script"
    echo "         with Hyprland Setup"
    echo "========================================="
    echo
    
    check_root
    check_internet
    update_clock
    
    # Get user input
    list_disks
    echo
    prompt_input "Enter the disk to install to (e.g., /dev/sda, /dev/nvme0n1)" DISK
    prompt_input "Enter timezone" TIMEZONE "Europe/Berlin"
    prompt_input "Enter locale" LOCALE "en_US"
    prompt_input "Enter keyboard layout" KEYMAP "de-latin1"
    prompt_input "Enter hostname" HOSTNAME "archlinux"
    prompt_input "Enter username" USERNAME "user"
    prompt_password "Enter root password" ROOT_PASSWORD
    prompt_password "Enter user password" USER_PASSWORD
    
    echo
    read -p "Do you want to install the extended system (Hyprland, AUR packages, etc.)? (yes/no): " INSTALL_EXTENDED
    
    echo
    print_status "Starting installation with the following settings:"
    echo "Disk: $DISK"
    echo "Timezone: $TIMEZONE"
    echo "Locale: $LOCALE"
    echo "Keymap: $KEYMAP"
    echo "Hostname: $HOSTNAME"
    echo "Username: $USERNAME"
    echo "Extended setup: $INSTALL_EXTENDED"
    echo
    
    read -p "Continue with installation? (yes/no): " confirm
    if [ "$confirm" != "yes" ]; then
        print_error "Installation aborted"
        exit 1
    fi
    
    # Perform installation
    partition_disk "$DISK"
    format_partitions
    mount_partitions
    install_base_system
    generate_fstab
    configure_system
    
    # Install extended system if requested
    if [ "$INSTALL_EXTENDED" = "yes" ]; then
        setup_extended_system
    fi
    
    echo
    print_success "========================================="
    print_success "    Installation completed successfully!"
    print_success "========================================="
    echo
    print_status "You can now reboot into your new Arch Linux system."
    if [ "$INSTALL_EXTENDED" = "yes" ]; then
        print_status "Hyprland is installed. Start it with 'Hyprland' after login."
        print_status "Configure powerlevel10k with 'p10k configure'"
    fi
    print_status "Don't forget to remove the installation media."
    echo
    read -p "Reboot now? (yes/no): " reboot_confirm
    if [ "$reboot_confirm" = "yes" ]; then
        umount -R /mnt
        reboot
    fi
}

# Run main function
main "$@"
