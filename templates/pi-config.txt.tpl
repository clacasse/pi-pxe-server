[all]
arm_64bit=1
kernel=vmlinuz
initramfs initrd followkernel
cmdline=cmdline.txt

# Disable splash and use serial console for debugging
disable_splash=1
enable_uart=1

# GPU memory (minimum for headless server)
gpu_mem=16
