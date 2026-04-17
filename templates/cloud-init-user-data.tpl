#cloud-config
hostname: ubuntu
manage_etc_hosts: true
users:
  - name: $target_username
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    lock_passwd: false
    passwd: "$target_password_hash"
    ssh_authorized_keys:
$target_ssh_keys
package_update: true
package_upgrade: true
packages:
$target_packages
$target_late_commands_block
