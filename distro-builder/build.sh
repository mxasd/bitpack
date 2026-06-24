#!/bin/bash
set -e # Exit immediately if a command exits with a non-zero status
cd distro-builder

echo "--- Starting BitPack OS Build ---"

# 1. Install necessary tools for the build process itself
echo "Installing build dependencies..."
sudo apt update
sudo apt install -y curl wget git nano live-build systemd-resolved rsync squashfs-tools xorriso fakeroot

# Ensure YAML parsing is available (we'll use a simple method for this script)
# For robust YAML parsing, a dedicated tool like 'yq' might be preferred,
# but for simplicity, we'll grep/cut directly or source environment variables.

# Load config.yaml values (simplified approach)
OS_NAME=$(grep "os_name:" distro-builder/config.yaml | cut -d ':' -f 2 | xargs)
BASE_SYSTEM=$(grep "base_system:" distro-builder/config.yaml | cut -d ':' -f 2 | xargs)
PACKAGES_STR=$(grep -A 20 "packages:" distro-builder/config.yaml | grep -v "packages:" | sed '/^$/d' | sed '/^#/d' | sed 's/^- //g' | xargs)
DESKTOP_ENV=$(grep "desktop_environment:" distro-builder/config.yaml | cut -d ':' -f 2 | xargs)
THEME=$(grep "theme:" distro-builder/config.yaml | cut -d ':' -f 2 | xargs)
ICON_THEME=$(grep "icon_theme:" distro-builder/config.yaml | cut -d ':' -f 2 | xargs)
FONT=$(grep "font:" distro-builder/config.yaml | cut -d ':' -f 2 | xargs)
TERMINAL_FONT=$(grep "terminal_font:" distro-builder/config.yaml | cut -d ':' -f 2 | xargs)
WALLPAPER_URL=$(grep "wallpaper_url:" distro-builder/config.yaml | cut -d ':' -f 2 | xargs)
DEFAULT_MODE=$(grep "default_mode:" distro-builder/config.yaml | cut -d ':' -f 2 | xargs)

# 2. Prepare live-build configuration
echo "Configuring live-build..."
sudo lb config --architecture amd64 \
    --distribution noble \
    --binary-images iso-hybrid \
    --chroot-filesystem squashfs \
    --archive-areas "main universe restricted multiverse"

# 3. Add custom hooks for post-installation customization
echo "Creating custom hooks..."
mkdir -p config/hooks/normal
mkdir -p config/packages-lists

# Add desktop environment and core utilities to package list
echo "${DESKTOP_ENV}" >> config/packages-lists/bitpack.list.chroot
echo "xserver-xorg" >> config/packages-lists/bitpack.list.chroot
echo "xinit" >> config/packages-lists/bitpack.list.chroot
echo "lightdm" >> config/packages-lists/bitpack.list.chroot # For GNOME, gdm3 is common, but lightdm is more universal and customizable
echo "gnome-shell-extensions" >> config/packages-lists/bitpack.list.chroot
echo "chrome-gnome-shell" >> config/packages-lists/bitpack.list.chroot # For managing extensions post-install

# Add packages from config.yaml
for pkg in $PACKAGES_STR; do
    echo "$pkg" >> config/packages-lists/bitpack.list.chroot
done

# Create a custom hook script for applying settings inside the chroot
cat << EOF > config/hooks/normal/01-bitpack-custom.chroot
#!/bin/bash

echo "Applying BitPack custom settings..."

# Set up user 'bitpackuser'
useradd -m -s /bin/bash bitpackuser
echo "bitpackuser:password" | chpasswd # !!! IMPORTANT: CHANGE THIS FOR PRODUCTION !!!
echo "bitpackuser ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/bitpackuser
chmod 0440 /etc/sudoers.d/bitpackuser

# Basic D-Bus setup for gsettings to work as a user
export DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$(id -u bitpackuser)/bus"
export XDG_RUNTIME_DIR="/run/user/$(id -u bitpackuser)"

# --- Apply GNOME settings for 'bitpackuser' ---
su - bitpackuser -c "gsettings set org.gnome.desktop.interface gtk-theme \"${THEME}\""
su - bitpackuser -c "gsettings set org.gnome.desktop.interface icon-theme \"${ICON_THEME}\""
su - bitpackuser -c "gsettings set org.gnome.desktop.interface font-name \"${FONT}\""
su - bitpackuser -c "gsettings set org.gnome.desktop.interface document-font-name \"${FONT}\""
su - bitpackuser -c "gsettings set org.gnome.desktop.interface monospace-font-name \"${TERMINAL_FONT}\""

# Apply default mode (light/dark)
if [ "${DEFAULT_MODE}" = "dark" ]; then
    su - bitpackuser -c "gsettings set org.gnome.desktop.interface color-scheme 'prefer-dark'"
    su - bitpackuser -c "gsettings set org.gnome.desktop.interface gtk-theme \"${THEME}-dark\"" # Assuming a -dark variant exists
else
    su - bitpackuser -c "gsettings set org.gnome.desktop.interface color-scheme 'prefer-light'"
fi


# Set Wallpaper
echo "Setting wallpaper..."
if [[ -n "${WALLPAPER_URL}" && "${WALLPAPER_URL}" != "null" ]]; then
    # Extract file extension from URL
    WALLPAPER_EXT="${WALLPAPER_URL##*.}"
    WALLPAPER_FILENAME="bitpack_wallpaper.${WALLPAPER_EXT}"

    # Create the directory for wallpapers
    sudo -u bitpackuser mkdir -p /home/bitpackuser/.local/share/backgrounds
    # Download the wallpaper as bitpackuser
    sudo -u bitpackuser wget -O "/home/bitpackuser/.local/share/backgrounds/${WALLPAPER_FILENAME}" "${WALLPAPER_URL}"
    # Set the wallpaper
    su - bitpackuser -c "gsettings set org.gnome.desktop.background picture-uri 'file:///home/bitpackuser/.local/share/backgrounds/${WALLPAPER_FILENAME}'"
    su - bitpackuser -c "gsettings set org.gnome.desktop.background picture-options 'zoom'"
    su - bitpackuser -c "gsettings set org.gnome.desktop.background primary-color '#000000'" # Fallback if image fails
fi

# Plank Dock Configuration (Applied for the user)
echo "Configuring Plank dock..."
sudo -u bitpackuser mkdir -p /home/bitpackuser/.config/plank/dock1/
cat << PLANKCONF > /home/bitpackuser/.config/plank/dock1/settings
[dock1]
Position=3
Theme=Gtk+
Alignment=0.5
IconSize=48
AutoHide=true
HideMode=dock-dodge
ShowDockItems=true
# Dock items are usually configured after first launch or via dconf
# Example: CustomDockItems=firefox.desktop,libreoffice-writer.desktop
PLANKCONF
sudo -u bitpackuser chown bitpackuser:bitpackuser /home/bitpackuser/.config/plank/dock1/settings

# Set up autostart for Plank
sudo -u bitpackuser mkdir -p /home/bitpackuser/.config/autostart
cat << EOF_PLANK > /home/bitpackuser/.config/autostart/plank.desktop
[Desktop Entry]
Type=Application
Exec=plank
Hidden=false
NoDisplay=false
X-GNOME-Autostart-enabled=true
Name=Plank
Comment=Lightweight dock
EOF_PLANK
sudo -u bitpackuser chown bitpackuser:bitpackuser /home/bitpackuser/.config/autostart/plank.desktop


# Bash Shell configuration
echo "Applying Bash shell configuration..."
cat << 'BASHRC' >> /home/bitpackuser/.bashrc

# --- BitPack Custom Bash Prompt ---
alias ls='ls --color=auto'
alias ll='ls -alF'
export PS1="\n\[\e[38;5;10m\]BitPack \[\e[38;5;12m\]\w\[\e[0m\]\n\$ "

BASHRC
sudo -u bitpackuser chown bitpackuser:bitpackuser /home/bitpackuser/.bashrc

# Clean up apt caches
apt clean
rm -rf /var/lib/apt/lists/*
EOF
chmod +x config/hooks/normal/01-bitpack-custom.chroot

# 4. Build the ISO
echo "Starting the ISO build process..."
sudo lb build

# 5. Rename the ISO for clarity
echo "Build complete. Renaming ISO..."
mv live-image-amd64.hybrid.iso "${OS_NAME}-amd64-$(date +%Y%m%d%H%M).iso"

echo "--- BitPack OS Build Finished! ---"
