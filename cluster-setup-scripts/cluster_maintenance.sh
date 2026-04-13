#!/bin/bash

# Script to update the base OS for all PXE/OverlayFS Raspberry Pi nodes

# --- CONFIGURATION ---
NFS_BASE="/nfs/base"
NFS_BOOT="/var/pxe/boot"
MASTER_USER="pi"

# --- 1. Notify and Prepare ---
echo "=== PXE Cluster Maintenance ==="
echo "Notify users and shut down all worker nodes before proceeding."
read -p "Have you shut down all worker nodes? [y/N]: " CONFIRM
[[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]] && { echo "Aborting."; exit 1; }

# --- 2. Mount and Chroot to Base Filesystem ---
echo "=== Chrooting into $NFS_BASE ==="
mount --bind /dev $NFS_BASE/dev
mount --bind /proc $NFS_BASE/proc
mount --bind /sys $NFS_BASE/sys
mount --bind /run $NFS_BASE/run
mount --bind /tmp $NFS_BASE/tmp

chroot $NFS_BASE /bin/bash <<'EOF'
echo "=== Updating base OS ==="
apt update
apt full-upgrade -y
apt autoremove -y
apt clean
EOF

umount $NFS_BASE/dev
umount $NFS_BASE/proc
umount $NFS_BASE/sys
umount $NFS_BASE/run
umount $NFS_BASE/tmp

# --- 3. Update Boot Files if Needed ---
echo "=== Updating boot files ==="
if [ -d "$NFS_BASE/boot/firmware" ]; then
    rsync -xa --delete "$NFS_BASE/boot/firmware/" "$NFS_BOOT/"
else
    rsync -xa --delete "$NFS_BASE/boot/" "$NFS_BOOT/"
fi

# --- 4. Update Initramfs (if needed) ---
echo "=== Updating initramfs in base ==="
chroot $NFS_BASE update-initramfs -u

# --- 5. Reload NFS Exports and Restart NFS Server ---
echo "=== Reloading NFS exports and restarting NFS server ==="
exportfs -ra
systemctl restart nfs-kernel-server

# --- 6. Done ---
echo "=== Update complete. You may now clear overlays (if desired) and boot your worker nodes. ==="
