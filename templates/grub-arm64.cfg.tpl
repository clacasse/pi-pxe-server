linux /arm64/vmlinuz ip=dhcp url=http://__PI_IP__:8080/arm64/ubuntu.iso autoinstall "ds=nocloud-net;s=http://__PI_IP__:8080/autoinstall/"
initrd /arm64/initrd
boot
