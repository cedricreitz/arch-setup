#!/bin/bash
# Arch Linux Installation Script with Hyprland Setup (post-install script pulled from GitHub)

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

print_status() { echo -e "${BLUE}[INFO]${NC} $1"; }
print_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1"; }

prompt_input() {
    local prompt="$1" var_name="$2" default="$3"
    if [ -n "$default" ]; then
        read -p "$prompt [$default]: " input
        eval "$var_name=\"\${input:-$default}\""
    else
        read -p "$prompt: " input
        eval "$var_name=\"$input\""
    fi
}

prompt_password() {
    local prompt="$1" var_name="$2" pass pass2
    while true; do
        read -s -p "$prompt: " pass; echo
        read -s -p "Confirm password: " pass2; echo
        [ "$pass" = "$pass2" ] && { eval "$var_name=\"$pass\""; break; }
        print_error "Passwords do not match. Try again."
    done
}

# Check if running as root
check_root() {
    if [ "$EUID" -ne 0 ]; then
        print_error "This script must be run as root"
        exit 1
    fi
}

check_internet() { ping -c 1 archlinux.org &>/dev/null || { print_error "No internet"; exit 1; }; }
update_clock() { timedatectl set-ntp true; }

list_disks() { lsblk -dp -o NAME,SIZE,MODEL | grep -E "^/dev/(sd|nvme|vd)"; }

partition_disk() {
    local disk="$1"
    print_status "Partitioning $disk..."
    read -p "This will erase ALL data. Continue? (yes/no): " confirm
    [ "$confirm" != "yes" ] && exit 1
    umount -R /mnt 2>/dev/null || true
    wipefs -af "$disk"
    parted -s "$disk" mklabel gpt
    parted -s "$disk" mkpart primary fat32 1MiB 513MiB
    parted -s "$disk" set 1 esp on
    parted -s "$disk" mkpart primary ext4 513MiB 100%

    if [[ "$disk" == *"nvme"* ]]; then
        EFI_PART="${disk}p1"
        CRYPT_PART="${disk}p2"
    else
        EFI_PART="${disk}1"
        CRYPT_PART="${disk}2"
    fi

    sleep 2 && partprobe "$disk" && sleep 2

    echo -n "$PASSWORD" | cryptsetup luksFormat "$CRYPT_PART" -
    echo -n "$PASSWORD" | cryptsetup open "$CRYPT_PART" cryptroot -
}

format_partitions() {
    mkfs.fat -F32 -n EFI "$EFI_PART"
    mkfs.ext4 -L ROOT /dev/mapper/cryptroot
}

mount_partitions() {
    mount /dev/mapper/cryptroot /mnt
    mkdir -p /mnt/boot
    mount "$EFI_PART" /mnt/boot
}

install_base_system() {
    pacman -Sy --noconfirm archlinux-keyring
    pacstrap /mnt base base-devel linux-zen linux-zen-headers linux-firmware networkmanager \
             os-prober ntfs-3g dosfstools mtools nano sudo git curl wget \
             pipewire pipewire-alsa pipewire-pulse pipewire-jack wireplumber zsh \
             wayland xorg-xwayland hyprland hyprpaper hyprlock waybar swaync \
             rofi-wayland thunar nwg-look kitty polkit hyprpolkitagent \
             ttf-jetbrains-mono-nerd pavucontrol playerctl brightnessctl grim slurp \
             wl-clipboard papirus-icon-theme lsd blueman jq fzf \
             zoxide bat usbutils fprintd gtk-engine-murrine cantarell-fonts plymouth lzip \
             seahorse gnome-keyring libsecret libnewt uwsm qt5-wayland qt6-wayland
}

generate_fstab() {
    genfstab -U /mnt >> /mnt/etc/fstab
}

download_post_install_script() {
    local script_url="https://raw.githubusercontent.com/cedricreitz/arch-setup/refs/heads/main/post-install.sh"
    print_status "Downloading post-install script..."
    mkdir -p "/mnt/home/$USERNAME"
    curl -fsSL "$script_url" -o "/mnt/home/$USERNAME/post-install.sh"
    arch-chroot /mnt chown "$USERNAME:$USERNAME" "/home/$USERNAME/post-install.sh"
    arch-chroot /mnt chmod +x "/home/$USERNAME/post-install.sh"
}


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
    list_disks

    prompt_input "Disk to install to" DISK
    prompt_input "Timezone" TIMEZONE "Europe/Berlin"
    prompt_input "Locale" LOCALE "en_US"
    prompt_input "Keymap" KEYMAP "de-latin1"
    prompt_input "Hostname" HOSTNAME "archlinux"
    prompt_input "Username" USERNAME "user"
    prompt_password "Password" PASSWORD

    partition_disk "$DISK"
    format_partitions
    mount_partitions
    install_base_system
    generate_fstab

    UUID_CRYPT=$(blkid -s UUID -o value "$CRYPT_PART")
    ROOT_UUID=$(blkid -s UUID -o value /dev/mapper/cryptroot)
    CATPUCCIN_TTY="vt.default_red=30,243,166,249,137,245,148,186,88,243,166,249,137,245,148,166 vt.default_grn=30,139,227,226,180,194,226,194,91,139,227,226,180,194,226,173 vt.default_blu=46,168,161,175,250,231,213,222,112,168,161,175,250,231,213,200"

    # Create minimal user + root config so post-install can run
    arch-chroot /mnt /bin/bash -c "
        ln -sf /usr/share/zoneinfo/$TIMEZONE /etc/localtime
        hwclock --systohc
        echo \"$LOCALE.UTF-8 UTF-8\" >> /etc/locale.gen
        locale-gen
        echo \"LANG=$LOCALE.UTF-8\" > /etc/locale.conf
        echo \"KEYMAP=$KEYMAP\" > /etc/vconsole.conf
        echo \"$HOSTNAME\" > /etc/hostname
        echo \"root:$PASSWORD\" | chpasswd
        useradd -m -G wheel,audio,video,optical,storage -s /bin/zsh \"$USERNAME\"
        echo \"$USERNAME:$PASSWORD\" | chpasswd
        sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) NOPASSWD: ALL/' /etc/sudoers
        systemctl enable NetworkManager

        # Add encrypt hook to mkinitcpio
        sed -i 's/^HOOKS=.*/HOOKS=(base udev autodetect microcode modconf kms keyboard keymap consolefont block plymouth encrypt filesystems fsck)/' /etc/mkinitcpio.conf
        mkinitcpio -P
        bootctl install

        # Create boot entry
        cat > /boot/loader/entries/arch.conf << EOL
        title   Arch Linux
        linux   /vmlinuz-linux-zen
        initrd  /initramfs-linux-zen.img
        options cryptdevice=UUID=$UUID_CRYPT:cryptroot root=UUID=$ROOT_UUID rw quiet splash nr_ttys=1 loglevel=3 acpi.debug_level=0 $CATPUCCIN_TTY
        EOL

        # Configure boot loader
        cat > /boot/loader/loader.conf << EOL
        default arch
        timeout 3
        console-mode max
        editor  no
        EOL

        # Configure autologin
        mkdir -p /etc/systemd/system/getty@tty1.service.d
        cat >/etc/systemd/system/getty@tty1.service.d/autologin.conf << EOL
        [Service]
        ExecStart=
        ExecStart=-/sbin/agetty --autologin $USERNAME --noclear %I $TERM
        EOL
        systemctl enable getty@tty1.service
    "

    download_post_install_script

    print_success "Installation complete. Reboot into your new system."
    read -p "Reboot now? (yes/no): " rb
    [ "$rb" = "yes" ] && { umount -R /mnt; reboot; }
}

main "$@"
