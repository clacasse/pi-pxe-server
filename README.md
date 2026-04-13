# PXE Homelab

Automated bare metal provisioning for a GPU workstation running Kubernetes + Ollama.

## What This Does

From a fresh Raspberry Pi and a bare metal PC, this repo sets up:

1. **PXE Server** (Raspberry Pi) - Serves Ubuntu autoinstall over the network
2. **GPU Workstation** - Ubuntu 24.04 LTS with NVIDIA drivers, k3s, and Ollama

## Prerequisites

- Raspberry Pi 4 (or 3B+) with Raspberry Pi OS Lite (64-bit)
- GPU workstation connected via ethernet to the same network
- Existing DHCP server on the network (e.g., UniFi, router)
- Secure Boot disabled on the GPU workstation
- PXE/Network boot enabled in GPU workstation BIOS

## Quick Start

### Step 1: Flash the Pi

Use [Raspberry Pi Imager](https://www.raspberrypi.com/software/):
- OS: **Raspberry Pi OS Lite (64-bit)**
- Enable SSH, set hostname to `pxe-server`, set username `pi` + password
- Skip WiFi (use ethernet)
- Flash the SD card, but **don't eject yet**

### Step 2: Prepare the SD Card

```bash
git clone git@github.com:clacasse/pxe-homelab.git
cd pxe-homelab

# Create your config
cp ansible/group_vars/all.yml.example ansible/group_vars/all.yml
# Edit all.yml with your IP, MAC address, SSH key, etc.

# Copy repo and firstboot service to the SD card boot partition
./scripts/prepare-sd.sh /path/to/boot/partition
```

Eject the SD card and insert into the Pi.

### Step 3: Boot the Pi

Power on the Pi. It will automatically:
1. Boot and configure the user (from Pi Imager settings)
2. Install Ansible and git
3. Run the PXE server playbook
4. Download Ubuntu ISO (~2.6GB)

Monitor progress: `ssh pi@pxe-server 'journalctl -u pxe-firstboot -f'`

### Step 4: PXE Boot the GPU Workstation

1. Ensure the workstation's MAC is listed in `ansible/group_vars/all.yml`
2. Power on the workstation (BIOS set to PXE boot first, Secure Boot off)
3. It will PXE boot, install Ubuntu headlessly, and reboot
4. SSH in: `ssh chris@ollama-server`

### Step 5: Provision the GPU Workstation (TODO)

```bash
ansible-playbook -i ansible/inventory.yml ansible/site.yml
```

## How PXE Boot Control Works

BIOS is set to PXE boot first on all managed machines. The PXE server controls which machines get re-imaged:

- **Normal boot**: dnsmasq ignores the PXE request, machine boots from local disk (~3 sec delay)
- **Re-image**: Add MAC to `pxe_clients` in config, restart dnsmasq, reboot machine

## Network Architecture

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
│  GPU Workstation                              │
│  PXE boot -> Ubuntu autoinstall -> k3s       │
└──────────────────────────────────────────────┘
```
