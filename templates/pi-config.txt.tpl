[all]
arm_64bit=1
kernel=vmlinuz
cmdline=cmdline.txt
initramfs initrd followkernel
enable_uart=1
dtparam=audio=off
dtoverlay=vc4-kms-v3d
disable_fw_kms_setup=1
gpu_mem=16

[pi4]
arm_boost=1

[pi3+]
dtoverlay=vc4-kms-v3d,cma-128

[pi02]
dtoverlay=vc4-kms-v3d,cma-128

[all]
