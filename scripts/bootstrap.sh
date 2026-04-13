#!/bin/bash
# Bootstrap a fresh Raspberry Pi as a PXE server
# Usage: curl -fsSL <url> | bash  (public repo)
#   or:  ./bootstrap.sh            (after cloning)
set -e

REPO_URL="${REPO_URL:-https://github.com/clacasse/pxe-homelab.git}"
REPO_DIR="/home/$(whoami)/pxe-homelab"

echo "=== PXE Server Bootstrap ==="

# Install dependencies
echo "Installing ansible and git..."
sudo apt update -qq
sudo apt install -y -qq ansible git

# Clone repo if not already in it
if [ ! -f "$REPO_DIR/ansible/setup-pxe-server.yml" ]; then
    echo "Cloning repo..."
    git clone "$REPO_URL" "$REPO_DIR"
fi

cd "$REPO_DIR"

# Create config from example if it doesn't exist
if [ ! -f ansible/group_vars/all.yml ]; then
    cp ansible/group_vars/all.yml.example ansible/group_vars/all.yml
    echo ""
    echo "=== IMPORTANT ==="
    echo "Edit ansible/group_vars/all.yml before running the playbook:"
    echo "  nano $REPO_DIR/ansible/group_vars/all.yml"
    echo ""
    echo "Then run:"
    echo "  cd $REPO_DIR"
    echo "  ansible-playbook -i localhost, -c local ansible/setup-pxe-server.yml"
    exit 0
fi

# Run the playbook
echo "Running Ansible playbook..."
ansible-playbook -i localhost, -c local ansible/setup-pxe-server.yml
