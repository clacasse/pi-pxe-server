#!/bin/bash
# Runs once on Pi first boot via cloud-init runcmd.
# Transforms the pre-rendered configs on the boot partition into
# a fully configured multi-arch PXE server.
#
# x86_64: UEFI PXE → GRUB → Ubuntu autoinstall
# ARM64:  Native Pi TFTP boot → Ubuntu kernel → autoinstall
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
mkdir -p /srv/tftp/arm64

# ---- Template configs with IP/network ----
echo "Writing configs..."
sed "s|__NETWORK__|${NETWORK}|g" "$BOOT_REPO/templates/dnsmasq.conf.tpl" > /etc/dnsmasq.d/pxe.conf

# x86_64 GRUB config
sed "s|__PI_IP__|${PI_IP}|g" "$BOOT_REPO/templates/grub-x86_64.cfg.tpl" > /srv/tftp/x86_64/grub/grub.cfg
cp /srv/tftp/x86_64/grub/grub.cfg /srv/tftp/x86_64/boot/grub/grub.cfg

# ARM64 Pi native boot config
sed "s|__PI_IP__|${PI_IP}|g" "$BOOT_REPO/templates/pi-cmdline.txt.tpl" > /srv/tftp/arm64/cmdline.txt
cp "$BOOT_REPO/templates/pi-config.txt.tpl" /srv/tftp/arm64/config.txt

# Nginx site (static)
cp "$BOOT_REPO/templates/nginx-pxe.conf" /etc/nginx/sites-available/pxe
ln -sf /etc/nginx/sites-available/pxe /etc/nginx/sites-enabled/pxe
rm -f /etc/nginx/sites-enabled/default

# Autoinstall files (already resolved by prepare_sd.py)
cp "$BOOT_REPO/autoinstall/user-data" /srv/http/autoinstall/user-data
cp "$BOOT_REPO/autoinstall/meta-data" /srv/http/autoinstall/meta-data
touch /srv/http/autoinstall/vendor-data

# ---- Download Ubuntu images ----
UBUNTU_VERSION="${UBUNTU_VERSION:-25.10}"

# x86_64: live-server ISO (for autoinstall)
echo "Downloading Ubuntu x86_64 ISO (${UBUNTU_VERSION})..."
wget -q --show-progress -O /srv/http/x86_64/ubuntu.iso \
    "https://releases.ubuntu.com/${UBUNTU_VERSION}/ubuntu-${UBUNTU_VERSION}-live-server-amd64.iso"

# ARM64: preinstalled Pi image (for cloud-init — much smaller boot files)
PI_IMG_URL="https://cdimage.ubuntu.com/releases/${UBUNTU_VERSION}/release/ubuntu-${UBUNTU_VERSION}-preinstalled-server-arm64+raspi.img.xz"
echo "Downloading Ubuntu ARM64 preinstalled Pi image (${UBUNTU_VERSION})..."
wget -q --show-progress -O /tmp/ubuntu-pi.img.xz "$PI_IMG_URL"

echo "Decompressing Pi image..."
xz -d /tmp/ubuntu-pi.img.xz

# Serve the raw image via HTTP for Pi clients to write to disk
mv /tmp/ubuntu-pi.img /srv/http/arm64/ubuntu-pi.img

# ---- Extract x86_64 kernel + initrd from ISO ----
echo "Extracting x86_64 kernel/initrd..."
mkdir -p /mnt/iso
mount -o loop,ro /srv/http/x86_64/ubuntu.iso /mnt/iso
cp /mnt/iso/casper/vmlinuz /srv/tftp/x86_64/vmlinuz
cp /mnt/iso/casper/initrd /srv/tftp/x86_64/initrd
umount /mnt/iso

# ---- Extract ARM64 boot files from preinstalled Pi image ----
echo "Extracting ARM64 Pi boot files..."
LOOP_DEV=$(losetup --find --show --partscan /srv/http/arm64/ubuntu-pi.img)
mkdir -p /mnt/piboot
mount "${LOOP_DEV}p1" /mnt/piboot

# Copy firmware from boot partition root (needed for TFTP boot chain)
cp /mnt/piboot/bootcode.bin /srv/tftp/arm64/ 2>/dev/null || true
cp /mnt/piboot/start*.elf /srv/tftp/arm64/ 2>/dev/null || true
cp /mnt/piboot/fixup*.dat /srv/tftp/arm64/ 2>/dev/null || true

# Kernel and device trees from current/ subdirectory
cp /mnt/piboot/current/vmlinuz /srv/tftp/arm64/vmlinuz
cp /mnt/piboot/current/*.dtb /srv/tftp/arm64/ 2>/dev/null || true
cp -r /mnt/piboot/current/overlays /srv/tftp/arm64/ 2>/dev/null || true

umount /mnt/piboot
losetup -d "$LOOP_DEV"

# Build the installer initramfs (replaces the image's initrd with a
# tiny busybox-based installer that downloads + writes the image to disk)
chmod +x "$BOOT_REPO/scripts/build-pi-installer.sh"
"$BOOT_REPO/scripts/build-pi-installer.sh" /tmp/pi-initrd "$PI_IP"
cp /tmp/pi-initrd/../pi-installer.img /srv/tftp/arm64/initrd
rm -rf /tmp/pi-initrd /tmp/pi-installer.img

# Cloud-init user-data (applied after image is written to disk)
cp "$BOOT_REPO/autoinstall/pi-user-data" /srv/http/arm64/user-data
echo "{}" > /srv/http/arm64/meta-data
touch /srv/http/arm64/vendor-data

# ---- Download x86_64 GRUB ----
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

# ---- Link ARM64 files to TFTP root ----
# Pi native boot looks for files by serial number prefix, then falls
# back to the TFTP root. Symlink files and copy overlays (symlinked
# directories don't resolve correctly from within other symlinks).
for f in /srv/tftp/arm64/*; do
    base=$(basename "$f")
    [ "$base" = "overlays" ] && continue
    ln -sf "arm64/$base" "/srv/tftp/$base" 2>/dev/null || true
done
rm -rf /srv/tftp/overlays
cp -r /srv/tftp/arm64/overlays /srv/tftp/overlays

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
curl -sf -o /dev/null "http://localhost:8080/autoinstall/user-data" && echo "HTTP: x86_64 autoinstall ready"
curl -sf -o /dev/null "http://localhost:8080/arm64/user-data" && echo "HTTP: ARM64 cloud-init ready"
[ -f /srv/tftp/x86_64/grubnetx64.efi ] && echo "x86_64 GRUB: ready"
[ -f /srv/tftp/arm64/vmlinuz ] && echo "ARM64 kernel: ready"
[ -f /srv/http/arm64/ubuntu-pi.img ] && echo "ARM64 Pi image: ready ($(du -sh /srv/http/arm64/ubuntu-pi.img | cut -f1))"

echo "=== PXE Setup Complete $(date) ==="
echo ""
echo "Multi-arch PXE server ready at $PI_IP"
echo "  x86_64: UEFI PXE boot → GRUB → Ubuntu autoinstall"
echo "  ARM64:  Pi native TFTP boot → Ubuntu autoinstall"
echo ""
echo "For Pi clients:"
echo "  Pi 3:   needs bootcode.bin on SD card, or OTP network boot enabled"
echo "  Pi 4/5: set EEPROM BOOT_ORDER=0xf21 for network boot"
echo ""
echo "Stop serving: sudo systemctl stop dnsmasq"
