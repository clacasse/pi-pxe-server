#!/bin/bash
# Build a minimal ARM64 initramfs that downloads and writes the
# preinstalled Ubuntu Pi image to disk. Used for Pi TFTP network install.
#
# Called by pi-setup.sh. Requires: wget, cpio, gzip
set -e

INITRD_DIR="$1"   # output: directory to build initramfs in
PI_IP="$2"        # PXE server IP for HTTP URLs
BUSYBOX_URL="https://busybox.net/downloads/binaries/1.35.0-arm64-linux-musl/busybox"

if [ -z "$INITRD_DIR" ] || [ -z "$PI_IP" ]; then
    echo "Usage: $0 <initrd-dir> <pi-ip>"
    exit 1
fi

echo "Building Pi installer initramfs..."

rm -rf "$INITRD_DIR"
mkdir -p "$INITRD_DIR"/{bin,sbin,etc,proc,sys,dev,mnt/boot,tmp,usr/bin,usr/sbin}

# Download static busybox
echo "  Downloading busybox (static arm64)..."
wget -q -O "$INITRD_DIR/bin/busybox" "$BUSYBOX_URL"
chmod +x "$INITRD_DIR/bin/busybox"

# Create busybox symlinks
for cmd in sh ash wget dd mount umount reboot sleep ip udhcpc \
           mkdir cat echo ls lsblk blockdev sync poweroff; do
    ln -sf busybox "$INITRD_DIR/bin/$cmd"
done

# udhcpc needs a script to apply the lease
mkdir -p "$INITRD_DIR/usr/share/udhcpc"
cat > "$INITRD_DIR/usr/share/udhcpc/default.script" << 'DHCP'
#!/bin/sh
case "$1" in
    bound|renew)
        ip addr add "$ip/$mask" dev "$interface"
        if [ -n "$router" ]; then
            ip route add default via "$router"
        fi
        if [ -n "$dns" ]; then
            for d in $dns; do
                echo "nameserver $d" >> /etc/resolv.conf
            done
        fi
        ;;
esac
DHCP
chmod +x "$INITRD_DIR/usr/share/udhcpc/default.script"

# Create the init script (the installer)
cat > "$INITRD_DIR/init" << INIT
#!/bin/sh
# Pi Network Installer
# Downloads the preinstalled Ubuntu image and writes it to disk.

echo ""
echo "=================================="
echo "  Pi Network Installer"
echo "=================================="
echo ""

# Mount essential filesystems
mount -t proc none /proc
mount -t sysfs none /sys
mount -t devtmpfs none /dev

# Wait for network interface to appear
echo "Waiting for network..."
for i in \$(seq 1 30); do
    if ip link show eth0 >/dev/null 2>&1; then
        break
    fi
    sleep 1
done

ip link set eth0 up
sleep 2

# DHCP
echo "Requesting DHCP lease..."
udhcpc -i eth0 -s /usr/share/udhcpc/default.script -q 2>/dev/null

echo "IP: \$(ip -4 addr show eth0 | grep inet | awk '{print \$2}')"

# Find target disk (largest block device that isn't a loop or ram device)
sleep 3  # wait for USB/NVMe devices to appear
TARGET=""
for disk in /dev/nvme0n1 /dev/sda /dev/mmcblk0; do
    if [ -b "\$disk" ]; then
        TARGET="\$disk"
        break
    fi
done

if [ -z "\$TARGET" ]; then
    echo "ERROR: No target disk found!"
    echo "Available block devices:"
    ls /dev/sd* /dev/nvme* /dev/mmcblk* 2>/dev/null || echo "  (none)"
    echo "Dropping to shell..."
    exec /bin/sh
fi

SIZE=\$(blockdev --getsize64 "\$TARGET" 2>/dev/null || echo "unknown")
echo "Target disk: \$TARGET (\$SIZE bytes)"
echo ""

# Download and write image
IMG_URL="http://${PI_IP}:8080/arm64/ubuntu-pi.img"
echo "Downloading and writing image from \$IMG_URL"
echo "This will take several minutes..."
echo ""

wget -O - "\$IMG_URL" | dd of="\$TARGET" bs=4M 2>&1
sync

echo ""
echo "Image written successfully."

# Mount the boot partition and inject cloud-init user-data
echo "Configuring cloud-init..."
sleep 2

# Detect boot partition (first partition)
if [ -b "\${TARGET}p1" ]; then
    BOOT_PART="\${TARGET}p1"
elif [ -b "\${TARGET}1" ]; then
    BOOT_PART="\${TARGET}1"
else
    echo "WARNING: Could not find boot partition. Cloud-init not configured."
    BOOT_PART=""
fi

if [ -n "\$BOOT_PART" ]; then
    mount "\$BOOT_PART" /mnt/boot
    wget -q -O /mnt/boot/user-data "http://${PI_IP}:8080/arm64/user-data"
    wget -q -O /mnt/boot/network-config "http://${PI_IP}:8080/arm64/network-config" 2>/dev/null || true
    sync
    umount /mnt/boot
    echo "Cloud-init configured."
fi

echo ""
echo "=================================="
echo "  Installation complete!"
echo "  Rebooting in 5 seconds..."
echo "=================================="
sleep 5
reboot -f
INIT
chmod +x "$INITRD_DIR/init"

# Pack the initramfs
echo "  Packing initramfs..."
(cd "$INITRD_DIR" && find . | cpio -o -H newc 2>/dev/null | gzip -9) > "$INITRD_DIR/../pi-installer.img"

echo "  Built: $(ls -lh "$INITRD_DIR/../pi-installer.img" | awk '{print $5}')"
