# ProxyDHCP mode - works alongside existing DHCP
port=0
dhcp-range=__NETWORK__,proxy

# x86_64 UEFI PXE boot
dhcp-boot=grubnetx64.efi
pxe-service=x86-64_EFI,"Network Boot",grubnetx64.efi

enable-tftp
tftp-root=/srv/tftp

log-dhcp
log-queries
