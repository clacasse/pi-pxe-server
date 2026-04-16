#!/bin/bash
# Runs once on Pi first boot via cloud-init runcmd.
# Transforms the pre-rendered configs on the boot partition into
# a fully configured multi-arch PXE server (x86_64 + ARM64).
set -e

LOG=/var/log/pxe-setup.log
exec > >(tee -a "$LOG") 2>&1
echo "=== PXE Setup $(date) ==="

# ---- Locate the repo on the boot partition ----
for BOOT_REPO in /boot/firmware/pi-pxe-server /boot/pi-pxe-server; do
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
mkdir -p /srv/http/x86_64
mkdir -p /srv/http/arm64
mkdir -p /srv/tftp/x86_64/grub
mkdir -p /srv/tftp/x86_64/boot/grub
mkdir -p /srv/tftp/arm64/grub
mkdir -p /srv/tftp/arm64/boot/grub

# ---- Template configs with IP/network ----
echo "Writing configs..."
# Raspberry Pi OS systemd unit only reads /etc/dnsmasq.d/, not /etc/dnsmasq.conf
sed "s|__NETWORK__|${NETWORK}|g" "$BOOT_REPO/templates/dnsmasq.conf.tpl" > /etc/dnsmasq.d/pxe.conf

# Per-architecture GRUB configs
sed "s|__PI_IP__|${PI_IP}|g" "$BOOT_REPO/templates/grub-x86_64.cfg.tpl" > /srv/tftp/x86_64/grub/grub.cfg
cp /srv/tftp/x86_64/grub/grub.cfg /srv/tftp/x86_64/boot/grub/grub.cfg
sed "s|__PI_IP__|${PI_IP}|g" "$BOOT_REPO/templates/grub-arm64.cfg.tpl" > /srv/tftp/arm64/grub/grub.cfg
cp /srv/tftp/arm64/grub/grub.cfg /srv/tftp/arm64/boot/grub/grub.cfg

# Nginx site (static)
cp "$BOOT_REPO/templates/nginx-pxe.conf" /etc/nginx/sites-available/pxe
ln -sf /etc/nginx/sites-available/pxe /etc/nginx/sites-enabled/pxe
rm -f /etc/nginx/sites-enabled/default

# Autoinstall files (already resolved by prepare_sd.py)
cp "$BOOT_REPO/autoinstall/user-data" /srv/http/autoinstall/user-data
cp "$BOOT_REPO/autoinstall/meta-data" /srv/http/autoinstall/meta-data
touch /srv/http/autoinstall/vendor-data

# ---- Download Ubuntu ISOs ----
UBUNTU_VERSION="${UBUNTU_VERSION:-25.10}"

echo "Downloading Ubuntu x86_64 ISO (${UBUNTU_VERSION})..."
wget -q --show-progress -O /srv/http/x86_64/ubuntu.iso \
    "https://releases.ubuntu.com/${UBUNTU_VERSION}/ubuntu-${UBUNTU_VERSION}-live-server-amd64.iso"

echo "Downloading Ubuntu ARM64 ISO (${UBUNTU_VERSION})..."
wget -q --show-progress -O /srv/http/arm64/ubuntu.iso \
    "https://cdimage.ubuntu.com/releases/${UBUNTU_VERSION}/release/ubuntu-${UBUNTU_VERSION}-live-server-arm64.iso"

# ---- Extract kernel + initrd from ISOs ----
echo "Extracting x86_64 kernel/initrd..."
mkdir -p /mnt/iso
mount -o loop,ro /srv/http/x86_64/ubuntu.iso /mnt/iso
cp /mnt/iso/casper/vmlinuz /srv/tftp/x86_64/vmlinuz
cp /mnt/iso/casper/initrd /srv/tftp/x86_64/initrd
umount /mnt/iso

echo "Extracting ARM64 kernel/initrd..."
mount -o loop,ro /srv/http/arm64/ubuntu.iso /mnt/iso
cp /mnt/iso/casper/vmlinuz /srv/tftp/arm64/vmlinuz
cp /mnt/iso/casper/initrd /srv/tftp/arm64/initrd
umount /mnt/iso

# ---- Download + extract GRUB netboot binaries ----
# x86_64 GRUB
GRUB_X86_SIGNED_DEB="http://archive.ubuntu.com/ubuntu/pool/main/g/grub2-signed/grub-efi-amd64-signed_1.202+2.12-1ubuntu7_amd64.deb"
GRUB_X86_BIN_DEB="http://archive.ubuntu.com/ubuntu/pool/main/g/grub2-unsigned/grub-efi-amd64-bin_2.12-1ubuntu7_amd64.deb"

echo "Downloading x86_64 GRUB packages..."
wget -q -O /tmp/grub-x86-signed.deb "$GRUB_X86_SIGNED_DEB"
wget -q -O /tmp/grub-x86-bin.deb "$GRUB_X86_BIN_DEB"

echo "Extracting x86_64 GRUB..."
dpkg -x /tmp/grub-x86-signed.deb /tmp/grub-x86-signed
dpkg -x /tmp/grub-x86-bin.deb /tmp/grub-x86-bin
cp /tmp/grub-x86-signed/usr/lib/grub/x86_64-efi-signed/grubnetx64.efi.signed /srv/tftp/x86_64/grubnetx64.efi
cp -r /tmp/grub-x86-bin/usr/lib/grub/x86_64-efi /srv/tftp/x86_64/grub/x86_64-efi
rm -rf /tmp/grub-x86-signed /tmp/grub-x86-bin /tmp/grub-x86-signed.deb /tmp/grub-x86-bin.deb

# ARM64 GRUB
GRUB_ARM64_SIGNED_DEB="http://ports.ubuntu.com/ubuntu-ports/pool/main/g/grub2-signed/grub-efi-arm64-signed_1.202+2.12-1ubuntu7_arm64.deb"
GRUB_ARM64_BIN_DEB="http://ports.ubuntu.com/ubuntu-ports/pool/main/g/grub2-unsigned/grub-efi-arm64-bin_2.12-1ubuntu7_arm64.deb"

echo "Downloading ARM64 GRUB packages..."
wget -q -O /tmp/grub-arm64-signed.deb "$GRUB_ARM64_SIGNED_DEB"
wget -q -O /tmp/grub-arm64-bin.deb "$GRUB_ARM64_BIN_DEB"

echo "Extracting ARM64 GRUB..."
dpkg -x /tmp/grub-arm64-signed.deb /tmp/grub-arm64-signed
dpkg -x /tmp/grub-arm64-bin.deb /tmp/grub-arm64-bin
cp /tmp/grub-arm64-signed/usr/lib/grub/arm64-efi-signed/grubnetaa64.efi.signed /srv/tftp/arm64/grubnetaa64.efi
cp -r /tmp/grub-arm64-bin/usr/lib/grub/arm64-efi /srv/tftp/arm64/grub/arm64-efi
rm -rf /tmp/grub-arm64-signed /tmp/grub-arm64-bin /tmp/grub-arm64-signed.deb /tmp/grub-arm64-bin.deb

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
[ -f /srv/tftp/x86_64/grubnetx64.efi ] && echo "x86_64 GRUB: ready"
[ -f /srv/tftp/arm64/grubnetaa64.efi ] && echo "ARM64 GRUB: ready"

echo "=== PXE Setup Complete $(date) ==="
echo ""
echo "Multi-arch PXE server ready at $PI_IP"
echo "  x86_64: any UEFI PC that network boots → Ubuntu"
echo "  ARM64:  any UEFI ARM64 device (Pi 4/5 with UEFI firmware) → Ubuntu"
echo "Stop serving: sudo systemctl stop dnsmasq"
