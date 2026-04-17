#!/usr/bin/env python3
"""Prepare a Raspberry Pi target's SD card for first boot.

After flashing Ubuntu Server ARM64 with Raspberry Pi Imager, run this
script against the boot partition to inject cloud-init user-data. On
first boot, cloud-init creates your user, installs SSH keys, and
configures NOPASSWD sudo.

Usage:
    python scripts/prepare_pi_target.py /Volumes/system-boot
    python scripts/prepare_pi_target.py /Volumes/system-boot --username admin --ssh-key-file ~/.ssh/id_ed25519.pub -y
"""

import sys
from pathlib import Path
from string import Template

try:
    import typer
    from rich.console import Console
    from rich.panel import Panel
    from rich.table import Table
except ImportError:
    print("Missing dependencies. Install with:")
    print("  pip install -r requirements.txt")
    sys.exit(1)

from common import (
    REPO_DIR,
    TEMPLATES_DIR,
    console,
    generate_password_hash,
    prompt_password,
    prompt_ssh_key,
)

app = typer.Typer(add_completion=False)

DEFAULT_PACKAGES = ["curl", "wget", "git", "jq", "ca-certificates", "openssh-server"]


def _yaml_list(items: list[str], indent: int = 4) -> str:
    if not items:
        return " " * indent + "[]"
    prefix = " " * indent
    return "\n".join(f"{prefix}- {item}" for item in items)


def render_cloud_init(
    username: str,
    password_hash: str,
    ssh_keys: list[str],
    packages: list[str],
) -> str:
    """Render the cloud-init user-data template."""
    template_path = TEMPLATES_DIR / "cloud-init-user-data.tpl"
    template = Template(template_path.read_text())

    rendered = template.substitute(
        target_username=username,
        target_password_hash=password_hash,
        target_ssh_keys=_yaml_list(ssh_keys, indent=6),
        target_packages=_yaml_list(packages, indent=2),
        target_late_commands_block="",
    )
    import re
    rendered = re.sub(r"\n\n+", "\n", rendered)
    return rendered


def is_pi_boot_partition(path: Path) -> bool:
    """Check if a path looks like a Pi Ubuntu boot partition."""
    indicators = ["config.txt", "cmdline.txt", "user-data", "meta-data"]
    return any((path / f).exists() for f in indicators)


@app.command()
def main(
    boot_mount: Path = typer.Argument(
        ...,
        help="Path to the Pi's boot/system-boot partition (e.g. /Volumes/system-boot).",
    ),
    username: str = typer.Option(None, help="Username for the target Pi."),
    password: str = typer.Option(None, help="Password for the target Pi."),
    ssh_key: str = typer.Option(None, help="SSH public key string."),
    ssh_key_file: str = typer.Option(None, help="Path to SSH public key file."),
    non_interactive: bool = typer.Option(False, "-y", help="Accept defaults without prompting."),
) -> None:
    """Prepare a Raspberry Pi target SD card with cloud-init configuration."""
    console.print(Panel("Node Bootstrap - Pi Target Preparation", style="bold blue"))

    if not boot_mount.exists():
        console.print(f"[red]Path not found: {boot_mount}[/red]")
        raise typer.Exit(1)

    if not is_pi_boot_partition(boot_mount):
        console.print(f"[yellow]Warning: {boot_mount} doesn't look like a Pi boot partition.[/yellow]")
        if not non_interactive and not typer.confirm("Continue anyway?"):
            raise typer.Exit(0)

    # Prompt for inputs
    if not username:
        username = typer.prompt("Username")

    resolved_password = prompt_password(password)
    ssh_key_resolved = prompt_ssh_key(ssh_key, ssh_key_file, non_interactive)

    # Generate password hash
    console.print("\nGenerating password hash...")
    password_hash = generate_password_hash(resolved_password)

    # Render cloud-init user-data
    user_data = render_cloud_init(
        username=username,
        password_hash=password_hash,
        ssh_keys=[ssh_key_resolved],
        packages=DEFAULT_PACKAGES,
    )

    # Write to boot partition
    console.print("Writing cloud-init configuration...")
    (boot_mount / "user-data").write_text(user_data)
    console.print(f"  [green]✓[/green] {boot_mount / 'user-data'}")

    # Ensure meta-data exists
    meta_data = boot_mount / "meta-data"
    if not meta_data.exists():
        meta_data.write_text("{}\n")
        console.print(f"  [green]✓[/green] {meta_data}")

    # Summary
    table = Table(title="Configuration Summary", show_header=False)
    table.add_column("Key", style="cyan")
    table.add_column("Value", style="white")
    table.add_row("Username", username)
    table.add_row("SSH Key", (ssh_key_resolved[:50] + "...") if len(ssh_key_resolved) > 50 else ssh_key_resolved)
    table.add_row("NOPASSWD sudo", "yes")
    table.add_row("Boot Partition", str(boot_mount))
    console.print(table)

    console.print("\n[green]Done.[/green] Eject the SD card, insert into Pi, and boot.")
    console.print("On first boot, cloud-init will configure the user and SSH access.")
    console.print(f"SSH in with: [cyan]ssh {username}@<pi-ip>[/cyan]")


if __name__ == "__main__":
    app()
