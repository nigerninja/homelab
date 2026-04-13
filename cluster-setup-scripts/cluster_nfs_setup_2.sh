#!/bin/bash

# PXE/OverlayFS Kubernetes Cluster Setup Script (Copy from Master Node)

# --- Configuration ---
MASTER_IP="10.200.0.101"
MASTER_HOST="knode1"
NODE_IPS=("10.200.0.102" "10.200.0.103" "10.200.0.104")
NODE_HOSTS=("knode2" "knode3" "knode4")
USERNAME="pi"

# --- Check Arguments ---
if [ $# -ne 3 ]; then
    echo "Usage: $0 <serial1> <serial2> <serial3>"
    exit 1
fi
SERIALS=("$@")

# --- Install Required Packages on Base OS---
sudo apt update && sudo apt install -y rsync open-iscsi nfs-common dmsetup libraspberrypi-bin linux-modules-extra-raspi apache2-utils

# --- Directory Structure ---
mkdir -p /var/pxe/{tftp,boot}
mkdir -p /nfs/base /nfs/boot /nfs/overlays
for host in "${NODE_HOSTS[@]}"; do
    mkdir -p "/nfs/overlays/$host"
done
chmod -R 777 /var/pxe /nfs

# --- Copy Boot Files from Master Node ---
echo "Copying boot files from /boot or /boot/firmware..."
if [ -d /boot/firmware ]; then
    rsync -xa /boot/firmware/ /var/pxe/boot/
else
    rsync -xa /boot/ /var/pxe/boot/
fi

# --- Copy Root Filesystem from Master Node (Excluding Special Directories) ---
echo "Copying root filesystem from / to /nfs/base (excluding special dirs)..."
rsync -xaAX \
    --exclude={"/proc","/sys","/dev","/tmp","/run","/mnt","/media","/lost+found","/nfs","/var/pxe","/home/pi/homeserver_backups"} \
    / /nfs/base/

# --- Create excluded directories
echo "re-Creating excluded directories"
mkdir -p /nfs/base/{dev,lost+found,proc,run,sys,tmp}

# --- Install Required Packages for Master NFS OS---
sudo apt update && sudo apt install -y nfs-kernel-server tftpd-hpa rsync open-iscsi nfs-common dmsetup libraspberrypi-bin linux-modules-extra-raspi apache2-utils

# --- NFS Exports ---
echo "/nfs/base    *(ro,sync,no_subtree_check,no_root_squash)" > /etc/exports
echo "/nfs/boot    *(rw,sync,no_subtree_check,no_root_squash)" >> /etc/exports
for i in {0..2}; do
    echo "/nfs/overlays/${NODE_HOSTS[$i]} ${NODE_IPS[$i]}(rw,sync,no_subtree_check,no_root_squash)" >> /etc/exports
done
exportfs -ra
systemctl restart nfs-kernel-server

# --- Prepare Overlay Setup for Each Node ---
for i in {0..2}; do
    SERIAL_DIR="/var/pxe/tftp/${SERIALS[$i]}"
    mkdir -p "$SERIAL_DIR"

    # Copy boot files
    cp /var/pxe/boot/* "$SERIAL_DIR"

    # Prepare overlay workdir
    mkdir -p "/nfs/overlays/${NODE_HOSTS[$i]}/work"
    mkdir -p "/nfs/overlays/${NODE_HOSTS[$i]}/upper"

    # Set hostname in overlay (optional but recommended)
    mkdir -p "/nfs/overlays/${NODE_HOSTS[$i]}/upper/etc"
    echo "${NODE_HOSTS[$i]}" > "/nfs/overlays/${NODE_HOSTS[$i]}/upper/etc/hostname"
    cp /nfs/base/etc/hosts "/nfs/overlays/${NODE_HOSTS[$i]}/upper/etc/hosts"
    sed -i "s/127.0.1.1.*/127.0.1.1\t${NODE_HOSTS[$i]}/" "/nfs/overlays/${NODE_HOSTS[$i]}/upper/etc/hosts"

    # Generate cmdline.txt for overlay root
    echo "console=serial0,115200 console=tty1 ip=dhcp root=/dev/nfs nfsroot=$MASTER_IP:/nfs/base,vers=3 ro rootwait elevator=deadline" > "$SERIAL_DIR/cmdline.txt"
    echo "console=serial0,115200 console=tty1 ip=dhcp root=/dev/nfs nfsroot=$MASTER_IP:/nfs/base,vers=3 ro rootwait elevator=deadline init=/bin/ro-root.sh overlayroot=10.200.0.101:/nfs/overlays/${NODE_HOSTS[$i]}" >> "$SERIAL_DIR/cmdline.txt"

    # Generate fstab for /boot and overlay
    echo "$MASTER_IP:/nfs/boot /boot nfs defaults,vers=3 0 0" > "$SERIAL_DIR/fstab"
done

echo "PXE OverlayFS setup complete using current master node's filesystems."
echo "Configure your overlay mount at boot (initramfs or rc.local) for each node."
echo "You can now boot your Raspberry Pi nodes via network boot."
