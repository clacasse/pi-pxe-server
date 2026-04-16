#!/usr/bin/env python3
"""Prepare a Raspberry Pi SD card as a PXE server.

Resolves config templates with user inputs and copies the final configs
to the SD card. Cloud-init runs pi-setup.sh on first boot to finish
provisioning.

Works on Linux, macOS, and WSL.
"""

import os
import re
import shutil
import sys
from pathlib import Path
from string import Template

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
    TEMPLATES_DIR,
    console,
    generate_password_hash,
    prompt_password,
    prompt_ssh_key,
)

app = typer.Typer(help="Prepare a Raspberry Pi SD card as a PXE server.")

DEFAULT_PACKAGES = ["curl", "git", "ansible", "jq"]


# ==================== SD Card Helpers ====================


def detect_boot_partition() -> Path | None:
    """Auto-detect the Raspberry Pi boot partition."""
    candidates = []

    for name in ["bootfs", "boot"]:
        p = Path(f"/Volumes/{name}")
        if p.exists():
            candidates.append(p)

    user = os.environ.get("USER", "")
    for name in ["bootfs", "boot"]:
        p = Path(f"/media/{user}/{name}")
        if p.exists():
            candidates.append(p)

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


def _copy_tree_fat32(src: Path, dst: Path) -> None:
    """Recursively copy a directory to FAT32 without touching metadata."""
    dst.mkdir(exist_ok=True)
    for item in src.iterdir():
        src_item = src / item.name
        dst_item = dst / item.name
        if src_item.is_dir():
            _copy_tree_fat32(src_item, dst_item)
        else:
            shutil.copyfile(src_item, dst_item)


# ==================== Template Rendering ====================


def _yaml_list(items: list[str], indent: int = 4) -> str:
    """Format a list of strings as YAML list items."""
    if not items:
        return " " * indent + "[]"
    prefix = " " * indent
    return "\n".join(f"{prefix}- {item}" for item in items)


def render_autoinstall(
    target_username: str,
    password_hash: str,
    ssh_keys: list[str],
    packages: list[str],
    late_commands: list[str],
) -> str:
    """Render the autoinstall user-data template with user inputs."""
    template_path = TEMPLATES_DIR / "autoinstall-user-data.tpl"
    template = Template(template_path.read_text())

    if late_commands:
        # Leading blank-line to separate from the previous section
        late_block = "  late-commands:\n" + _yaml_list(late_commands, indent=4) + "\n"
    else:
        late_block = ""

    rendered = template.substitute(
        target_username=target_username,
        target_password_hash=password_hash,
        target_ssh_keys=_yaml_list(ssh_keys, indent=6),
        target_packages=_yaml_list(packages, indent=4),
        target_late_commands_block=late_block,
    )
    # Collapse any accidental blank lines
    rendered = re.sub(r"\n\n+", "\n", rendered)
    return rendered


# ==================== Cloud-Init Injection ====================


def _detect_pi_user(user_data_content: str) -> str:
    """Extract the first username from cloud-init user-data's users: section."""
    match = re.search(r"^users:\s*$", user_data_content, re.MULTILINE)
    if match:
        after = user_data_content[match.end():]
        name_match = re.search(r"-\s*name:\s*(\S+)", after)
        if name_match:
            return name_match.group(1)
    return "pi"


def _inject_cloud_init(user_data: Path) -> None:
    """Inject packages and runcmd into cloud-init user-data."""
    content = user_data.read_text()
    if "pi-pxe-server" in content and "pi-setup.sh" in content:
        console.print("[dim]PXE setup already present in user-data.[/dim]")
        return

    pi_user = _detect_pi_user(content)

    # Add runcmd entries. pi-setup.sh handles apt install itself so we don't rely
    # on cloud-init's package stage (which has been flaky). Match existing list
    # indentation if present.
    indent = "  "  # default if no runcmd exists
    runcmd_match = re.search(r"^runcmd:\s*\n((?:[ \t]*-[^\n]*\n?)+)", content, re.MULTILINE)
    if runcmd_match:
        first_item = runcmd_match.group(1).splitlines()[0]
        indent = re.match(r"(\s*)-", first_item).group(1)

    # Find pi-setup.sh in whichever boot dir the Pi OS uses, then exec it.
    # Using 'for' picks the correct path by existence check rather than by
    # fall-through on failure (which would mask real errors).
    find_script = (
        'for p in /boot/firmware/pi-pxe-server/scripts/pi-setup.sh '
        '/boot/pi-pxe-server/scripts/pi-setup.sh; '
        'do [ -f $p ] && { chmod +x $p; exec $p; }; done'
    )
    runcmd_lines = [
        f'{indent}- [ sh, -c, "{find_script}" ]',
    ]

    if runcmd_match:
        content = content.rstrip() + "\n" + "\n".join(runcmd_lines) + "\n"
    else:
        content = content.rstrip() + "\nruncmd:\n" + "\n".join(runcmd_lines) + "\n"

    user_data.write_text(content)
    console.print(f"[dim]Injected PXE setup into cloud-init user-data (user: {pi_user}).[/dim]")


# ==================== SD Card Layout ====================


def write_sd_card(
    boot_mount: Path,
    target_username: str,
    password_hash: str,
    ssh_keys: list[str],
    packages: list[str],
    late_commands: list[str],
) -> None:
    """Write all required files to the SD card boot partition."""
    sd_repo = boot_mount / "pi-pxe-server"

    if sd_repo.exists():
        shutil.rmtree(sd_repo)

    sd_repo.mkdir()
    (sd_repo / "templates").mkdir()
    (sd_repo / "scripts").mkdir()
    (sd_repo / "autoinstall").mkdir()

    # Copy template files that pi-setup.sh will reference
    for name in ["dnsmasq.conf.tpl", "grub-x86_64.cfg.tpl", "pi-config.txt.tpl", "pi-cmdline.txt.tpl", "nginx-pxe.conf"]:
        shutil.copyfile(TEMPLATES_DIR / name, sd_repo / "templates" / name)

    # Copy pi-setup.sh
    shutil.copyfile(REPO_DIR / "scripts" / "pi-setup.sh", sd_repo / "scripts" / "pi-setup.sh")

    # Render and write autoinstall user-data
    user_data_content = render_autoinstall(
        target_username=target_username,
        password_hash=password_hash,
        ssh_keys=ssh_keys,
        packages=packages,
        late_commands=late_commands,
    )
    (sd_repo / "autoinstall" / "user-data").write_text(user_data_content)

    # Static autoinstall files
    shutil.copyfile(TEMPLATES_DIR / "autoinstall-meta-data", sd_repo / "autoinstall" / "meta-data")
    (sd_repo / "autoinstall" / "vendor-data").touch()

    # Inject into Pi Imager's cloud-init user-data
    user_data = boot_mount / "user-data"
    if user_data.exists():
        _inject_cloud_init(user_data)
    else:
        console.print(
            "[yellow]WARNING:[/yellow] No user-data found on boot partition.\n"
            "Did you configure the Pi in the Imager? Setup will not auto-run."
        )


# ==================== Command ====================


@app.command()
def prepare(
    boot_path: str = typer.Argument(None, help="Path to the Pi boot partition. Auto-detects if omitted."),
    pi_hostname: str = typer.Option(None, "--pi-hostname", help="Pi hostname (set in Raspberry Pi Imager)"),
    pi_user: str = typer.Option(None, "--pi-user", help="Pi username (set in Raspberry Pi Imager)"),
    username: str = typer.Option(None, "--username", help="Target machine username"),
    password: str = typer.Option(None, "--password", help="Target machine password"),
    ssh_key: str = typer.Option(None, "--ssh-key", help="SSH public key (raw string)"),
    ssh_key_file: str = typer.Option(None, "--ssh-key-file", help="Path to SSH public key file"),
    non_interactive: bool = typer.Option(False, "--yes", "-y", help="Skip confirmations"),
):
    """Prepare a Raspberry Pi SD card as a PXE server."""

    console.print(Panel("Pi PXE Server - SD Card Preparation", style="bold blue"))

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
        raise typer.Exit(1)

    # ---- Gather inputs ----
    console.print("\n[bold]PXE Server (Raspberry Pi)[/bold]")

    if not pi_hostname:
        pi_hostname = typer.prompt("Pi hostname", default="pxe-server")

    if not pi_user:
        pi_user = typer.prompt("Pi username")

    console.print("\n[bold]Target Machine Configuration[/bold]")
    console.print("[dim]These settings apply to all machines installed via PXE.[/dim]")

    if not username:
        username = typer.prompt("Username")

    resolved_password = prompt_password(password)
    ssh_key_resolved = prompt_ssh_key(ssh_key, ssh_key_file, non_interactive)

    # ---- Generate password hash ----
    console.print("\nGenerating password hash...")
    password_hash = generate_password_hash(resolved_password)

    # ---- Write to SD card ----
    console.print("Writing to SD card...")
    write_sd_card(
        boot_mount=boot_mount,
        target_username=username,
        password_hash=password_hash,
        ssh_keys=[ssh_key_resolved],
        packages=DEFAULT_PACKAGES,
        late_commands=[
            f"echo '{username} ALL=(ALL) NOPASSWD:ALL' > /target/etc/sudoers.d/{username}",
            f"chmod 440 /target/etc/sudoers.d/{username}",
        ],
    )

    # ---- Summary ----
    table = Table(title="Configuration Summary", show_header=False)
    table.add_column("Key", style="cyan")
    table.add_column("Value", style="white")
    table.add_row("Pi Hostname", pi_hostname)
    table.add_row("Pi User", pi_user)
    table.add_row("Target Username", username)
    table.add_row("SSH Key", ssh_key_resolved[:50] + "..." if len(ssh_key_resolved) > 50 else ssh_key_resolved)
    table.add_row("Boot Partition", str(boot_mount))
    console.print()
    console.print(table)

    console.print(Panel(
        "[bold green]SD Card Ready![/bold green]\n\n"
        "Next steps:\n"
        "  1. Eject the SD card\n"
        "  2. Insert into Pi and power on (connect ethernet first)\n"
        "  3. Wait for setup (~5-10 min, mostly Ubuntu ISO download)\n"
        f"  4. Monitor: [cyan]ssh {pi_user}@{pi_hostname} 'sudo tail -f /var/log/pxe-setup.log'[/cyan]\n"
        "  5. PXE boot any machine on the network",
        title="Done",
    ))


if __name__ == "__main__":
    app()
