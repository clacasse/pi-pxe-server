#!/usr/bin/env python3
"""Prepare a Raspberry Pi SD card as a PXE server.

Works on Linux, macOS, and WSL.
"""

import os
import shutil
import sys
from pathlib import Path

try:
    import typer
    from rich.panel import Panel
    from rich.table import Table
except ImportError:
    print("Missing dependencies. Install with:")
    print("  pip install typer rich")
    sys.exit(1)

from common import (
    REPO_DIR,
    console,
    prompt_password,
    prompt_ssh_key,
    validate_mac,
)
from configure import write_all_yml, write_inventory_yml, DEFAULT_PACKAGES, generate_password_hash

app = typer.Typer(help="Prepare a Raspberry Pi SD card as a PXE server.")


# ==================== SD Card Helpers ====================


def detect_boot_partition() -> Path | None:
    """Auto-detect the Raspberry Pi boot partition."""
    candidates = []

    # macOS
    for name in ["bootfs", "boot"]:
        p = Path(f"/Volumes/{name}")
        if p.exists():
            candidates.append(p)

    # Linux
    user = os.environ.get("USER", "")
    for name in ["bootfs", "boot"]:
        p = Path(f"/media/{user}/{name}")
        if p.exists():
            candidates.append(p)

    # WSL - check common drive letters
    for letter in "defgh":
        p = Path(f"/mnt/{letter}")
        if (p / "config.txt").exists() or (p / "cmdline.txt").exists():
            candidates.append(p)

    for candidate in candidates:
        if (candidate / "config.txt").exists() or (candidate / "cmdline.txt").exists():
            return candidate

    return None


def is_boot_partition(path: Path) -> bool:
    """Check if a path looks like a Raspberry Pi boot partition."""
    return (path / "config.txt").exists() or (path / "cmdline.txt").exists()


def copy_to_sd(boot_mount: Path) -> None:
    """Copy repo files and firstboot service to the SD card."""
    sd_repo = boot_mount / "pxe-homelab"

    # Clean previous copy if exists
    if sd_repo.exists():
        shutil.rmtree(sd_repo)

    # Copy repo contents (excluding .git and large files)
    sd_repo.mkdir()
    for item in ["ansible", "scripts", "templates"]:
        src = REPO_DIR / item
        if src.exists():
            shutil.copytree(src, sd_repo / item)
    for item in ["README.md", ".gitignore", "pyproject.toml"]:
        src = REPO_DIR / item
        if src.exists():
            shutil.copy2(src, sd_repo / item)

    # Copy firstboot script and service to boot root
    firstboot_sh = REPO_DIR / "scripts" / "firstboot.sh"
    firstboot_svc = REPO_DIR / "scripts" / "pxe-firstboot.service"
    shutil.copy2(firstboot_sh, boot_mount / "pxe-firstboot.sh")
    os.chmod(boot_mount / "pxe-firstboot.sh", 0o755)
    shutil.copy2(firstboot_svc, boot_mount / "pxe-firstboot.service")

    # Hook into Pi Imager's firstrun.sh
    firstrun = boot_mount / "firstrun.sh"
    if firstrun.exists():
        content = firstrun.read_text()
        content = content.replace("exit 0\n", "").rstrip()
        content += """

# Enable PXE firstboot service
cp /boot/firmware/pxe-firstboot.service /etc/systemd/system/pxe-firstboot.service 2>/dev/null || \\
cp /boot/pxe-firstboot.service /etc/systemd/system/pxe-firstboot.service 2>/dev/null
systemctl enable pxe-firstboot.service

exit 0
"""
        firstrun.write_text(content)
    else:
        console.print(
            "[yellow]WARNING:[/yellow] No firstrun.sh found (did you configure the Pi in the Imager?).\n"
            "After booting, manually run:\n"
            "  sudo cp /boot/firmware/pxe-firstboot.service /etc/systemd/system/\n"
            "  sudo systemctl enable --now pxe-firstboot.service"
        )


# ==================== Command ====================


@app.command()
def prepare(
    boot_path: str = typer.Argument(None, help="Path to the Pi boot partition. Auto-detects if omitted."),
    pxe_ip: str = typer.Option(None, "--pxe-ip", help="PXE server (Pi) IP address"),
    pi_user: str = typer.Option(None, "--pi-user", help="Pi username (set in Raspberry Pi Imager)"),
    hostname: str = typer.Option(None, "--hostname", help="Target machine hostname"),
    username: str = typer.Option(None, "--username", help="Target machine username"),
    password: str = typer.Option(None, "--password", help="Target machine password"),
    mac: str = typer.Option(None, "--mac", help="Target machine MAC address"),
    ssh_key: str = typer.Option(None, "--ssh-key", help="SSH public key (raw string)"),
    ssh_key_file: str = typer.Option(None, "--ssh-key-file", help="Path to SSH public key file"),
    non_interactive: bool = typer.Option(False, "--yes", "-y", help="Skip confirmations"),
):
    """Prepare a Raspberry Pi SD card as a PXE server."""

    console.print(Panel("PXE Homelab - SD Card Preparation", style="bold blue"))

    # ---- Boot partition ----
    if boot_path:
        boot_mount = Path(boot_path)
    else:
        console.print("Searching for boot partition...")
        detected = detect_boot_partition()
        if detected:
            console.print(f"Found: [cyan]{detected}[/cyan]")
            if non_interactive or typer.confirm("Use this?", default=True):
                boot_mount = detected
            else:
                boot_path = typer.prompt("Enter path to boot partition")
                boot_mount = Path(boot_path)
        else:
            console.print("[yellow]Could not auto-detect boot partition.[/yellow]")
            console.print("  macOS:  usually /Volumes/bootfs")
            console.print("  Linux:  usually /media/$USER/bootfs")
            console.print("  WSL:    usually /mnt/d or /mnt/e")
            boot_path = typer.prompt("Enter path to boot partition")
            boot_mount = Path(boot_path)

    if not is_boot_partition(boot_mount):
        console.print(f"[red]ERROR:[/red] {boot_mount} doesn't look like a Raspberry Pi boot partition")
        console.print("       (no config.txt or cmdline.txt found)")
        raise typer.Exit(1)

    # ---- Gather config inputs ----
    if not pxe_ip:
        pxe_ip = typer.prompt("PXE server (Pi) IP address")

    if not pi_user:
        pi_user = typer.prompt("Pi username")

    console.print("\n[bold]Target Machine Configuration[/bold]")

    if not hostname:
        hostname = typer.prompt("Hostname")

    if not username:
        username = typer.prompt("Username")

    resolved_password = prompt_password(password)

    if not mac:
        mac = typer.prompt("MAC address (aa:bb:cc:dd:ee:ff)")
    mac = validate_mac(mac)

    ssh_key_resolved = prompt_ssh_key(ssh_key, ssh_key_file, non_interactive)

    # ---- Generate password hash ----
    console.print("\nGenerating password hash...")
    password_hash = generate_password_hash(resolved_password)

    # ---- Write config files ----
    console.print("Creating configuration...")
    all_yml_path = write_all_yml(
        pxe_server_ip=pxe_ip,
        pi_user=pi_user,
        target_hostname=hostname,
        target_username=username,
        password_hash=password_hash,
        pxe_clients=[{"mac": mac, "name": hostname}],
        ssh_keys=[ssh_key_resolved],
        packages=DEFAULT_PACKAGES,
        late_commands=[],
    )
    console.print(f"  Config: [dim]{all_yml_path}[/dim]")

    inventory_path = write_inventory_yml(pxe_server_ip=pxe_ip, pi_user=pi_user)
    console.print(f"  Inventory: [dim]{inventory_path}[/dim]")

    # ---- Copy to SD card ----
    console.print("Copying files to SD card...")
    copy_to_sd(boot_mount)

    # ---- Summary ----
    table = Table(title="Configuration Summary", show_header=False)
    table.add_column("Key", style="cyan")
    table.add_column("Value", style="white")
    table.add_row("PXE Server IP", pxe_ip)
    table.add_row("Pi User", pi_user)
    table.add_row("Target Hostname", hostname)
    table.add_row("Target Username", username)
    table.add_row("Target MAC", mac)
    table.add_row("SSH Key", ssh_key_resolved[:50] + "..." if len(ssh_key_resolved) > 50 else ssh_key_resolved)
    table.add_row("Boot Partition", str(boot_mount))
    console.print()
    console.print(table)

    console.print(Panel(
        "[bold green]SD Card Ready![/bold green]\n\n"
        "Next steps:\n"
        "  1. Eject the SD card\n"
        "  2. Insert into Pi and power on (connect ethernet first)\n"
        f"  3. Wait for setup to complete (~30 min, mostly ISO download)\n"
        f"  4. Monitor: [cyan]ssh {pi_user}@{pxe_ip} 'journalctl -u pxe-firstboot -f'[/cyan]\n"
        "  5. PXE boot the target machine",
        title="Done",
    ))


if __name__ == "__main__":
    app()
