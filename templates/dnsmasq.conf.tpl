# ProxyDHCP mode - works alongside existing DHCP
port=0
dhcp-range=__NETWORK__,proxy

# x86_64 UEFI clients get GRUB
dhcp-match=set:efi-x86_64,option:client-arch,7
dhcp-boot=tag:efi-x86_64,x86_64/grubnetx64.efi
pxe-service=x86-64_EFI,"Network Boot (x86_64)",x86_64/grubnetx64.efi

# Pi native network boot: the Pi requests files via TFTP without
# sending UEFI arch codes. It looks for files in a directory named
# after its serial number, then falls back to the TFTP root.
# We symlink known serials to arm64/ or use arm64/ as the fallback.
pxe-service=0,"Raspberry Pi Boot"

enable-tftp
tftp-root=/srv/tftp

log-dhcp
log-queries
