#!/bin/bash
# Runs on first boot of a fresh Pi
# Expects the pxe-homelab repo to be on the boot partition
set -e

# Detect boot partition path (differs by Pi model/OS version)
for BOOT_DIR in /boot/firmware /boot; do
    if [ -d "$BOOT_DIR/pxe-homelab" ]; then
        break
    fi
done

BOOT_REPO="$BOOT_DIR/pxe-homelab"
CURRENT_USER=$(ls /home/ | head -1)
DEST_DIR="/home/$CURRENT_USER/pxe-homelab"
LOG="/var/log/pxe-firstboot.log"

exec > >(tee -a "$LOG") 2>&1
echo "=== PXE First Boot $(date) ==="
echo "Boot repo: $BOOT_REPO"
echo "Dest dir: $DEST_DIR"
echo "User: $CURRENT_USER"

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
    chown -R "$CURRENT_USER:$CURRENT_USER" "$DEST_DIR"
else
    echo "ERROR: $BOOT_REPO not found"
    exit 1
fi

# Run the playbook
echo "Running Ansible playbook..."
cd "$DEST_DIR"
ansible-playbook -i localhost, -c local ansible/setup-pxe-server.yml

# Clean up boot partition
rm -rf "$BOOT_REPO"
rm -f "$BOOT_DIR/pxe-firstboot.sh"
systemctl disable pxe-firstboot.service

echo "=== PXE First Boot Complete $(date) ==="
