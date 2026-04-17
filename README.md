# Pi PXE Server

Multi-architecture PXE server on a Raspberry Pi. Boots x86_64 PCs and ARM64 devices (including other Pis) into unattended Ubuntu installs.

## What This Does

From a fresh Raspberry Pi, this repo:

1. Turns a **Raspberry Pi** into a multi-arch PXE server (dnsmasq + nginx)
2. PXE boots **x86_64** and **ARM64** machines with fully **unattended Ubuntu 25.10** installs
3. Leaves you with clean Ubuntu servers ready for further provisioning

No Ansible, no Docker — just cloud-init and a shell script. The Pi is single-purpose and meant to be "flash once, forget about it." To reconfigure, reflash.

## Prerequisites

- Raspberry Pi (4 recommended, 3B+ works) as the PXE server
- Target machine(s) connected via ethernet to the same network
- Existing DHCP server on the network (router, UniFi, etc.)
- Python 3.10+ on your workstation (for `prepare_sd.py`)
- Target machines connected via ethernet to the same network

### Preparing x86_64 targets

Disable Secure Boot and set PXE/Network boot as the first boot option in BIOS. Most modern motherboards support this — check under Boot Priority or Boot Order in your BIOS settings.

### Preparing Raspberry Pi targets

The PXE server auto-detects x86 vs. Pi clients and serves the right files. Pi clients use native TFTP boot (no UEFI firmware needed), but need network boot enabled in their EEPROM or boot firmware.

Pi 4 and Pi 5 store boot configuration in EEPROM. The `BOOT_ORDER` setting controls which boot modes are tried and in what order. Each hex digit is a boot mode, read right-to-left:

| Code | Boot mode |
|---|---|
| `1` | SD card |
| `2` | Network (TFTP) |
| `4` | USB mass storage |
| `6` | NVMe |
| `7` | HTTP boot |
| `f` | Restart (loop) |

See the [official bootloader configuration docs](https://www.raspberrypi.com/documentation/computers/raspberry-pi.html#raspberry-pi-bootloader-configuration) for the full reference.

**Raspberry Pi 3 / 3B+:**
The Pi 3 doesn't have configurable EEPROM. Put `bootcode.bin` on a FAT32-formatted SD card — the Pi 3 loads this from SD, then switches to TFTP for everything else. Download it from [raspberrypi/firmware](https://github.com/raspberrypi/firmware/blob/master/boot/bootcode.bin).

**Raspberry Pi 4:**
```bash
# On a running Pi 4 (with Pi OS or Ubuntu on SD):
sudo rpi-eeprom-config --edit

# Add network boot (2) to the boot order. This tries network first,
# then USB, then SD. When nothing is installed, it PXE boots.
# After install, it boots from the installed disk.
BOOT_ORDER=0xf1642
```
Reboot, then remove the SD card. The Pi will try network boot, receive Ubuntu from the PXE server, and install to whatever disk is attached.

**Raspberry Pi 5:**
Same as Pi 4. The default `BOOT_ORDER` is `0xf461` (NVMe → USB → SD) which does **not** include network boot. Add it:
```bash
sudo rpi-eeprom-config --edit

# Network (2) first, then NVMe (6), USB (4), SD (1)
BOOT_ORDER=0xf1642
```
Reboot, remove the SD card, and the Pi 5 will PXE boot. After Ubuntu is installed to NVMe/USB, it boots from there directly — network boot times out in a few seconds and falls through.

**Recovery:** If you misconfigure the EEPROM, flash the "Bootloader" recovery image from Raspberry Pi Imager (Misc utility images → Bootloader → your Pi model) to an SD card. Boot with it inserted, wait for the green LED to flash steadily, power off, remove SD. EEPROM is restored to defaults.

## Quick Start

### Step 1: Flash the Pi

Use [Raspberry Pi Imager](https://www.raspberrypi.com/software/):
- OS: **Raspberry Pi OS Lite (64-bit)**
- Click the gear icon to configure: hostname, enable SSH, username + password
- Skip WiFi (use ethernet)
- Flash the SD card, but **don't eject yet**

### Step 2: Prepare the SD Card

```bash
git clone git@github.com:clacasse/pi-pxe-server.git
cd pi-pxe-server
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
python scripts/prepare_sd.py
```

The script will prompt you for:
- Pi hostname and username (as set in Raspberry Pi Imager)
- Target machine username and password (applies to all PXE-installed machines)
- SSH public key (auto-detected if available)

All options can also be passed as flags:

```bash
python scripts/prepare_sd.py /path/to/boot/partition \
    --pi-hostname pxe-server \
    --pi-user pi \
    --username admin \
    --password "secret" \
    --ssh-key-file ~/.ssh/id_ed25519.pub \
    -y
```

Works on **Linux**, **macOS**, and **WSL**.

### Step 3: Boot the Pi

1. Eject the SD card, insert into Pi
2. Connect ethernet, power on
3. Cloud-init will automatically:
   - Install dnsmasq, nginx, wget
   - Run `pi-setup.sh` which downloads Ubuntu ISO, extracts GRUB, writes configs, and starts services

Monitor progress: `ssh <pi-user>@<pi-hostname> 'sudo tail -f /var/log/pxe-setup.log'`

### Step 4: PXE Boot Target Machines

1. Connect target machine via ethernet
2. Power on — it will PXE boot and install Ubuntu automatically
3. Wait ~20-30 min for install to complete
4. SSH in: `ssh <username>@<machine-ip>`

## How It Works

```
┌──────────────────────────────────────────────┐
│  Raspberry Pi (PXE Server)                   │
│  dnsmasq (proxyDHCP + TFTP, multi-arch)     │
│  nginx (HTTP on port 8080)                   │
└─────────────────────┬────────────────────────┘
                      │
        Network (existing DHCP from router)
                      │
        ┌─────────────┴─────────────���
        │                           │
┌───────┴──────────┐  ┌────────────┴───────────┐
│  x86_64 PC       │  │  ARM64 device (Pi 4/5) │
│  UEFI PXE boot   │  │  UEFI PXE boot         │
│  → Ubuntu 25.10  │  │  → Ubuntu 25.10        │
└──────────────────┘  └────────────────────────┘
```

The PXE server serves any machine that network boots. Control it by starting/stopping dnsmasq:

- **PXE on**: `sudo systemctl start dnsmasq` — any machine that PXE boots gets Ubuntu installed
- **PXE off**: `sudo systemctl stop dnsmasq` — machines boot from local disk normally

## Reconfigure

The Pi is designed as a throwaway / single-purpose device. To change settings:

1. Update config on your workstation
2. Re-run `python scripts/prepare_sd.py`
3. Reflash the SD card
4. Reboot the Pi

## File Structure

```
pi-pxe-server/
├── README.md
├── pyproject.toml
├── requirements.txt
├── scripts/
│   ├── prepare_sd.py              # SD card setup (typer CLI)
│   ├── pi-setup.sh                # Runs once on Pi first boot (multi-arch)
│   └── common.py                  # Shared helpers
└── templates/
    ├── dnsmasq.conf.tpl           # Multi-arch proxyDHCP + TFTP
    ├── grub-x86_64.cfg.tpl        # x86_64 GRUB boot config
    ├── pi-config.txt.tpl          # Pi native boot config.txt
    ├── pi-cmdline.txt.tpl         # Pi kernel cmdline (autoinstall)
    ├── nginx-pxe.conf             # static
    ├── autoinstall-user-data.tpl  # target install config
    └── autoinstall-meta-data      # static
```

## Troubleshooting

Check the logs:
- First-boot setup: `sudo tail -f /var/log/pxe-setup.log`
- Cloud-init: `sudo journalctl -u cloud-final -f`
- dnsmasq: `sudo journalctl -u dnsmasq -f`
- nginx: `sudo journalctl -u nginx -f`
