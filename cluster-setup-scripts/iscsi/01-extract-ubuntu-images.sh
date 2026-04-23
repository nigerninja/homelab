#!/bin/bash
# =============================================================================
# 01-extract-ubuntu-images.sh
# =============================================================================
# Creates 15GB disk images for each worker node and copies Ubuntu 22.04 data
# from the source image. Uses a fresh partition table approach.
#
# Prerequisites:
#   - Run as root on knode1 (10.200.0.101)
#   - At least 50GB free space on the target disk
# =============================================================================

set -e

# Configuration
IMAGE_XZ="ubuntu-22.04.3-preinstalled-server-arm64+raspi.img.xz"
IMAGE_IMG="ubuntu-22.04.3-preinstalled-server-arm64+raspi.img"
WORK_DIR="/srv/iscsi"
MOUNT_ROOT="/mnt/ubuntu_img_root"
MOUNT_BOOT="/mnt/ubuntu_img_boot"
TEMP_NODE="/mnt/temp_node"

NODES=("knode2" "knode3" "knode4")
TARGET_IPS=("10.200.0.102" "10.200.0.103" "10.200.0.104")

# -----------------------------------------------------------------------------
# Helper functions
# -----------------------------------------------------------------------------
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

error_exit() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $1" >&2
    exit 1
}

cleanup() {
    log "Cleaning up..."
    umount "$MOUNT_BOOT" 2>/dev/null || true
    umount "$MOUNT_ROOT" 2>/dev/null || true
    umount "$TEMP_NODE/boot" 2>/dev/null || true
    umount "$TEMP_NODE/root" 2>/dev/null || true
    losetup -D 2>/dev/null || true
}

trap cleanup EXIT

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------
log "Starting Ubuntu image creation for iSCSI boot"

if [[ $EUID -ne 0 ]]; then
    error_exit "This script must be run as root"
fi

log "Installing required packages..."
apt-get update
apt-get install -y parted e2fsprogs rsync wget xz-utils dosfstools kpartx || \
    error_exit "Failed to install packages"

# Download image if needed
if [[ ! -f "$IMAGE_XZ" ]]; then
    log "Downloading Ubuntu 22.04.3 ARM64 image..."
    wget -O "$IMAGE_XZ" \
        "https://cdimage.ubuntu.com/ubuntu-server/jammy/daily-preinstalled/current/${IMAGE_XZ}"
else
    log "Image $IMAGE_XZ already exists, skipping download"
fi

# Extract image if needed
if [[ ! -f "$IMAGE_IMG" ]]; then
    log "Extracting $IMAGE_XZ..."
    unxz -k "$IMAGE_XZ" || error_exit "Failed to extract image"
else
    log "Image $IMAGE_IMG already exists, skipping extraction"
fi

mkdir -p "$WORK_DIR" "$MOUNT_ROOT" "$MOUNT_BOOT" "$TEMP_NODE/boot" "$TEMP_NODE/root"

# Mount source image
log "Mounting source image..."
LOOP_DEV=$(losetup --show -fP "$IMAGE_IMG")
sleep 3

mount "${LOOP_DEV}p1" "$MOUNT_BOOT" || error_exit "Failed to mount boot partition"
mount "${LOOP_DEV}p2" "$MOUNT_ROOT" || error_exit "Failed to mount root partition"

if [[ -d "$MOUNT_BOOT/firmware" ]]; then
    BOOT_SRC="$MOUNT_BOOT/firmware"
else
    BOOT_SRC="$MOUNT_BOOT"
fi

# Partition layout for Ubuntu 22.04 ARM64 RPi image
# p1: VFAT boot - starts at sector 8192, 256MB (524288 sectors)
# p2: ext4 root - starts after p1
BOOT_START=8192
BOOT_SECTORS=524288

log "Using hardcoded partition layout:"
log "  Boot partition: start=$BOOT_START, sectors=$BOOT_SECTORS"

# -----------------------------------------------------------------------------
# Create image for each node
# -----------------------------------------------------------------------------
for i in "${!NODES[@]}"; do
    NODE="${NODES[$i]}"
    TARGET_IP="${TARGET_IPS[$i]}"
    IMG_FILE="$WORK_DIR/${NODE}.img"
    
    log ""
    log "============================================"
    log "Creating image for $NODE ($TARGET_IP)"
    log "============================================"
    
    # Step 1: Create 15GB sparse image file
    log "Creating 15GB image file..."
    truncate -s 15G "$IMG_FILE"
    
    # Step 2: Attach loop device
    log "Setting up loop device..."
    NODE_LOOP=$(losetup --show -f "$IMG_FILE")
    sleep 1
    
    # Step 3: Create partition table with sfdisk
    log "Creating partition table..."
    # p1: VFAT boot partition (256MB)
    # p2: ext4 root (rest of disk)
    ROOT_START=$((BOOT_START + BOOT_SECTORS))
    sfdisk "$NODE_LOOP" << EOF
label: dos
unit: sectors

${NODE_LOOP}p1 : start=$BOOT_START size=$BOOT_SECTORS type=c
${NODE_LOOP}p2 : start=$ROOT_START type=83
EOF
    
    # Force kernel to re-read partition table
    log "Re-scanning partition table..."
    partprobe "$NODE_LOOP" || partx -u "$NODE_LOOP"
    sleep 2
    
    # Step 4: Format partitions
    log "Formatting boot partition (VFAT)..."
    mkfs.vfat -F 32 "${NODE_LOOP}p1" || error_exit "Failed to format boot partition"
    
    log "Formatting root partition (ext4)..."
    mkfs.ext4 -F "${NODE_LOOP}p2" || error_exit "Failed to format root partition"
    
    # Step 5: Copy boot partition data
    log "Copying boot partition data..."
    mount "${NODE_LOOP}p1" "$TEMP_NODE/boot"
    rsync -aAX "$BOOT_SRC/" "$TEMP_NODE/boot/"
    umount "$TEMP_NODE/boot"
    
    # Step 6: Copy root partition data
    log "Copying root partition data (this may take a while)..."
    mount "${NODE_LOOP}p2" "$TEMP_NODE/root"
    
    # Rsync root filesystem, excluding special directories
    rsync -aAX \
        --exclude={"/proc","/sys","/dev","/tmp","/run","/mnt","/media","/lost+found","/srv","/var/cache"} \
        "$MOUNT_ROOT/" "$TEMP_NODE/root/"
    
    # Recreate excluded directories
    mkdir -p "$TEMP_NODE/root"/{proc,sys,dev,tmp,run,mnt}
    
    umount "$TEMP_NODE/root"
    
    # Step 7: Detach loop device
    losetup -d "$NODE_LOOP"
    
    log "Created: $IMG_FILE"
    ls -lh "$IMG_FILE"
done

# -----------------------------------------------------------------------------
# Cleanup
# -----------------------------------------------------------------------------
log "Cleaning up..."
umount "$MOUNT_BOOT"
umount "$MOUNT_ROOT"
losetup -d "$LOOP_DEV"

log ""
log "Done! Created images:"
for NODE in "${NODES[@]}"; do
    ls -lh "$WORK_DIR/${NODE}.img"
done

log ""
log "Next step: Run 02-setup-iscsi-targets.sh"
