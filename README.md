# PXE Homelab

Automated bare metal provisioning for Ubuntu servers via PXE boot from a Raspberry Pi.

## What This Does

From a fresh Raspberry Pi and a bare metal PC, this repo:

1. Turns a **Raspberry Pi** into a PXE server (dnsmasq + nginx)
2. PXE boots target machines with a fully **unattended Ubuntu 24.04 LTS** install
3. Leaves you with a clean Ubuntu server ready for further provisioning via Ansible

## Prerequisites

- Raspberry Pi (4 recommended, 3B+ works)
- Target machine connected via ethernet to the same network
- Existing DHCP server on the network (router, UniFi, etc.)
- On the target machine:
  - Secure Boot disabled
  - PXE/Network boot set as first boot option in BIOS

## Quick Start

### Step 1: Flash the Pi

Use [Raspberry Pi Imager](https://www.raspberrypi.com/software/):
- OS: **Raspberry Pi OS Lite (64-bit)**
- Click the gear icon to set: hostname `pxe-server`, enable SSH, username `pi` + password
- Skip WiFi (use ethernet)
- Flash the SD card, but **don't eject yet**

### Step 2: Prepare the SD Card

```bash
git clone git@github.com:clacasse/pxe-homelab.git
cd pxe-homelab
pip install typer rich
python scripts/prepare_sd.py
```

The script will:
- Auto-detect the boot partition (or ask you)
- Prompt for target machine config (hostname, username, password, MAC address)
- Generate the password hash
- Copy everything to the SD card

All options can also be passed as flags for non-interactive use:

```bash
python scripts/prepare_sd.py /mnt/d \
    --pxe-ip 192.168.1.219 \
    --hostname server-01 \
    --username admin \
    --mac aa:bb:cc:dd:ee:ff \
    --ssh-key ~/.ssh/id_ed25519.pub \
    -y
```

Works on **Linux**, **macOS**, and **WSL**.

### Step 3: Boot the Pi

1. Eject the SD card, insert into Pi
2. Connect ethernet, power on
3. The Pi will automatically install dependencies and configure PXE services
4. Monitor: `ssh pi@pxe-server 'journalctl -u pxe-firstboot -f'`

### Step 4: PXE Boot the Target Machine

1. Connect target machine via ethernet
2. Power on - it will PXE boot and install Ubuntu automatically
3. Wait ~20-30 min for install to complete
4. SSH in: `ssh <username>@<hostname>`

## How PXE Boot Control Works

BIOS is set to PXE boot first on all managed machines. The PXE server controls which machines get re-imaged:

- **Normal boot**: dnsmasq ignores the PXE request, machine boots from local disk (~3 sec delay)
- **Re-image**: MAC is listed in config, dnsmasq responds, Ubuntu installs automatically

To re-image a machine later, add its MAC to `ansible/group_vars/all.yml` under `pxe_clients` and restart dnsmasq on the Pi.

## Architecture

```
┌──────────────────────────────────────────────┐
│  Raspberry Pi (PXE Server)                   │
│  dnsmasq (proxyDHCP + TFTP)                 │
│  nginx (HTTP on port 8080)                   │
└─────────────────────┬────────────────────────┘
                      │
        Network (existing DHCP from router)
                      │
┌─────────────────────┴────────────────────────┐
│  Target Machine                               │
│  PXE boot -> Ubuntu 24.04 autoinstall        │
└──────────────────────────────────────────────┘
```

## File Structure

```
pxe-homelab/
├── README.md
├── ansible/
│   ├── inventory.yml
│   ├── setup-pxe-server.yml      # Ansible playbook for Pi
│   └── group_vars/
│       ├── all.yml.example        # Template config
│       └── all.yml                # Your config (gitignored)
├── scripts/
│   ├── prepare_sd.py              # Interactive SD card setup (typer CLI)
│   ├── prepare-sd.sh              # Bash alternative
│   ├── firstboot.sh               # Runs on Pi's first boot
│   ├── bootstrap.sh               # Manual alternative to firstboot
│   └── pxe-firstboot.service      # systemd unit for firstboot
```

## Customization

Edit `ansible/group_vars/all.yml` to change:
- `pxe_clients` - MAC addresses of machines to PXE boot
- `target_packages` - packages installed during Ubuntu setup
- `target_late_commands` - custom commands run at end of install

## Troubleshooting

See the [full troubleshooting guide](docs/troubleshooting.md) or check:
- dnsmasq logs: `sudo journalctl -u dnsmasq -f`
- nginx logs: `sudo journalctl -u nginx -f`
- firstboot logs: `sudo journalctl -u pxe-firstboot -f`
