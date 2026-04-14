#!/bin/bash
# Runs once on Pi first boot via cloud-init runcmd.
# Transforms the pre-rendered configs on the boot partition into
# a fully configured PXE server.
set -e

LOG=/var/log/pxe-setup.log
exec > >(tee -a "$LOG") 2>&1
echo "=== PXE Setup $(date) ==="

# ---- Locate the repo on the boot partition ----
for BOOT_REPO in /boot/firmware/pxe-homelab /boot/pxe-homelab; do
    [ -d "$BOOT_REPO" ] && break
done
echo "Repo: $BOOT_REPO"

# ---- Detect Pi IP and network ----
PI_IP=$(ip -4 addr show scope global | awk '/inet / {print $2}' | cut -d/ -f1 | head -1)
NETWORK=$(echo "$PI_IP" | sed 's|\.[0-9]*$|.0|')
echo "Pi IP: $PI_IP"
echo "Network: $NETWORK"

# ---- Wait for network + install packages ----
echo "Waiting for network..."
until ping -c1 -W2 archive.ubuntu.com &>/dev/null; do sleep 2; done

# Pi has no RTC - wait for NTP sync so apt signatures validate
echo "Waiting for time sync (Pi has no RTC)..."
systemctl start systemd-timesyncd 2>/dev/null || true
for i in $(seq 1 60); do
    if timedatectl show --property=NTPSynchronized --value 2>/dev/null | grep -q yes; then
        echo "Clock synced: $(date)"
        break
    fi
    sleep 2
done

echo "Installing packages..."
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y -o Dpkg::Options::=--force-confold -o Dpkg::Options::=--force-confdef dnsmasq nginx wget

# ---- Directory structure ----
mkdir -p /srv/http/autoinstall
mkdir -p /srv/tftp/grub
mkdir -p /srv/tftp/boot/grub

# ---- Template configs with IP/network ----
echo "Writing configs..."
sed "s|__NETWORK__|${NETWORK}|g" "$BOOT_REPO/templates/dnsmasq.conf.tpl" > /etc/dnsmasq.conf
sed "s|__PI_IP__|${PI_IP}|g" "$BOOT_REPO/templates/grub.cfg.tpl" > /srv/tftp/grub/grub.cfg
cp /srv/tftp/grub/grub.cfg /srv/tftp/boot/grub/grub.cfg

# Nginx site (static)
cp "$BOOT_REPO/templates/nginx-pxe.conf" /etc/nginx/sites-available/pxe
ln -sf /etc/nginx/sites-available/pxe /etc/nginx/sites-enabled/pxe
rm -f /etc/nginx/sites-enabled/default

# Autoinstall files (already resolved by prepare_sd.py)
cp "$BOOT_REPO/autoinstall/user-data" /srv/http/autoinstall/user-data
cp "$BOOT_REPO/autoinstall/meta-data" /srv/http/autoinstall/meta-data
touch /srv/http/autoinstall/vendor-data

# ---- Download Ubuntu ISO ----
UBUNTU_VERSION="${UBUNTU_VERSION:-24.04.2}"
ISO_URL="https://releases.ubuntu.com/${UBUNTU_VERSION}/ubuntu-${UBUNTU_VERSION}-live-server-amd64.iso"
echo "Downloading Ubuntu ISO (${UBUNTU_VERSION})..."
wget -q --show-progress -O /srv/http/ubuntu.iso "$ISO_URL"

# ---- Extract kernel + initrd from ISO ----
echo "Extracting kernel/initrd..."
mkdir -p /mnt/iso
mount -o loop,ro /srv/http/ubuntu.iso /mnt/iso
cp /mnt/iso/casper/vmlinuz /srv/tftp/vmlinuz
cp /mnt/iso/casper/initrd /srv/tftp/initrd
umount /mnt/iso

# ---- Download + extract GRUB netboot binaries ----
GRUB_SIGNED_DEB="http://archive.ubuntu.com/ubuntu/pool/main/g/grub2-signed/grub-efi-amd64-signed_1.202+2.12-1ubuntu7_amd64.deb"
GRUB_BIN_DEB="http://archive.ubuntu.com/ubuntu/pool/main/g/grub2-unsigned/grub-efi-amd64-bin_2.12-1ubuntu7_amd64.deb"

echo "Downloading GRUB packages..."
wget -q -O /tmp/grub-signed.deb "$GRUB_SIGNED_DEB"
wget -q -O /tmp/grub-bin.deb "$GRUB_BIN_DEB"

echo "Extracting GRUB..."
dpkg -x /tmp/grub-signed.deb /tmp/grub-signed
dpkg -x /tmp/grub-bin.deb /tmp/grub-bin

cp /tmp/grub-signed/usr/lib/grub/x86_64-efi-signed/grubnetx64.efi.signed /srv/tftp/grubnetx64.efi
cp -r /tmp/grub-bin/usr/lib/grub/x86_64-efi /srv/tftp/grub/x86_64-efi

rm -rf /tmp/grub-signed /tmp/grub-bin /tmp/grub-signed.deb /tmp/grub-bin.deb

# ---- Enable services ----
echo "Enabling services..."
systemctl enable --now dnsmasq
systemctl enable --now nginx
systemctl reload nginx

# ---- Verify ----
echo "Verifying..."
sleep 2
systemctl is-active dnsmasq && echo "dnsmasq: active"
systemctl is-active nginx && echo "nginx: active"
curl -sf -o /dev/null "http://localhost:8080/autoinstall/user-data" && echo "HTTP: serving"

echo "=== PXE Setup Complete $(date) ==="
echo ""
echo "PXE server ready at $PI_IP"
echo "Any machine that PXE boots will get Ubuntu installed automatically."
echo "Stop serving: sudo systemctl stop dnsmasq"
