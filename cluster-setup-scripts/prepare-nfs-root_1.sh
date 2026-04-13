#!/bin/bash
# Run as root on master after setup-master.sh

#set -e

# Copy base OS from image (adjust path to your Ubuntu 22.04 image)

# Paths and filenames
IMAGE_XZ="ubuntu-22.04.3-preinstalled-server-arm64+raspi.img.xz"
IMAGE_IMG="ubuntu-22.04.3-preinstalled-server-arm64+raspi.img"
MOUNT_ROOT="/mnt/ubuntu_img_root"
MOUNT_BOOT="/mnt/ubuntu_img_boot"
NFS_ROOT="/srv/nfs/rpi-root"
TFTP_ROOT="/srv/tftp"

# 1. Uncompress the image if needed
if [ ! -f "$IMAGE_IMG" ]; then
    echo "Uncompressing $IMAGE_XZ..."
    unxz -k "$IMAGE_XZ"
fi

# 2. Create mount points
echo "create mount points..."
mkdir -p "$MOUNT_ROOT" "$MOUNT_BOOT"

# 3. Setup loop device with partitions
echo "setting up loop device with partitions..."
LOOP_DEV=$(losetup --show -fP "$IMAGE_IMG")
BOOT_PART="${LOOP_DEV}p1"
ROOT_PART="${LOOP_DEV}p2"

# Wait for device nodes to appear
echo "waiting safely for device nodes..."
sleep 5

# 4. Mount boot and root partitions
echo "mounting boot and root partitions..."
mount "$BOOT_PART" "$MOUNT_BOOT"
mount "$ROOT_PART" "$MOUNT_ROOT"

# 5. Copy root filesystem to NFS root
if [ -d "$NFS_ROOT" ]; then
    echo "deleting old nfs root..."
    rm -rf "$NFS_ROOT"
fi

echo "copying root files from mount..."
cp -a "$MOUNT_ROOT" "$NFS_ROOT"

# 6. Copy boot files to NFS root and TFTP root
if [ -d "$TFTP_ROOT" ]; then
    echo "deleting old tftp root..."
    rm -rf "$TFTP_ROOT"
fi
echo "creating new tftp root..."
mkdir -p "$TFTP_ROOT"

echo "copying boot files..."
cp -a "$MOUNT_BOOT"/* "$NFS_ROOT/boot/"
cp -a "$MOUNT_BOOT"/* "$TFTP_ROOT/"

# 7. Unmount partitions and detach loop device
echo "unmounting and removing loop devices and mounts"
umount "$MOUNT_BOOT"
umount "$MOUNT_ROOT"
losetup -d "$LOOP_DEV"
rmdir "$MOUNT_BOOT" "$MOUNT_ROOT"

# --- 2. Mount and Chroot to Base Filesystem ---
echo "=== mounting for chrooting into $NFS_BASE ==="
mount --bind /dev $NFS_ROOT/dev
mount --bind /proc $NFS_ROOT/proc
mount --bind /sys $NFS_ROOT/sys
mount --bind /run $NFS_ROOT/run
mount --bind /tmp $NFS_ROOT/tmp

# remove default fstab from nfs root
echo "removing default fstab..."
chroot /srv/nfs/rpi-root /bin/bash -c "rm -f /etc/fstab"

# copy resolv.conf to allow internet address resolution
echo "copying resolv.conf to allow internet address resolution..."
chroot /srv/nfs/rpi-root /bin/bash -c "mkdir -p /run/systemd/resolve"
chroot /srv/nfs/rpi-root /bin/bash -c "touch /run/systemd/resolve/stub-resolv.conf"

cat <<EOF > /srv/nfs/rpi-root/etc/resolv.conf
nameserver 127.0.0.53
options edns0 trust-ad
search lan
EOF

#cp /etc/resolv.conf /srv/nfs/rpi-root/etc/resolv.conf

# << ////

# add a user
echo "adding a user..."
chroot /srv/nfs/rpi-root /bin/bash -c "adduser pi"

# add user to sudo group
echo "adding user to sudo group..."
chroot /srv/nfs/rpi-root /bin/bash -c "usermod -aG sudo pi"

# Install essential tools in NFS root
chroot /srv/nfs/rpi-root /bin/bash -c "apt update && apt install -y openssh-server cloud-init netplan.io initramfs-tools"

# copy nfsmount fix for v4
echo "copying additional scripts and service unit files..."
cp /home/pi/nfsmount /srv/nfs/rpi-root/usr/lib/klibc/bin/nfsmount

cp /home/pi/set-hostname.sh /srv/nfs/rpi-root/etc/set-hostname.sh
cp /home/pi/set-hostname.service /srv/nfs/rpi-root/etc/systemd/system/set-hostname.service

# move hostname and hosts to var local
echo "moving hostname and hosts files to writeable var local overlay..."
mv /srv/nfs/rpi-root/etc/hostname /srv/nfs/rpi-root/var/local/hostname
ln -sf /var/local/hostname /srv/nfs/rpi-root/etc/hostname

mv /srv/nfs/rpi-root/etc/hosts /srv/nfs/rpi-root/var/local/hosts
ln -sf /var/local/hosts /srv/nfs/rpi-root/etc/hosts

cp /home/pi/mount-overlay.sh /srv/nfs/rpi-root/usr/local/bin/mount-overlay.sh
cp /home/pi/overlay-root.service /srv/nfs/rpi-root/etc/systemd/system/overlay-root.service

echo "setting scripts as executable..."
chroot /srv/nfs/rpi-root /bin/bash -c "chmod +x /usr/lib/klibc/bin/nfsmount"
chroot /srv/nfs/rpi-root /bin/bash -c "chmod +x /etc/set-hostname.sh"
chroot /srv/nfs/rpi-root /bin/bash -c "chmod +x /usr/local/bin/mount-overlay.sh"

# Configure network (static dhcp IP lease example)
cat <<EOF > /srv/nfs/rpi-root/etc/netplan/50-cloud-init.yaml
network:
  version: 2
  ethernets:
    eth0:
      dhcp4: true
EOF

# Enable overlay module
echo "setting up overlay module in initramfs..."

# mkdir -p /srv/nfs/rpi-root/etc/initramfs-tools
# touch /srv/nfs/rpi-root/etc/initramfs-tools/modules

chroot /srv/nfs/rpi-root /bin/bash -c "echo 'overlay' >> /etc/initramfs-tools/modules"
#echo "overlay" >> /srv/nfs/rpi-root/etc/initramfs-tools/modules
chroot /srv/nfs/rpi-root update-initramfs -u

# ////

# unmount chroot from rpi-root
echo "unmounting chroot from base filesystems..."
umount $NFS_ROOT/dev
umount $NFS_ROOT/proc
umount $NFS_ROOT/sys
umount $NFS_ROOT/run
umount $NFS_ROOT/tmp

echo "NFS root prepared!"
