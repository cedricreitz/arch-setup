#!/bin/bash
set -e

# Detect SUDO_USER (first home dir found if not explicitly passed)
SUDO_USER=$(ls /home | head -n 1)

echo "[INFO] Running post-install for user: $SUDO_USER"

# Helper function to check if package is installed
is_package_installed() {
    pacman -Qi "$1" &>/dev/null
}

# Helper function to check if AUR package is installed
is_aur_package_installed() {
    sudo -u "$SUDO_USER" yay -Qi "$1" &>/dev/null 2>&1
}

# Helper function to check if systemd service exists and is enabled
is_service_enabled() {
    local service="$1"
    local user_service="$2"
    
    if [[ "$user_service" == "true" ]]; then
        # Check if user service exists and is enabled
        sudo -u "$SUDO_USER" XDG_RUNTIME_DIR="/run/user/$(id -u "$SUDO_USER")" \
            systemctl --user is-enabled "$service" &>/dev/null
    else
        systemctl is-enabled "$service" &>/dev/null
    fi
}

# Helper function to enable user service safely
enable_user_service() {
    local service="$1"
    local user_uid=$(id -u "$SUDO_USER")
    
    echo "[INFO] Enabling user service: $service"
    
    # Ensure XDG_RUNTIME_DIR exists and has correct permissions
    if [[ ! -d "/run/user/$user_uid" ]]; then
        mkdir -p "/run/user/$user_uid"
        chown "$SUDO_USER:$SUDO_USER" "/run/user/$user_uid"
        chmod 700 "/run/user/$user_uid"
    fi
    
    # Enable the service
    sudo -u "$SUDO_USER" XDG_RUNTIME_DIR="/run/user/$user_uid" \
        systemctl --user enable "$service"
}

# Helper function to start user service safely
start_user_service() {
    local service="$1"
    local user_uid=$(id -u "$SUDO_USER")
    
    echo "[INFO] Starting user service: $service"
    
    # Only try to start if we can connect to user bus
    if sudo -u "$SUDO_USER" XDG_RUNTIME_DIR="/run/user/$user_uid" \
        systemctl --user status &>/dev/null; then
        sudo -u "$SUDO_USER" XDG_RUNTIME_DIR="/run/user/$user_uid" \
            systemctl --user start "$service" || true
    else
        echo "[WARN] Cannot start $service - no active user session. Service will start on next login."
    fi
}

# Helper function to check if user service is active
is_user_service_active() {
    local service="$1"
    local user_uid=$(id -u "$SUDO_USER")
    
    sudo -u "$SUDO_USER" XDG_RUNTIME_DIR="/run/user/$user_uid" \
        systemctl --user is-active "$service" &>/dev/null
}

# Helper function to check if directory exists and is not empty
dir_exists_and_not_empty() {
    [[ -d "$1" && "$(ls -A "$1" 2>/dev/null)" ]]
}

# ---------------------------
# 1. System update
# ---------------------------
echo "[INFO] Updating system..."
pacman -Syu --noconfirm

# ---------------------------
# 2. Install yay (AUR helper)
# ---------------------------
if ! command -v yay &>/dev/null; then
    echo "[INFO] Installing yay..."
    cd /tmp
    if [[ -d "/tmp/yay" ]]; then
        rm -rf /tmp/yay
    fi
    sudo -u "$SUDO_USER" git clone https://aur.archlinux.org/yay.git
    cd yay
    sudo -u "$SUDO_USER" makepkg -si --noconfirm
    cd /
    rm -rf /tmp/yay
else
    echo "[SKIP] yay is already installed"
fi

# ---------------------------
# 3. Install AUR packages as user
# ---------------------------
echo "[INFO] Checking AUR packages..."
aur_packages=("visual-studio-code-bin" "goxlr-utility-bin" "google-chrome-bin")
packages_to_install=()

for package in "${aur_packages[@]}"; do
    if ! is_aur_package_installed "$package"; then
        packages_to_install+=("$package")
    else
        echo "[SKIP] $package is already installed"
    fi
done

if [[ ${#packages_to_install[@]} -gt 0 ]]; then
    echo "[INFO] Installing AUR packages: ${packages_to_install[*]}"
    sudo -u "$SUDO_USER" yay -S --noconfirm "${packages_to_install[@]}"
else
    echo "[SKIP] All AUR packages are already installed"
fi

# ---------------------------
# 4. Setup Oh My Zsh for user
# ---------------------------
if [[ ! -d "/home/$SUDO_USER/.oh-my-zsh" ]]; then
    echo "[INFO] Installing Oh My Zsh..."
    sudo -u "$SUDO_USER" sh -c "$(curl -fsSL https://raw.github.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended
else
    echo "[SKIP] Oh My Zsh is already installed"
fi

# Powerlevel10k theme
if [[ ! -d "/home/$SUDO_USER/.oh-my-zsh/custom/themes/powerlevel10k" ]]; then
    echo "[INFO] Installing Powerlevel10k theme..."
    sudo -u "$SUDO_USER" git clone --depth=1 https://github.com/romkatv/powerlevel10k.git \
        /home/$SUDO_USER/.oh-my-zsh/custom/themes/powerlevel10k
else
    echo "[SKIP] Powerlevel10k theme is already installed"
fi

# Zsh plugins
declare -A zsh_plugins=(
    ["zsh-autosuggestions"]="https://github.com/zsh-users/zsh-autosuggestions"
    ["zsh-syntax-highlighting"]="https://github.com/zsh-users/zsh-syntax-highlighting.git"
    ["zsh-autocomplete"]="https://github.com/marlonrichert/zsh-autocomplete.git"
)

for plugin in "${!zsh_plugins[@]}"; do
    plugin_dir="/home/$SUDO_USER/.oh-my-zsh/custom/plugins/$plugin"
    if [[ ! -d "$plugin_dir" ]]; then
        echo "[INFO] Installing zsh plugin: $plugin"
        if [[ "$plugin" == "zsh-autocomplete" ]]; then
            sudo -u "$SUDO_USER" git clone --depth=1 "${zsh_plugins[$plugin]}" "$plugin_dir"
        else
            sudo -u "$SUDO_USER" git clone "${zsh_plugins[$plugin]}" "$plugin_dir"
        fi
    else
        echo "[SKIP] Zsh plugin $plugin is already installed"
    fi
done

# Configure .zshrc (always update to ensure latest config)
echo "[INFO] Updating .zshrc configuration..."
cat > /home/$SUDO_USER/.zshrc << 'EOF'
export ZSH="$HOME/.oh-my-zsh"
ZSH_THEME="powerlevel10k/powerlevel10k"
plugins=(git zsh-autosuggestions zsh-syntax-highlighting zsh-autocomplete)
source $ZSH/oh-my-zsh.sh

alias cat="bat"
alias cd="z"
alias cl="clear"
alias ls="lsd"
EOF
chown $SUDO_USER:$SUDO_USER /home/$SUDO_USER/.zshrc

# ---------------------------
# 5. PAM config for hyprlock
# ---------------------------
if [[ ! -f "/etc/pam.d/hyprlock" ]]; then
    echo "[INFO] Configuring PAM for hyprlock..."
    cat << 'PAMCONF' > /etc/pam.d/hyprlock
#%PAM-1.0
auth     include   login
account  include   login
password include   login
session  include   login
PAMCONF
else
    echo "[SKIP] PAM configuration for hyprlock already exists"
fi

# ---------------------------
# 6. Enable autologin on tty1
# ---------------------------
autologin_dir="/etc/systemd/system/getty@tty1.service.d"
autologin_file="$autologin_dir/override.conf"

if [[ ! -f "$autologin_file" ]]; then
    echo "[INFO] Setting up autologin on tty1..."
    mkdir -p "$autologin_dir"
    cat << AUTOLOGIN > "$autologin_file"
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin $SUDO_USER --noclear %I \$TERM
AUTOLOGIN
    # Reload systemd to pick up the new override
    systemctl daemon-reload
else
    echo "[SKIP] Autologin on tty1 is already configured"
fi

# ---------------------------
# 7. Create systemd user service for Hyprland
# ---------------------------
hyprland_service_dir="/home/$SUDO_USER/.config/systemd/user"
hyprland_service_file="$hyprland_service_dir/hyprland.service"

if [[ ! -f "$hyprland_service_file" ]]; then
    echo "[INFO] Creating Hyprland systemd user service..."
    sudo -u "$SUDO_USER" mkdir -p "$hyprland_service_dir"
    cat << 'HYPRSVC' > "$hyprland_service_file"
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
    chown -R $SUDO_USER:$SUDO_USER /home/$SUDO_USER/.config
else
    echo "[SKIP] Hyprland systemd user service already exists"
fi

# ---------------------------
# 8. Disable unused TTYs
# ---------------------------
echo "[INFO] Checking unused TTYs..."
ttys_to_mask=("getty@tty2.service" "getty@tty3.service" "getty@tty4.service" "getty@tty5.service" "getty@tty6.service")
ttys_to_disable=()

for tty in "${ttys_to_mask[@]}"; do
    if systemctl is-enabled "$tty" &>/dev/null; then
        ttys_to_disable+=("$tty")
    fi
done

if [[ ${#ttys_to_disable[@]} -gt 0 ]]; then
    echo "[INFO] Disabling unused TTYs: ${ttys_to_disable[*]}"
    systemctl mask "${ttys_to_disable[@]}"
else
    echo "[SKIP] Unused TTYs are already disabled"
fi

# ---------------------------
# 9. Enable essential services
# ---------------------------
echo "[INFO] Setting up user services..."

# Ensure user runtime directory exists
user_uid=$(id -u "$SUDO_USER")
user_runtime_dir="/run/user/$user_uid"

if [[ ! -d "$user_runtime_dir" ]]; then
    echo "[INFO] Creating user runtime directory..."
    mkdir -p "$user_runtime_dir"
    chown "$SUDO_USER:$SUDO_USER" "$user_runtime_dir"
    chmod 700 "$user_runtime_dir"
fi

# Enable lingering for the user (allows user services to run without login)
if ! loginctl show-user "$SUDO_USER" -p Linger | grep -q "yes"; then
    echo "[INFO] Enabling lingering for user $SUDO_USER..."
    loginctl enable-linger "$SUDO_USER"
else
    echo "[SKIP] Lingering already enabled for user $SUDO_USER"
fi

# Give a moment for lingering to take effect
sleep 2

# Handle user services
user_services=("pipewire.service" "wireplumber.service" "hyprland.service")

for service in "${user_services[@]}"; do
    service_enabled=false
    
    # Check if service is enabled
    if is_service_enabled "$service" "true"; then
        echo "[SKIP] User service $service is already enabled"
        service_enabled=true
    else
        # Try to enable the service
        if enable_user_service "$service"; then
            service_enabled=true
        else
            echo "[WARN] Failed to enable user service $service"
        fi
    fi
    
    # Try to start the service if it's enabled and not running
    if [[ "$service_enabled" == "true" ]]; then
        if ! is_user_service_active "$service"; then
            start_user_service "$service"
        else
            echo "[SKIP] User service $service is already running"
        fi
    fi
done

# ---------------------------
# 10. Copy user configs from GitHub
# ---------------------------
config_dir="/home/$SUDO_USER/.config"
temp_repo_dir="/home/$SUDO_USER/arch-auto-setup"

# Check if we need to update configs
should_update_configs=false

if [[ ! -d "$config_dir" ]] || [[ ! dir_exists_and_not_empty "$config_dir" ]]; then
    should_update_configs=true
    echo "[INFO] Config directory is missing or empty, will download configs"
elif [[ ! -f "$config_dir/.last_config_update" ]]; then
    should_update_configs=true
    echo "[INFO] No config update timestamp found, will update configs"
else
    # Check if it's been more than a day since last update (optional)
    last_update=$(stat -c %Y "$config_dir/.last_config_update" 2>/dev/null || echo 0)
    current_time=$(date +%s)
    time_diff=$((current_time - last_update))
    # Update if more than 24 hours (86400 seconds)
    if [[ $time_diff -gt 86400 ]]; then
        should_update_configs=true
        echo "[INFO] Configs are older than 24 hours, will update"
    fi
fi

if [[ "$should_update_configs" == "true" ]]; then
    echo "[INFO] Downloading/updating Hyprland configs..."
    
    # Clean up any existing temp directory
    if [[ -d "$temp_repo_dir" ]]; then
        rm -rf "$temp_repo_dir"
    fi
    
    sudo -u "$SUDO_USER" git clone --depth=1 https://github.com/cedricreitz/arch-setup.git "$temp_repo_dir"
    
    # Create config directory if it doesn't exist
    sudo -u "$SUDO_USER" mkdir -p "$config_dir"
    
    # Copy configs
    sudo -u "$SUDO_USER" cp -r "$temp_repo_dir/.config/"* "$config_dir/"
    
    # Clean up
    rm -rf "$temp_repo_dir"
    
    # Fix ownership
    chown -R $SUDO_USER:$SUDO_USER "$config_dir"
    
    # Create timestamp file
    sudo -u "$SUDO_USER" touch "$config_dir/.last_config_update"
else
    echo "[SKIP] Hyprland configs are up to date"
fi

echo "[SUCCESS] Post-install setup completed!"
echo "[INFO] User services have been enabled. They will be fully active after the next login or reboot."