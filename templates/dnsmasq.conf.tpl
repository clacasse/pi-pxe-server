# ProxyDHCP mode - works alongside existing DHCP
port=0
dhcp-range=__NETWORK__,proxy

# PXE boot settings - serve any machine that requests it
dhcp-boot=grubnetx64.efi
pxe-service=x86-64_EFI,"Network Boot",grubnetx64.efi

enable-tftp
tftp-root=/srv/tftp

log-dhcp
log-queries
