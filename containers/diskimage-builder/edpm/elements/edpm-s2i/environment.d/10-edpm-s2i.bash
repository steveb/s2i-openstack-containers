# Distribution identity for the tarball-based root filesystem.
#
# These replace the environment that diskimage-builder's centos/rhel
# elements provide. The tarball element does not know which OS its tarball
# contains, so the s2i element declares it: the os_source content and the
# RPM repositories used to build it are CentOS Stream.

export DISTRO_NAME=centos
export DIB_RELEASE=${DIB_RELEASE:-10-stream}
export YUM=dnf

# The UEFI bootloader element copies the secure boot grub.cfg into
# /boot/efi/$EFI_BOOT_DIR. Without it the image is built without a shim
# boot entry and is not bootable on UEFI systems.
export EFI_BOOT_DIR=EFI/centos
