#!/bin/bash
set -e

# Detect username (first home dir found if not explicitly passed)
USERNAME=$(ls /home | head -n 1)

echo "[INFO] Running post-install for user: $USERNAME"

# ---------------------------
# 1. System update
# ---------------------------
echo "[INFO] Updating system..."
pacman -Syu --noconfirm

# ---------------------------
# 2. Install yay (AUR helper)
# ---------------------------
echo "[INFO] Installing yay..."
cd /tmp
sudo -u "$USERNAME" git clone https://aur.archlinux.org/yay.git
cd yay
sudo -u "$USERNAME" makepkg -si --noconfirm
cd /
rm -rf /tmp/yay

# ---------------------------
# 3. Install AUR packages as user
# ---------------------------
echo "[INFO] Installing AUR packages..."
sudo -u "$USERNAME" yay -S --noconfirm \
    visual-studio-code-bin \
    goxlr-utility-bin \
    google-chrome-bin

# ---------------------------
# 4. Setup Oh My Zsh for user
# ---------------------------
echo "[INFO] Installing Oh My Zsh..."
sudo -u "$USERNAME" sh -c "$(curl -fsSL https://raw.github.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended

# Powerlevel10k theme
sudo -u "$USERNAME" git clone --depth=1 https://github.com/romkatv/powerlevel10k.git \
    /home/$USERNAME/.oh-my-zsh/custom/themes/powerlevel10k

# Zsh plugins
sudo -u "$USERNAME" git clone https://github.com/zsh-users/zsh-autosuggestions \
    /home/$USERNAME/.oh-my-zsh/custom/plugins/zsh-autosuggestions
sudo -u "$USERNAME" git clone https://github.com/zsh-users/zsh-syntax-highlighting.git \
    /home/$USERNAME/.oh-my-zsh/custom/plugins/zsh-syntax-highlighting
sudo -u "$USERNAME" git clone --depth=1 https://github.com/marlonrichert/zsh-autocomplete.git \
    /home/$USERNAME/.oh-my-zsh/custom/plugins/zsh-autocomplete

# Configure .zshrc
cat > /home/$USERNAME/.zshrc << 'EOF'
export ZSH="$HOME/.oh-my-zsh"
ZSH_THEME="powerlevel10k/powerlevel10k"
plugins=(git zsh-autosuggestions zsh-syntax-highlighting zsh-autocomplete)
source $ZSH/oh-my-zsh.sh

alias cat="bat"
alias cd="z"
alias cl="clear"
alias ls="lsd"
EOF
chown $USERNAME:$USERNAME /home/$USERNAME/.zshrc

# ---------------------------
# 5. PAM config for hyprlock
# ---------------------------
echo "[INFO] Configuring PAM for hyprlock..."
cat << 'PAMCONF' > /etc/pam.d/hyprlock
#%PAM-1.0
auth     include   login
account  include   login
password include   login
session  include   login
PAMCONF

# ---------------------------
# 6. Enable autologin on tty1
# ---------------------------
echo "[INFO] Setting up autologin on tty1..."
mkdir -p /etc/systemd/system/getty@tty1.service.d
cat << AUTOLOGIN > /etc/systemd/system/getty@tty1.service.d/override.conf
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin $USERNAME --noclear %I \$TERM
AUTOLOGIN

# ---------------------------
# 7. Create systemd user service for Hyprland
# ---------------------------
echo "[INFO] Creating Hyprland systemd user service..."
sudo -u "$USERNAME" mkdir -p /home/$USERNAME/.config/systemd/user
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
chown -R $USERNAME:$USERNAME /home/$USERNAME/.config

# Enable Hyprland service for the user
sudo -u "$USERNAME" systemctl --user enable hyprland.service

# ---------------------------
# 8. Disable unused TTYs
# ---------------------------
echo "[INFO] Disabling unused TTYs..."
systemctl mask getty@tty2.service getty@tty3.service getty@tty4.service \
               getty@tty5.service getty@tty6.service

# ---------------------------
# 9. Enable essential services
# ---------------------------
echo "[INFO] Enabling essential services..."
systemctl enable NetworkManager
systemctl enable pipewire
systemctl enable wireplumber

# ---------------------------
# 10. Copy user configs from GitHub
# ---------------------------
echo "[INFO] Copying Hyprland configs..."
sudo -u "$USERNAME" git clone --depth=1 https://github.com/cedricreitz/arch-setup.git \
    /home/$USERNAME/arch-auto-setup
sudo -u "$USERNAME" cp -r /home/$USERNAME/arch-auto-setup/.config /home/$USERNAME/.config
rm -rf /home/$USERNAME/arch-auto-setup
chown -R $USERNAME:$USERNAME /home/$USERNAME/.config

echo "[SUCCESS] Post-install setup completed!"
