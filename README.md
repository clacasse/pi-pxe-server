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
- Enable SSH, set hostname to `pxe-server`, set username/password
- Connect via ethernet, boot up

### Step 2: Bootstrap the PXE Server

From any machine with Ansible installed and SSH access to the Pi:

```bash
git clone https://github.com/YOURUSERNAME/pxe-homelab.git
cd pxe-homelab

# Edit config for your environment
cp ansible/group_vars/all.yml.example ansible/group_vars/all.yml
# Edit all.yml with your IP, MAC address, SSH key, etc.

# Run the playbook
ansible-playbook -i ansible/inventory.yml ansible/setup-pxe-server.yml
```

This will:
- Install dnsmasq and Docker on the Pi
- Download Ubuntu 24.04 ISO (~2.6GB)
- Extract bootloader files
- Configure GRUB, autoinstall, and TFTP
- Start nginx for HTTP serving

### Step 3: PXE Boot the GPU Workstation

1. Ensure the workstation's MAC is listed in `ansible/group_vars/all.yml`
2. Power on the workstation
3. It will PXE boot, install Ubuntu headlessly, and reboot
4. SSH in: `ssh chris@ollama-server`

### Step 4: Provision the GPU Workstation (TODO)

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
