#!/usr/bin/env python3
"""Generate or edit Ansible configuration for PXE homelab.

Works standalone or called from prepare_sd.py.
"""

import sys
from datetime import datetime, timezone
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
    CONFIG_DIR,
    REPO_DIR,
    TEMPLATES_DIR,
    console,
    generate_password_hash,
    prompt_password,
    prompt_ssh_key,
    validate_mac,
    yaml_list,
)

app = typer.Typer(help="Generate or edit Ansible configuration for PXE homelab.")

GRUB_SIGNED_DEB_URL = "http://archive.ubuntu.com/ubuntu/pool/main/g/grub2-signed/grub-efi-amd64-signed_1.202+2.12-1ubuntu7_amd64.deb"
GRUB_MODULES_DEB_URL = "http://archive.ubuntu.com/ubuntu/pool/main/g/grub2-unsigned/grub-efi-amd64-bin_2.12-1ubuntu7_amd64.deb"
DEFAULT_PACKAGES = ["curl", "git", "ansible", "jq"]


def load_existing_config() -> dict | None:
    """Load existing all.yml if present. Returns dict or None."""
    config_path = CONFIG_DIR / "all.yml"
    if not config_path.exists():
        return None

    try:
        import yaml

        with open(config_path) as f:
            return yaml.safe_load(f)
    except ImportError:
        pass

    # Fallback: simple line-by-line parsing for key: value pairs
    config = {}
    with open(config_path) as f:
        for line in f:
            line = line.strip()
            if line.startswith("#") or not line or ":" not in line:
                continue
            key, _, value = line.partition(":")
            value = value.strip().strip('"').strip("'")
            if value:
                config[key.strip()] = value
    return config


def render_template(template_name: str, variables: dict) -> str:
    """Render a template file with the given variables."""
    template_path = TEMPLATES_DIR / template_name
    template = Template(template_path.read_text())
    return template.substitute(variables)


def write_all_yml(
    target_hostname: str,
    target_username: str,
    password_hash: str,
    pxe_clients: list[dict],
    ssh_keys: list[str],
    packages: list[str],
    late_commands: list[str],
    ubuntu_version: str = "24.04.2",
) -> Path:
    """Generate ansible/group_vars/all.yml from template."""
    CONFIG_DIR.mkdir(parents=True, exist_ok=True)
    timestamp = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

    # Format list fields as YAML
    if pxe_clients:
        pxe_clients_yaml = "\n".join(
            f'  - mac: "{c["mac"]}"\n    name: "{c["name"]}"' for c in pxe_clients
        )
    else:
        pxe_clients_yaml = "  []"

    ssh_keys_yaml = yaml_list(ssh_keys)
    packages_yaml = yaml_list(packages)
    late_commands_yaml = yaml_list(late_commands)

    variables = {
        "timestamp": timestamp,
        "ubuntu_version": ubuntu_version,
        "grub_signed_deb_url": GRUB_SIGNED_DEB_URL,
        "grub_modules_deb_url": GRUB_MODULES_DEB_URL,
        "pxe_clients": pxe_clients_yaml,
        "target_hostname": target_hostname,
        "target_username": target_username,
        "target_password_hash": password_hash,
        "target_ssh_authorized_keys": ssh_keys_yaml,
        "target_packages": packages_yaml,
        "target_late_commands": late_commands_yaml,
    }

    config_path = CONFIG_DIR / "all.yml"
    config_path.write_text(render_template("all.yml.tpl", variables))
    return config_path


def write_inventory_yml(pi_hostname: str, pi_user: str) -> Path:
    """Generate ansible/inventory.yml from template."""
    timestamp = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    variables = {
        "timestamp": timestamp,
        "pi_hostname": pi_hostname,
        "pi_user": pi_user,
    }

    inventory_path = REPO_DIR / "ansible" / "inventory.yml"
    inventory_path.write_text(render_template("inventory.yml.tpl", variables))
    return inventory_path


def collect_pxe_clients(existing: list[dict] | None = None) -> list[dict]:
    """Interactively collect PXE client MAC/name pairs."""
    clients = []

    if existing:
        console.print("\n[bold]Current PXE clients:[/bold]")
        for c in existing:
            console.print(f"  {c['name']} ({c['mac']})")
        if typer.confirm("Keep existing clients?", default=True):
            clients = list(existing)

    while True:
        if clients:
            if not typer.confirm("Add another PXE client?", default=False):
                break
        else:
            console.print("\n[bold]PXE Clients[/bold] (machines to install via PXE)")

        mac = typer.prompt("  MAC address (aa:bb:cc:dd:ee:ff)")
        mac = validate_mac(mac)
        name = typer.prompt("  Hostname for this machine")
        clients.append({"mac": mac, "name": name})

    return clients


def collect_packages(existing: list[str] | None = None) -> list[str]:
    """Interactively collect package list."""
    defaults = existing or DEFAULT_PACKAGES
    console.print(f"\n[bold]Packages to install:[/bold] {', '.join(defaults)}")
    if typer.confirm("Use these packages?", default=True):
        return defaults

    pkg_input = typer.prompt("Enter packages (comma-separated)")
    return [p.strip() for p in pkg_input.split(",") if p.strip()]


def collect_late_commands(existing: list[str] | None = None) -> list[str]:
    """Interactively collect late-commands."""
    commands = []

    if existing:
        console.print("\n[bold]Current late-commands:[/bold]")
        for cmd in existing:
            console.print(f"  {cmd}")
        if typer.confirm("Keep existing late-commands?", default=True):
            commands = list(existing)

    if not commands:
        if not typer.confirm("\nAdd late-commands (run at end of install)?", default=False):
            return []

    while True:
        cmd = typer.prompt("  Command (or 'done' to finish)", default="done")
        if cmd.lower() == "done":
            break
        commands.append(cmd)

    return commands


@app.command()
def configure(
    pi_hostname: str = typer.Option(None, "--pi-hostname", help="Pi hostname (for remote Ansible access)"),
    pi_user: str = typer.Option(None, "--pi-user", help="Pi username (set in Raspberry Pi Imager)"),
    hostname: str = typer.Option(None, "--hostname", help="Target machine hostname"),
    username: str = typer.Option(None, "--username", help="Target machine username"),
    password: str = typer.Option(None, "--password", help="Target machine password (hashed automatically)"),
    mac: str = typer.Option(None, "--mac", help="Target machine MAC address"),
    ssh_key: str = typer.Option(None, "--ssh-key", help="SSH public key (raw string)"),
    ssh_key_file: str = typer.Option(None, "--ssh-key-file", help="Path to SSH public key file"),
    packages: str = typer.Option(None, "--packages", help="Comma-separated list of packages"),
    late_commands: list[str] = typer.Option(None, "--late-command", help="Late-command to run (repeatable)"),
    ubuntu_version: str = typer.Option(None, "--ubuntu-version", help="Ubuntu version to install"),
    edit: bool = typer.Option(False, "--edit", help="Edit existing configuration"),
    non_interactive: bool = typer.Option(False, "--yes", "-y", help="Skip confirmations"),
):
    """Generate or edit Ansible configuration for PXE homelab."""

    console.print(Panel("PXE Homelab - Configuration", style="bold blue"))

    # Load existing config if editing
    existing = load_existing_config() if edit else None
    if edit and existing:
        console.print("[dim]Loaded existing configuration. Current values shown as defaults.[/dim]\n")
    elif edit:
        console.print("[yellow]No existing configuration found. Creating new.[/yellow]\n")

    def default(key: str, fallback: str = "") -> str:
        if existing and key in existing:
            return existing[key]
        return fallback

    # ---- Pi connection info (for inventory) ----
    console.print("[bold]PXE Server (Raspberry Pi)[/bold]")

    if not pi_hostname:
        pi_hostname = typer.prompt("Pi hostname", default="pxe-server")

    if not pi_user:
        pi_user = typer.prompt("Pi username")

    # ---- Target machine config ----
    console.print("\n[bold]Target Machine Configuration[/bold]")

    if not hostname:
        hostname = typer.prompt("Hostname", default=default("target_hostname") or None)

    if not username:
        username = typer.prompt("Username", default=default("target_username") or None)

    resolved_password = prompt_password(password)

    # SSH key
    ssh_key_resolved = prompt_ssh_key(ssh_key, ssh_key_file, non_interactive)

    # PXE clients
    if mac:
        pxe_clients = [{"mac": validate_mac(mac), "name": hostname}]
    elif non_interactive:
        pxe_clients = []
    else:
        existing_clients = existing.get("pxe_clients") if existing else None
        pxe_clients = collect_pxe_clients(existing_clients)

    # Packages
    if packages:
        pkg_list = [p.strip() for p in packages.split(",")]
    elif non_interactive:
        pkg_list = DEFAULT_PACKAGES
    else:
        existing_pkgs = existing.get("target_packages") if existing else None
        pkg_list = collect_packages(existing_pkgs)

    # Late commands
    if late_commands:
        cmd_list = list(late_commands)
    elif non_interactive:
        cmd_list = []
    else:
        existing_cmds = existing.get("target_late_commands") if existing else None
        cmd_list = collect_late_commands(existing_cmds)

    # Ubuntu version
    if not ubuntu_version:
        ubuntu_version = default("ubuntu_version", "24.04.2")
        if not non_interactive:
            ubuntu_version = typer.prompt("Ubuntu version", default=ubuntu_version)

    # ---- Generate password hash ----
    console.print("\nGenerating password hash...")
    password_hash = generate_password_hash(resolved_password)

    # ---- Write configs ----
    console.print("Writing configuration files...")

    all_yml_path = write_all_yml(
        target_hostname=hostname,
        target_username=username,
        password_hash=password_hash,
        pxe_clients=pxe_clients,
        ssh_keys=[ssh_key_resolved],
        packages=pkg_list,
        late_commands=cmd_list,
        ubuntu_version=ubuntu_version,
    )
    console.print(f"  [dim]{all_yml_path}[/dim]")

    inventory_path = write_inventory_yml(pi_hostname=pi_hostname, pi_user=pi_user)
    console.print(f"  [dim]{inventory_path}[/dim]")

    # ---- Summary ----
    table = Table(title="Configuration Summary", show_header=False)
    table.add_column("Key", style="cyan")
    table.add_column("Value", style="white")
    table.add_row("Pi Hostname", pi_hostname)
    table.add_row("Pi User", pi_user)
    table.add_row("Target Hostname", hostname)
    table.add_row("Target Username", username)
    table.add_row("SSH Key", ssh_key_resolved[:50] + "..." if len(ssh_key_resolved) > 50 else ssh_key_resolved)
    table.add_row("PXE Clients", ", ".join(f"{c['name']} ({c['mac']})" for c in pxe_clients) or "none")
    table.add_row("Packages", ", ".join(pkg_list))
    table.add_row("Late Commands", str(len(cmd_list)) + " configured" if cmd_list else "none")
    table.add_row("Ubuntu Version", ubuntu_version)
    console.print()
    console.print(table)

    console.print(Panel(
        "[bold green]Configuration complete![/bold green]\n\n"
        "PXE server IP is auto-detected at Ansible runtime.\n"
        "No need to know it in advance.",
        title="Done",
    ))


if __name__ == "__main__":
    app()
