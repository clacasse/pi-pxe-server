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
- **x86_64 targets:** Secure Boot disabled, PXE/Network boot set as first boot option in BIOS
- **ARM64 targets:** must be able to UEFI PXE boot (you provide the firmware). Options include [rpi4-uefi-ipxe](https://github.com/rgl/rpi4-uefi-ipxe) for Pi 4, [pftf/RPi4](https://github.com/pftf/RPi4) UEFI firmware, or EEPROM network boot — whatever gets your device to send a UEFI PXE request on the network

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
    ├── grub-arm64.cfg.tpl         # ARM64 GRUB boot config
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
