# ProxyDHCP mode - works alongside existing DHCP
port=0
dhcp-range=__NETWORK__,proxy

# Architecture detection via DHCP option 93
dhcp-match=set:efi-x86_64,option:client-arch,7
dhcp-match=set:efi-arm64,option:client-arch,11

# Serve different boot files per architecture
dhcp-boot=tag:efi-x86_64,x86_64/grubnetx64.efi
dhcp-boot=tag:efi-arm64,arm64/grubnetaa64.efi
pxe-service=x86-64_EFI,"Network Boot (x86_64)",x86_64/grubnetx64.efi
pxe-service=ARM64_EFI,"Network Boot (ARM64)",arm64/grubnetaa64.efi

enable-tftp
tftp-root=/srv/tftp

log-dhcp
log-queries
