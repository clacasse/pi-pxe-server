#cloud-config
autoinstall:
  version: 1
  interactive-sections: []
  locale: en_US.UTF-8
  keyboard:
    layout: us
  storage:
    layout:
      name: lvm
      sizing-policy: all
  identity:
    username: $target_username
    password: "$target_password_hash"
  ssh:
    install-server: true
    allow-pw: true
    authorized-keys:
$target_ssh_keys
  packages:
$target_packages
$target_late_commands_block
  shutdown: reboot
