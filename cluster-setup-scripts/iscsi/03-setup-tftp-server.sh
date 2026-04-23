#!/bin/bash
# =============================================================================
# 03-setup-tftp-server.sh
# =============================================================================
# Installs and configures TFTP server for RPi 4 network boot.
# Creates per-node directories using RPi serial numbers and copies all
# required bootloader files, kernel, and initrd.
#
# Prerequisites:
#   - Run as root on knode1 (10.200.0.101)
#   - Ubuntu image available for extracting boot files
# =============================================================================

set -e

# Configuration
TFTP_ROOT="/srv/tftp"
WORK_DIR="/srv/iscsi"
IMAGE_MOUNT="/mnt/tftp_boot"
UBUNTU_IMG="ubuntu-22.04.3-preinstalled-server-arm64+raspi.img"

# Node configuration with serial numbers (RPi network boot uses serial-based directories)
NODE_SERIALS=("0f529cee" "f4e29afb" "afa90f6a")
NODES=("knode2" "knode3" "knode4")
# Static IPs assigned to each node (for iSCSI boot - no DHCP in initramfs)
NODE_IPS=("10.200.0.102" "10.200.0.103" "10.200.0.104")
# Target IPs (iSCSI target on knode1 - same for all nodes)
TARGET_IPS=("10.200.0.101" "10.200.0.101" "10.200.0.101")

# iSCSI credentials (match 02-setup-iscsi-targets.sh)
ISCSI_USER="iscsi-user"
ISCSI_PASS="iscsi-pass"
ISCSI_TARGET_IP="10.200.0.101"

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

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------
log "Starting TFTP server setup for RPi 4 network boot"

# Check if running as root
if [[ $EUID -ne 0 ]]; then
    error_exit "This script must be run as root"
fi

# Install TFTP server
log "Installing TFTP server..."
apt update
apt install -y tftpd-hpa syslinux-common parted kpartx

# Create TFTP directory structure
log "Creating TFTP directory structure..."
mkdir -p "$TFTP_ROOT/boot"
mkdir -p "$TFTP_ROOT/pxelinux.cfg"  # kept for reference

# Search for Ubuntu image in multiple locations
log "Searching for Ubuntu image..."
UBUNTU_IMG_PATH=""
SEARCH_DIRS="$WORK_DIR $PWD $(dirname "$0") ."

for search_dir in $SEARCH_DIRS; do
    if [[ -f "${search_dir}/${UBUNTU_IMG}" ]]; then
        UBUNTU_IMG_PATH="${search_dir}/${UBUNTU_IMG}"
        log "Found Ubuntu image at: $UBUNTU_IMG_PATH"
        break
    fi
done

if [[ -z "$UBUNTU_IMG_PATH" ]]; then
    error_exit "Ubuntu image not found. Searched in: $SEARCH_DIRS"
fi

# Mount image to extract boot files
log "Mounting Ubuntu image to extract boot files..."
mkdir -p "$IMAGE_MOUNT"
LOOP_DEV=""

if mountpoint -q "$IMAGE_MOUNT" 2>/dev/null; then
    log "Using already mounted image at $IMAGE_MOUNT"
else
    LOOP_DEV=$(losetup --show -fP "$UBUNTU_IMG_PATH")
    sleep 2
    
    # Force kernel to re-read partition table
    partprobe "$LOOP_DEV" || partx -u "$LOOP_DEV"
    sleep 2
    
    # Mount boot partition (p1 = VFAT boot)
    if [[ -b "${LOOP_DEV}p1" ]]; then
        mount "${LOOP_DEV}p1" "$IMAGE_MOUNT" || error_exit "Failed to mount boot partition"
    else
        error_exit "Boot partition not found on $LOOP_DEV"
    fi
fi

# Find firmware source
if [[ -d "$IMAGE_MOUNT/firmware" ]]; then
    FIRMWARE_SRC="$IMAGE_MOUNT/firmware"
elif [[ -d "$IMAGE_MOUNT" ]]; then
    FIRMWARE_SRC="$IMAGE_MOUNT"
else
    error_exit "Could not find boot files"
fi

log "Firmware source: $FIRMWARE_SRC"

# Copy kernel and initramfs to boot directory
# IMPORTANT: Use kernel from knode1 to ensure it matches the modules
# The Ubuntu image kernel may differ from knode1's kernel version
log "Copying kernel and initramfs to boot directory..."
KERNEL_VERSION=$(uname -r)
log "  Using knode1 kernel: $KERNEL_VERSION"

if [[ -f "/boot/vmlinuz-$KERNEL_VERSION" ]]; then
    cp "/boot/vmlinuz-$KERNEL_VERSION" "$TFTP_ROOT/boot/vmlinuz"
    log "  Copied vmlinuz from knode1: vmlinuz-$KERNEL_VERSION"
else
    log "  WARNING: knode1 kernel not found at /boot/vmlinuz-$KERNEL_VERSION"
    if [[ -f "$FIRMWARE_SRC/vmlinuz" ]]; then
        cp "$FIRMWARE_SRC/vmlinuz" "$TFTP_ROOT/boot/vmlinuz"
        log "  Falling back to image vmlinuz"
    fi
fi

if [[ -f "$FIRMWARE_SRC/initrd.img" ]]; then
    cp "$FIRMWARE_SRC/initrd.img" "$TFTP_ROOT/boot/"
    log "  Copied initrd.img"
fi

# Create per-node TFTP directories with RPi serial numbers
log "Creating per-node TFTP directories for RPi network boot..."

for i in "${!NODES[@]}"; do
    SERIAL="${NODE_SERIALS[$i]}"
    NODE="${NODES[$i]}"
    NODE_IP="${NODE_IPS[$i]}"
    TARGET_IP="${TARGET_IPS[$i]}"
    TARGET_IQN="iqn.2025-05.litaninja.dev:${NODE}"
    
    log ""
    log "  Configuring $NODE (serial: $SERIAL, IP: $TARGET_IP)"
    
    # Create directory for this node
    mkdir -p "$TFTP_ROOT/$SERIAL"
    
    # Copy bootloader files
    log "    Copying bootloader files..."
    
    if [[ -f "$FIRMWARE_SRC/start4.elf" ]]; then
        cp "$FIRMWARE_SRC/start4.elf" "$TFTP_ROOT/$SERIAL/"
        log "      - start4.elf"
    fi
    
    if [[ -f "$FIRMWARE_SRC/fixup4.dat" ]]; then
        cp "$FIRMWARE_SRC/fixup4.dat" "$TFTP_ROOT/$SERIAL/"
        log "      - fixup4.dat"
    fi
    
    # Copy device tree blobs
    if [[ -d "$FIRMWARE_SRC" ]]; then
        for dtb in "$FIRMWARE_SRC/"*.dtb; do
            if [[ -f "$dtb" ]]; then
                cp "$dtb" "$TFTP_ROOT/$SERIAL/"
                log "      - $(basename "$dtb")"
            fi
        done
    fi
    
    # Copy kernel
    if [[ -f "$TFTP_ROOT/boot/vmlinuz" ]]; then
        cp "$TFTP_ROOT/boot/vmlinuz" "$TFTP_ROOT/$SERIAL/"
        log "      - vmlinuz"
    fi
    
    # Copy initrd
    if [[ -f "$TFTP_ROOT/boot/initrd.img" ]]; then
        cp "$TFTP_ROOT/boot/initrd.img" "$TFTP_ROOT/$SERIAL/"
        log "      - initrd.img"
    fi
    
    # Create custom config.txt for this node
    log "    Creating config.txt for $NODE..."
    cat > "$TFTP_ROOT/$SERIAL/config.txt" << EOF
arm_64bit=1
kernel=vmlinuz
initramfs initrd.img followkernel
cmdline=cmdline.txt
max_framebuffers=2
arm_boost=1
enable_uart=1
force_turbo=1
dtparam=audio=on
dtparam=i2c_arm=on
dtparam=spi=on
dtparam=ethernet=on
disable_overscan=1
camera_auto_detect=1
display_auto_detect=1
dtoverlay=dwc2,dr_mode=host
EOF
    log "      - config.txt created"
    
    # Create cmdline.txt for network boot (iSCSI parameters)
    # Static IP format: ip=<client-ip>:::<netmask>:<hostname>:<device>:<autoconf>
    # The initramfs init-premount script parses the ip= parameter to configure static networking
    # IMPORTANT: root=/dev/sda2 (partition 2, not the whole disk sda)
    log "    Creating cmdline.txt for $NODE (static IP: $NODE_IP)..."
    cat > "$TFTP_ROOT/$SERIAL/cmdline.txt" << EOF
net.ifnames=0 dwc_otg.lpm_enable=0 console=serial0,115200 console=tty1 root=/dev/sda2 rw rootwait elevator=deadline ip=${NODE_IP}:::255.255.255.0:${NODE}:eth0:none iscsi_target_ip=${ISCSI_TARGET_IP} iscsi_target_name=${TARGET_IQN} iscsi_initiator_username=${ISCSI_USER} iscsi_initiator_password=${ISCSI_PASS}
EOF
    log "      - cmdline.txt created with static IP $NODE_IP and iSCSI parameters"
    
    log "  $NODE configured successfully"
done

# Unmount image
log "Cleaning up..."
if [[ -n "$LOOP_DEV" ]]; then
    umount "$IMAGE_MOUNT" || true
    losetup -d "$LOOP_DEV" || true
fi
rmdir "$IMAGE_MOUNT" 2>/dev/null || true

# Keep pxelinux.cfg for reference (RPi doesn't use it, but useful for documentation)
log "Keeping pxelinux.cfg directory for reference..."

# Set permissions
log "Setting permissions..."
chmod -R 755 "$TFTP_ROOT"

# Configure TFTP server
log "Configuring TFTP server..."
cat > /etc/default/tftpd-hpa << EOF
TFTP_USERNAME="tftp"
TFTP_DIRECTORY="$TFTP_ROOT"
TFTP_ADDRESS="0.0.0.0:69"
TFTP_OPTIONS="--secure --verbose"
EOF

# Restart TFTP server
log "Restarting TFTP server..."
systemctl restart tftpd-hpa
systemctl enable tftpd-hpa

# Wait for service to start
sleep 2

# Verify
log "Checking TFTP server status..."
systemctl status tftpd-hpa --no-pager || true

# Show final directory structure
log ""
log "TFTP server setup complete!"
log ""
log "Final TFTP directory structure:"
find "$TFTP_ROOT" -type f -o -type d | sort | head -50

log ""
log "Node directories:"
for SERIAL in "${NODE_SERIALS[@]}"; do
    log "  $TFTP_ROOT/$SERIAL/"
done

log ""
log "Next step: Run 04-configure-initramfs.sh"
