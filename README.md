# Node Bootstrap

From bare metal to Ubuntu: PXE boot for x86, SD card prep for Raspberry Pi.

## What This Does

Two paths to get a fresh machine running Ubuntu Server, ready for further provisioning:

- **x86_64 targets:** A Raspberry Pi PXE server automatically installs Ubuntu via network boot (fully unattended)
- **Pi targets:** Flash Ubuntu with Pi Imager, then run `prepare_pi_target.py` to inject your user, SSH key, and NOPASSWD sudo

Both paths leave you with a clean Ubuntu server ready for [k8s-cluster-bootstrap](https://github.com/clacasse/k8s-cluster-bootstrap)'s `prep-node`.

## Prerequisites

- Raspberry Pi (any model) as the PXE server
- Python 3.10+ on your workstation
- For x86 targets: Secure Boot disabled, PXE/Network boot enabled in BIOS
- For Pi targets: [Raspberry Pi Imager](https://www.raspberrypi.com/software/)

## x86 Targets: PXE Boot

### Step 1: Set up the PXE server

Flash a Raspberry Pi with Pi OS Lite and prepare it as a PXE server:

```bash
git clone git@github.com:clacasse/node-bootstrap.git
cd node-bootstrap
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
python scripts/prepare_pxe_server.py
```

The script prompts for:
- Pi hostname and username (as set in Raspberry Pi Imager)
- Target machine username and password (for all PXE-installed machines)
- SSH public key (auto-detected if available)

### Step 2: Boot the PXE server Pi

1. Eject SD card, insert into Pi, connect ethernet, power on
2. Cloud-init runs `pi-setup.sh` which downloads the Ubuntu ISO, extracts GRUB, and starts dnsmasq + nginx
3. Monitor: `ssh <pi-user>@<pi-hostname> 'sudo tail -f /var/log/pxe-setup.log'`

### Step 3: PXE boot target machines

1. Connect target via ethernet, power on
2. It PXE boots and installs Ubuntu automatically (~20-30 min)
3. SSH in: `ssh <username>@<machine-ip>`

### Controlling the PXE server

- **PXE on:** `sudo systemctl start dnsmasq`
- **PXE off:** `sudo systemctl stop dnsmasq`

## Pi Targets: SD Card Prep

### Step 1: Flash Ubuntu

Use Raspberry Pi Imager:
- OS: **Ubuntu Server 25.10 (64-bit)**
- Storage: your SD card (or USB SSD)
- Don't eject yet

### Step 2: Prepare the SD card

```bash
cd node-bootstrap
source .venv/bin/activate
python scripts/prepare_pi_target.py /Volumes/system-boot
```

The script prompts for username, password, and SSH key, then writes cloud-init configuration to the boot partition.

All options can be passed as flags:
```bash
python scripts/prepare_pi_target.py /Volumes/system-boot \
    --username admin \
    --password "secret" \
    --ssh-key-file ~/.ssh/id_ed25519.pub \
    -y
```

### Step 3: Boot the Pi

1. Eject SD card, insert into Pi, power on
2. Cloud-init configures the user, SSH key, and NOPASSWD sudo on first boot
3. SSH in: `ssh <username>@<pi-ip>`

## File Structure

```
node-bootstrap/
├── README.md
├── pyproject.toml
├── requirements.txt
├── scripts/
│   ├── prepare_pxe_server.py      # Set up the PXE server Pi's SD card
│   ├── prepare_pi_target.py       # Prep a Pi target's SD card with cloud-init
│   ├── pi-setup.sh                # Runs on PXE server Pi first boot
│   └── common.py                  # Shared helpers
└── templates/
    ├── dnsmasq.conf.tpl           # PXE server config
    ├── grub-x86_64.cfg.tpl        # x86_64 GRUB boot config
    ├── nginx-pxe.conf             # HTTP server for ISOs + autoinstall
    ├── autoinstall-user-data.tpl  # x86 target autoinstall config
    ├── cloud-init-user-data.tpl   # Pi target cloud-init config
    └── autoinstall-meta-data      # static
```

## Troubleshooting

PXE server logs:
- First-boot setup: `sudo tail -f /var/log/pxe-setup.log`
- dnsmasq: `sudo journalctl -u dnsmasq -f`
- nginx: `sudo journalctl -u nginx -f`
