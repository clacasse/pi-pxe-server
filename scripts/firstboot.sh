#!/bin/bash
# Runs on first boot of a fresh Pi
# Expects the pxe-homelab repo to be on the boot partition at /boot/firmware/pxe-homelab/
set -e

BOOT_REPO="/boot/firmware/pxe-homelab"
DEST_DIR="/home/pi/pxe-homelab"
LOG="/var/log/pxe-firstboot.log"

exec > >(tee -a "$LOG") 2>&1
echo "=== PXE First Boot $(date) ==="

# Wait for network
echo "Waiting for network..."
until ping -c1 archive.ubuntu.com &>/dev/null; do sleep 2; done

# Install dependencies
echo "Installing ansible..."
apt update -qq
apt install -y -qq ansible git

# Copy repo from boot partition to home
if [ -d "$BOOT_REPO" ]; then
    echo "Copying repo from boot partition..."
    cp -r "$BOOT_REPO" "$DEST_DIR"
    chown -R pi:pi "$DEST_DIR"
else
    echo "ERROR: $BOOT_REPO not found"
    exit 1
fi

# Run the playbook
echo "Running Ansible playbook..."
cd "$DEST_DIR"
ansible-playbook -i localhost, -c local ansible/setup-pxe-server.yml

# Clean up - remove repo from boot partition to free space
rm -rf "$BOOT_REPO"
rm -f /boot/firmware/pxe-firstboot.sh
systemctl disable pxe-firstboot.service

echo "=== PXE First Boot Complete $(date) ==="
