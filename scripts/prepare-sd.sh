#!/bin/bash
# Run this on your PC after flashing the SD card with Pi Imager
# Copies the repo and firstboot service to the boot partition
#
# Usage: ./prepare-sd.sh /path/to/boot/partition
#   Windows example: ./prepare-sd.sh /mnt/d
#   Linux example:   ./prepare-sd.sh /media/user/bootfs
set -e

BOOT_MOUNT="${1:?Usage: $0 /path/to/boot/partition}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"

if [ ! -f "$BOOT_MOUNT/config.txt" ] && [ ! -f "$BOOT_MOUNT/cmdline.txt" ]; then
    echo "ERROR: $BOOT_MOUNT doesn't look like a Raspberry Pi boot partition"
    echo "       (no config.txt or cmdline.txt found)"
    exit 1
fi

echo "=== Preparing SD Card ==="
echo "Boot partition: $BOOT_MOUNT"
echo "Repo source: $REPO_DIR"

# Copy repo to boot partition (excluding .git and large files)
echo "Copying repo..."
mkdir -p "$BOOT_MOUNT/pxe-homelab"
cp -r "$REPO_DIR/ansible" "$BOOT_MOUNT/pxe-homelab/"
cp -r "$REPO_DIR/scripts" "$BOOT_MOUNT/pxe-homelab/"
cp "$REPO_DIR/README.md" "$BOOT_MOUNT/pxe-homelab/"
cp "$REPO_DIR/.gitignore" "$BOOT_MOUNT/pxe-homelab/"

# Check for all.yml config
if [ ! -f "$REPO_DIR/ansible/group_vars/all.yml" ]; then
    echo ""
    echo "WARNING: ansible/group_vars/all.yml not found."
    echo "Copying example config - you MUST edit it before the playbook runs."
    cp "$REPO_DIR/ansible/group_vars/all.yml.example" \
       "$BOOT_MOUNT/pxe-homelab/ansible/group_vars/all.yml"
else
    cp "$REPO_DIR/ansible/group_vars/all.yml" \
       "$BOOT_MOUNT/pxe-homelab/ansible/group_vars/all.yml"
fi

# Copy firstboot script and service
echo "Installing firstboot service..."
cp "$REPO_DIR/scripts/firstboot.sh" "$BOOT_MOUNT/pxe-firstboot.sh"
chmod +x "$BOOT_MOUNT/pxe-firstboot.sh"

# Create a script that enables the service on first boot
# This runs as part of Pi's init before our service
cat > "$BOOT_MOUNT/custom.toml" << 'EOF'
# This file is not standard - we use firstrun.sh instead
EOF

# Append to firstrun.sh if it exists, otherwise create cmdline hook
if [ -f "$BOOT_MOUNT/firstrun.sh" ]; then
    # Pi Imager creates this - append our service setup
    sed -i '/^exit 0/d' "$BOOT_MOUNT/firstrun.sh"
    cat >> "$BOOT_MOUNT/firstrun.sh" << 'FIRSTRUN'

# Enable PXE firstboot service
cp /boot/firmware/pxe-firstboot.service /etc/systemd/system/pxe-firstboot.service 2>/dev/null || \
cp /boot/pxe-firstboot.service /etc/systemd/system/pxe-firstboot.service 2>/dev/null
systemctl enable pxe-firstboot.service

exit 0
FIRSTRUN
else
    echo "WARNING: No firstrun.sh found. You'll need to manually enable the service after boot:"
    echo "  sudo cp /boot/firmware/pxe-firstboot.sh /usr/local/bin/"
    echo "  sudo cp /boot/firmware/pxe-firstboot.service /etc/systemd/system/"
    echo "  sudo systemctl enable --now pxe-firstboot.service"
fi

# Copy the systemd service file to boot partition
cp "$REPO_DIR/scripts/pxe-firstboot.service" "$BOOT_MOUNT/pxe-firstboot.service"

echo ""
echo "=== SD Card Ready ==="
echo "1. Eject the SD card"
echo "2. Insert into Pi and power on"
echo "3. The Pi will automatically:"
echo "   - Boot and configure the user (Pi Imager settings)"
echo "   - Install Ansible and git"
echo "   - Run the PXE server playbook"
echo "   - Download Ubuntu ISO (~2.6GB, takes a while)"
echo ""
echo "Monitor progress: ssh pi@pxe-server 'journalctl -u pxe-firstboot -f'"
