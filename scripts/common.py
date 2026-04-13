"""Shared helpers for PXE homelab CLI scripts."""

import re
import subprocess
import sys
from pathlib import Path

try:
    import typer
    from rich.console import Console
except ImportError:
    print("Missing dependencies. Install with:")
    print("  pip install typer rich")
    sys.exit(1)

console = Console()

REPO_DIR = Path(__file__).resolve().parent.parent
CONFIG_DIR = REPO_DIR / "ansible" / "group_vars"
TEMPLATES_DIR = REPO_DIR / "templates"


def generate_password_hash(password: str) -> str:
    """Generate a SHA-512 password hash using the best available method."""
    # Python crypt module (Linux/macOS)
    try:
        import crypt

        return crypt.crypt(password, crypt.mksalt(crypt.METHOD_SHA512))
    except (ImportError, AttributeError):
        pass

    # openssl
    try:
        result = subprocess.run(
            ["openssl", "passwd", "-6", password],
            capture_output=True,
            text=True,
        )
        if result.returncode == 0 and result.stdout.strip():
            return result.stdout.strip()
    except FileNotFoundError:
        pass

    # mkpasswd
    try:
        result = subprocess.run(
            ["mkpasswd", "--method=SHA-512", password],
            capture_output=True,
            text=True,
        )
        if result.returncode == 0 and result.stdout.strip():
            return result.stdout.strip()
    except FileNotFoundError:
        pass

    console.print("[red]No password hashing tool found (need python3 crypt, openssl, or mkpasswd)[/red]")
    raise typer.Exit(1)


def find_ssh_pubkey() -> str | None:
    """Find the user's SSH public key."""
    ssh_dir = Path.home() / ".ssh"
    for name in ["id_ed25519.pub", "id_rsa.pub", "id_ecdsa.pub"]:
        keyfile = ssh_dir / name
        if keyfile.exists():
            return keyfile.read_text().strip()
    return None


def validate_mac(mac: str) -> str:
    """Validate and normalize a MAC address to colon-separated lowercase."""
    mac = mac.strip().lower()
    if re.match(r"^([0-9a-f]{2}:){5}[0-9a-f]{2}$", mac):
        return mac
    if re.match(r"^([0-9a-f]{2}-){5}[0-9a-f]{2}$", mac):
        return mac.replace("-", ":")
    if re.match(r"^[0-9a-f]{12}$", mac):
        return ":".join(mac[i : i + 2] for i in range(0, 12, 2))
    raise typer.BadParameter(f"Invalid MAC address: {mac} (use format aa:bb:cc:dd:ee:ff)")


def resolve_ssh_key(ssh_key: str | None, ssh_key_file: str | None) -> str | None:
    """Resolve an SSH key from either a raw string or a file path."""
    if ssh_key_file:
        path = Path(ssh_key_file).expanduser()
        if not path.exists():
            raise typer.BadParameter(f"SSH key file not found: {path}")
        return path.read_text().strip()
    return ssh_key


def prompt_ssh_key(ssh_key: str | None, ssh_key_file: str | None, non_interactive: bool = False) -> str:
    """Interactively prompt for an SSH key if not provided via flags."""
    resolved = resolve_ssh_key(ssh_key, ssh_key_file)
    if resolved:
        return resolved

    found_key = find_ssh_pubkey()
    if found_key:
        key_preview = found_key[:60] + "..." if len(found_key) > 60 else found_key
        console.print(f"\nFound SSH key: [dim]{key_preview}[/dim]")
        if non_interactive or typer.confirm("Use this key?", default=True):
            return found_key

    ssh_key_input = typer.prompt("SSH public key (paste key or path to .pub file)")
    key_path = Path(ssh_key_input).expanduser()
    if key_path.exists():
        return key_path.read_text().strip()
    return ssh_key_input.strip()


def prompt_password(password: str | None) -> str:
    """Prompt for a password if not provided via flag."""
    if password:
        return password
    return typer.prompt("Password", hide_input=True, confirmation_prompt=True)


def yaml_list(items: list[str], indent: int = 2) -> str:
    """Format a list as YAML list items. Returns '[]' for empty lists."""
    if not items:
        return " " * indent + "[]" if indent > 0 else "[]"
    prefix = " " * indent
    return "\n".join(f"{prefix}- {item}" for item in items)
