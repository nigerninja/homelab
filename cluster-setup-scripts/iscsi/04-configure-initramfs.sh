#!/bin/bash
# =============================================================================
# 04-configure-initramfs.sh
# =============================================================================
# Configures iSCSI network boot for each node's disk image using initramfs-tools.
#
# IMPORTANT: This script PURGES dracut before rebuilding initramfs because:
#   - Ubuntu 22.04's dracut has broken iSCSI support (Bug #2081172)
#   - dracut initramfs causes "FATAL: iscsiroot requested but kernel/initrd
#     does not support iscsi" errors
#   - We use initramfs-tools + iscsid + iscsiadm instead
#
# Boot sequence:
#   1. Kernel loads initramfs (built with initramfs-tools)
#   2. init-bottom/iscsi-root script:
#      - Loads iSCSI kernel modules
#      - Starts iscsid daemon
#      - Uses iscsiadm to discover and login to target
#      - Waits for /dev/sda to appear
#   3. Switches root to iSCSI device
#
# Prerequisites:
#   - Run as root on knode1 (10.200.0.101)
#   - Images created in /srv/iscsi/ by 01-extract-ubuntu-images.sh
# =============================================================================

set -e

# Configuration
WORK_DIR="/srv/iscsi"
NODES=("knode2" "knode3" "knode4")

# iSCSI settings
ISCSI_TARGET_IP="10.200.0.101"
ISCSI_USER="iscsi-user"
ISCSI_PASS="iscsi-pass"

# Kernel version on knode1 (auto-detected)
KERNEL_VERSION=$(uname -r)

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

cleanup_mount() {
    log "Cleaning up mount..."
    losetup -D 2>/dev/null || true
    sleep 1
    for NODE in "${NODES[@]}"; do
        MOUNT_POINT="/mnt/${NODE}_iscsi"
        umount -l "$MOUNT_POINT" 2>/dev/null || true
        rmdir "$MOUNT_POINT" 2>/dev/null || true
    done
    losetup -D 2>/dev/null || true
}

trap cleanup_mount EXIT

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------
log "Starting initramfs configuration for iSCSI network boot"
log "Using: initramfs-tools + iscsid + iscsiadm"
log ""

# Check if running as root
if [[ $EUID -ne 0 ]]; then
    error_exit "This script must be run as root"
fi

# Install required packages on knode1
log "Installing required packages on knode1..."
apt-get update
apt-get install -y parted kpartx open-iscsi || error_exit "Failed to install packages"

# Verify kernel modules exist on knode1 (DIAGNOSTIC ONLY - we use image modules, not knode1's)
log "Verifying iSCSI kernel modules on knode1 (diagnostic check)..."
MOD_DIR="/lib/modules/$KERNEL_VERSION"

if [[ ! -d "$MOD_DIR" ]]; then
    log "  NOTE: knode1 kernel modules not found at $MOD_DIR (this is OK - we use image modules)"
else
    # Check for required modules (diagnostic)
    REQUIRED_MODULES=(
        "kernel/drivers/scsi/iscsi_tcp.ko"
        "kernel/drivers/scsi/libiscsi.ko"
        "kernel/crypto/crc32c.ko"
    )
    for mod in "${REQUIRED_MODULES[@]}"; do
        if [[ ! -f "$MOD_DIR/$mod" ]] && [[ ! -f "${MOD_DIR}/${mod}.xz" ]] && [[ ! -f "${MOD_DIR}/${mod}.gz" ]]; then
            log "  INFO: knode1 missing $mod (OK - will use image modules)"
        else
            log "  OK: knode1 has $mod (for reference)"
        fi
    done
fi

# Verify images exist
log "Verifying disk images..."
for NODE in "${NODES[@]}"; do
    IMG_FILE="$WORK_DIR/${NODE}.img"
    if [[ ! -f "$IMG_FILE" ]]; then
        error_exit "Image not found: $IMG_FILE. Run 01-extract-ubuntu-images.sh first."
    fi
done

# Process each node image
for i in "${!NODES[@]}"; do
    NODE="${NODES[$i]}"
    IMG_FILE="$WORK_DIR/${NODE}.img"
    TARGET_IQN="iqn.2025-05.litaninja.dev:${NODE}"
    INITIATOR_IQN="iqn.2025-05.litaninja.dev:initiator-${NODE}"
    
    log ""
    log "============================================"
    log "Configuring $NODE"
    log "============================================"
    
    # Setup loop device with partition scanning
    log "Setting up loop device..."
    LOOP_DEV=$(losetup --show -fP "$IMG_FILE")
    
    # Force kernel to re-read partition table
    log "Re-scanning partition table..."
    partprobe "$LOOP_DEV" || partx -u "$LOOP_DEV"
    sleep 2
    
    # Note: p1 = VFAT boot, p2 = ext4 root
    PART="${LOOP_DEV}p2"
    
    # Create mount point
    MOUNT_POINT="/mnt/${NODE}_iscsi"
    mkdir -p "$MOUNT_POINT"
    
    # Mount partition
    log "Mounting $NODE image..."
    mount "$PART" "$MOUNT_POINT" || error_exit "Failed to mount ${NODE}.img"
    
    # Mount pseudo-filesystems for chroot
    log "Mounting pseudo-filesystems for chroot..."
    mount --bind /dev "$MOUNT_POINT/dev"
    mount --bind /proc "$MOUNT_POINT/proc"
    mount --bind /sys "$MOUNT_POINT/sys"
    mount --bind /run "$MOUNT_POINT/run"
    mount --bind /tmp "$MOUNT_POINT/tmp"
    
    # Create resolv.conf
    log "Creating resolv.conf..."
    if test -L "$MOUNT_POINT/etc/resolv.conf"; then
        rm -f "$MOUNT_POINT/etc/resolv.conf"
    fi
    cat > "$MOUNT_POINT/etc/resolv.conf" << 'RESOLV'
nameserver 8.8.8.8
nameserver 8.8.4.4
RESOLV
    
    # Create apt cache directories
    log "Creating apt cache directories..."
    mkdir -p "$MOUNT_POINT/var/cache/apt/archives/partial"
    mkdir -p "$MOUNT_POINT/var/lib/apt/lists/partial"
    chmod 755 "$MOUNT_POINT/var/cache/apt"
    chmod 755 "$MOUNT_POINT/var/lib/apt"
    
    # Get kernel version from the image
    IMG_KERNEL_VERSION=$(chroot "$MOUNT_POINT" uname -r)
    log "  Image kernel version: $IMG_KERNEL_VERSION"
    
    # -------------------------------------------------------------------------
    # CRITICAL: Purge dracut to ensure initramfs-tools is used
    # -------------------------------------------------------------------------
    log "Purging dracut to ensure initramfs-tools is used..."
    chroot "$MOUNT_POINT" apt-get purge -y dracut dracut-network 2>/dev/null || true
    chroot "$MOUNT_POINT" apt-get autoremove -y 2>/dev/null || true
    
    # Remove any dracut-generated initramfs
    log "  Removing old dracut initramfs if exists..."
    rm -f "$MOUNT_POINT/boot/initrd.img-$IMG_KERNEL_VERSION" 2>/dev/null || true
    rm -f "$MOUNT_POINT/var/lib/dracut" 2>/dev/null || true
    rm -rf "$MOUNT_POINT/etc/dracut.conf.d" 2>/dev/null || true
    
    # Install open-iscsi and initramfs-tools
    log "Installing open-iscsi and initramfs-tools..."
    chroot "$MOUNT_POINT" apt-get update
    chroot "$MOUNT_POINT" apt-get install -y open-iscsi initramfs-tools
    
    # IMPORTANT: Remove open-iscsi's initramfs scripts that call iscsistart
    # The open-iscsi package installs scripts/local-top/iscsi which calls iscsistart
    # iscsistart fails with "NETLINK_ISCSI socket not supported" on RPi kernel
    # We keep iscsid and iscsiadm binaries but remove the problematic scripts
    log "Removing open-iscsi initramfs scripts that call iscsistart..."
    rm -f "$MOUNT_POINT/etc/initramfs-tools/scripts/local-top/iscsi" 2>/dev/null || true
    rm -f "$MOUNT_POINT/etc/initramfs-tools/scripts/local-bottom/iscsi" 2>/dev/null || true
    rm -f "$MOUNT_POINT/usr/share/initramfs-tools/hooks/iscsi" 2>/dev/null || true
    rm -f "$MOUNT_POINT/usr/share/initramfs-tools/scripts/local-top/iscsi" 2>/dev/null || true
    rm -f "$MOUNT_POINT/usr/share/initramfs-tools/scripts/local-bottom/iscsi" 2>/dev/null || true
    
    # Verify open-iscsi scripts are removed
    if [[ -f "$MOUNT_POINT/etc/initramfs-tools/scripts/local-top/iscsi" ]]; then
        log "  WARNING: local-top/iscsi still exists"
    else
        log "  OK: Removed local-top/iscsi"
    fi
    
    # Verify initramfs-tools is properly configured
    log "  Verifying initramfs-tools configuration..."
    if [ -f "$MOUNT_POINT/usr/sbin/update-initramfs" ]; then
        log "  initramfs-tools is installed"
    else
        error_exit "initramfs-tools not found!"
    fi
    
    # Ensure update-initramfs uses initramfs-tools, not dracut
    log "  Ensuring initramfs-tools is the default..."
    chroot "$MOUNT_POINT" update-alternatives --set initramfs-generator /usr/sbin/update-initramfs 2>/dev/null || true
    
    # -------------------------------------------------------------------------
    # Create init-premount script for iSCSI connection (runs BEFORE root mount)
    # -------------------------------------------------------------------------
    log "Creating init-premount iSCSI script..."
    mkdir -p "$MOUNT_POINT/etc/initramfs-tools/scripts/init-premount"
    
    cat > "$MOUNT_POINT/etc/initramfs-tools/scripts/init-premount/iscsi" << 'ISCSISCRIPT'
#!/bin/sh
# iSCSI connection script for initramfs
# Runs BEFORE root mount attempt (init-premount phase)
# Uses iscsid + iscsiadm (not iscsistart)
# Includes verbose logging and retry logic

PREREQ="udev"
prereqs() {
    echo "$prereqs"
}

case "$1" in
prereqs)
    prereqs
    exit 0
    ;;
esac

. /scripts/functions

log_begin_msg "iSCSI: Starting network boot..."

# Debug: Check what binaries exist
echo "iSCSI: ======================================="
echo "iSCSI: Debug: Checking binaries..."
echo "iSCSI: /sbin/iscsid: $(ls -la /sbin/iscsid 2>&1 | head -1)"
echo "iSCSI: /sbin/iscsiadm: $(ls -la /sbin/iscsiadm 2>&1 | head -1)"
echo "iSCSI: /bin/ip: $(ls -la /bin/ip 2>&1 | head -1)"
echo "iSCSI: /usr/bin/pgrep: $(ls -la /usr/bin/pgrep 2>&1 | head -1)"
echo "iSCSI: ======================================="

# Parse kernel cmdline for iSCSI parameters and network config
ISCSI_TARGET_IP=""
ISCSI_TARGET_NAME=""
ISCSI_INITIATOR_USER=""
ISCSI_INITIATOR_PASS=""
STATIC_IP=""  # Format: ip=<client-ip>:::<netmask>:<hostname>:<device>:<autoconf>

for param in $(cat /proc/cmdline); do
    case "$param" in
        iscsi_target_ip=*)
            ISCSI_TARGET_IP="${param#iscsi_target_ip=}"
            ;;
        iscsi_target_name=*)
            ISCSI_TARGET_NAME="${param#iscsi_target_name=}"
            ;;
        iscsi_initiator_username=*)
            ISCSI_INITIATOR_USER="${param#iscsi_initiator_username=}"
            ;;
        iscsi_initiator_password=*)
            ISCSI_INITIATOR_PASS="${param#iscsi_initiator_password=}"
            ;;
        ip=*)
            STATIC_IP="${param#ip=}"
            ;;
    esac
done

# Skip if no iSCSI parameters
if [ -z "$ISCSI_TARGET_IP" ] || [ -z "$ISCSI_TARGET_NAME" ]; then
    log_end_msg "iSCSI: No iSCSI parameters found, skipping"
    exit 0
fi

echo "iSCSI: ======================================="
echo "iSCSI: Target: $ISCSI_TARGET_NAME at $ISCSI_TARGET_IP"
echo "iSCSI: ======================================="

# Configure network - either static IP or wait for DHCP
NETWORK_IFACE="eth0"
IP_READY=0

if [ -n "$STATIC_IP" ]; then
    # Parse static IP parameter: ip=<client-ip>:::<netmask>:<hostname>:<device>:<autoconf>
    echo "iSCSI: Configuring static IP: $STATIC_IP"
    
    # Extract components from ip= parameter
    # Format: <client-ip>:::<netmask>:<hostname>:<device>:<autoconf>
    IP_ADDR=$(echo "$STATIC_IP" | cut -d: -f1)
    NETMASK=$(echo "$STATIC_IP" | cut -d: -f4)
    HOSTNAME=$(echo "$STATIC_IP" | cut -d: -f5)
    DEVICE=$(echo "$STATIC_IP" | cut -d: -f6)
    
    echo "iSCSI:   IP Address: $IP_ADDR"
    echo "iSCSI:   Netmask: $NETMASK"
    echo "iSCSI:   Hostname: $HOSTNAME"
    echo "iSCSI:   Device: $DEVICE"
    
    if [ -z "$DEVICE" ]; then
        DEVICE="eth0"
    fi
    
    NETWORK_IFACE="$DEVICE"
    
    # Wait for interface to be present
    echo "iSCSI: Waiting for interface $DEVICE..."
    for i in $(seq 1 10); do
        if ip link show "$DEVICE" 2>/dev/null | grep -q "$DEVICE"; then
            echo "iSCSI:   Interface $DEVICE found"
            break
        fi
        echo "iSCSI:   Waiting for $DEVICE... ($i/10)"
        sleep 1
    done
    
    # Bring up interface and configure IP
    echo "iSCSI: Bringing up $DEVICE and configuring IP..."
    ip link set "$DEVICE" up
    sleep 1
    
    # Calculate CIDR prefix from netmask
    case "$NETMASK" in
        255.255.255.0) PREFIX="24" ;;
        255.255.0.0) PREFIX="16" ;;
        255.0.0.0) PREFIX="8" ;;
        *) PREFIX="24" ;;
    esac
    
    # Add IP address to interface
    ip addr add "${IP_ADDR}/${PREFIX}" dev "$DEVICE" 2>/dev/null || true
    
    # Set hostname if specified
    if [ -n "$HOSTNAME" ]; then
        hostname "$HOSTNAME"
        echo "iSCSI:   Hostname set to: $HOSTNAME"
    fi
    
    # Verify IP is configured
    sleep 1
    CONFIGURED_IP=$(ip addr show "$DEVICE" 2>/dev/null | grep "inet " | awk '{print $2}')
    if [ -n "$CONFIGURED_IP" ]; then
        echo "iSCSI: Static IP configured successfully: $CONFIGURED_IP on $DEVICE"
        IP_READY=1
    else
        echo "iSCSI: ERROR - Failed to configure static IP"
    fi
else
    # No static IP configured - this shouldn't happen with our setup
    # But keep DHCP fallback for debugging
    echo "iSCSI: WARNING: No static IP configured, attempting DHCP..."
    echo "iSCSI: (This should not happen - check cmdline.txt)"
    
    # Try to get DHCP lease
    for i in $(seq 1 30); do
        if ip addr show eth0 2>/dev/null | grep -q "inet "; then
            IP_ADDR=$(ip addr show eth0 | grep "inet " | awk '{print $2}')
            echo "iSCSI: Got IP via DHCP: $IP_ADDR"
            IP_READY=1
            break
        fi
        if [ $((i % 5)) -eq 0 ]; then
            echo "iSCSI: Waiting for DHCP... ($i/30)"
        fi
        sleep 1
    done
fi

# Show detailed network status
echo "iSCSI: Network status:"
echo "iSCSI: ======================================="
if [ -n "$NETWORK_IFACE" ]; then
    ip addr show "$NETWORK_IFACE" | while read line; do
        echo "iSCSI:   $line"
    done
fi
echo "iSCSI: Routes:"
ip route | while read line; do
    echo "iSCSI:   $line"
done
echo "iSCSI: ======================================="

# Module loading with verbose debugging
echo "iSCSI: Loading kernel modules..."
echo "iSCSI: ======================================="
echo "iSCSI: Module path debug:"
echo "iSCSI:   /lib/modules: $(ls -la /lib/modules 2>&1 | head -2 | tr '\n' ' ')"
echo "iSCSI:   /usr/lib/modules: $(ls -la /usr/lib/modules 2>&1 | head -2 | tr '\n' ' ')"
echo "iSCSI:   Running kernel: $(uname -r)"
echo "iSCSI: ======================================="

# Check which module paths exist (use running kernel version)
BOOT_KERNEL=$(uname -r)
echo "iSCSI: Module directory check:"
for modpath in /lib/modules/$BOOT_KERNEL /usr/lib/modules/$BOOT_KERNEL; do
    if [ -d "$modpath" ]; then
        echo "iSCSI:   EXISTS: $modpath"
        echo "iSCSI:       Contents: $(ls -la "$modpath" 2>&1 | head -3 | tr '\n' ' ')"
        if [ -d "$modpath/kernel/drivers/scsi" ]; then
            echo "iSCSI:       SCSI drivers: $(ls "$modpath/kernel/drivers/scsi"/*.ko* 2>&1 | tr '\n' ' ')"
        fi
    else
        echo "iSCSI:   MISSING: $modpath"
    fi
done
echo "iSCSI: ======================================="

# Load modules using modprobe (resolves dependencies automatically)
echo "iSCSI: Attempting to load modules using modprobe..."

# Get the running kernel version dynamically
BOOT_KERNEL=$(uname -r)
echo "iSCSI:   Running kernel version: $BOOT_KERNEL"

# Set module path for modprobe
export MODULE_DIR="/lib/modules/$BOOT_KERNEL"
if [ ! -d "$MODULE_DIR" ]; then
    MODULE_DIR="/usr/lib/modules/$BOOT_KERNEL"
fi
echo "iSCSI:   Module directory: $MODULE_DIR"

# Update modules.dep cache
echo "iSCSI:   Updating module dependencies..."
depmod -a 2>&1 || echo "iSCSI:     depmod warning (continuing)"

# Load scsi_transport_iscsi first (base dependency)
echo "iSCSI:   Loading scsi_transport_iscsi..."
modprobe scsi_transport_iscsi 2>&1 && echo "iSCSI:     - scsi_transport_iscsi loaded" || echo "iSCSI:     - scsi_transport_iscsi failed (may be built-in)"

# Load libiscsi
echo "iSCSI:   Loading libiscsi..."
modprobe libiscsi 2>&1 && echo "iSCSI:     - libiscsi loaded" || echo "iSCSI:     - libiscsi failed"

# Load libiscsi_tcp
echo "iSCSI:   Loading libiscsi_tcp..."
modprobe libiscsi_tcp 2>&1 && echo "iSCSI:     - libiscsi_tcp loaded" || echo "iSCSI:     - libiscsi_tcp failed"

# Load iscsi_tcp (this loads all dependencies automatically via modules.dep)
echo "iSCSI:   Loading iscsi_tcp..."
modprobe iscsi_tcp 2>&1 && echo "iSCSI:     - iscsi_tcp loaded" || echo "iSCSI:     - iscsi_tcp failed"

# Try loading crc32c if available
echo "iSCSI:   Loading crc32c..."
modprobe crc32c 2>&1 && echo "iSCSI:     - crc32c loaded" || echo "iSCSI:     - crc32c failed (may be built-in)"

sleep 2

# Show loaded modules for debugging
echo "iSCSI: Loaded modules after loading:"
cat /proc/modules | grep -E "(iscsi|crc)" | while read line; do
    echo "iSCSI:   $line"
done
echo "iSCSI: ======================================="

# Create required directories for iscsid BEFORE starting
echo "iSCSI: Creating required directories..."
mkdir -p /var/lib/iscsi/nodes
mkdir -p /var/lib/iscsi/send_targets
mkdir -p /var/run/iscsi
mkdir -p /run/initramfs
mkdir -p /run/lock/iscsi
mkdir -p /etc/iscsi/nodes
mkdir -p /etc/iscsi/send_targets
echo "iSCSI:   - /var/lib/iscsi"
echo "iSCSI:   - /var/run/iscsi"
echo "iSCSI:   - /run/lock/iscsi"
echo "iSCSI:   - /etc/iscsi"

# Verify config files exist
echo "iSCSI: Checking configuration files..."
if [ -f /etc/iscsi/iscsid.conf ]; then
    echo "iSCSI:   - /etc/iscsi/iscsid.conf: $(ls -la /etc/iscsi/iscsid.conf | awk '{print $5}')"
else
    echo "iSCSI: WARNING: /etc/iscsi/iscsid.conf not found!"
fi
if [ -f /etc/iscsi/initiatorname.iscsi ]; then
    echo "iSCSI:   - /etc/iscsi/initiatorname.iscsi: $(ls -la /etc/iscsi/initiatorname.iscsi | awk '{print $5}')"
else
    echo "iSCSI: WARNING: /etc/iscsi/initiatorname.iscsi not found!"
fi

# Start iscsid
echo "iSCSI: Starting iscsid daemon..."
ISCSID_PID=""

# Check if iscsid exists and is executable
if [ -x /sbin/iscsid ]; then
    echo "iSCSI: iscsid binary found, starting daemon..."
    
    # Start iscsid in background and capture output
    /sbin/iscsid 2>&1 &
    ISCSID_PID=$!
    echo "iSCSI: iscsid started with PID: $ISCSID_PID"
    
    # Wait a bit for daemon to initialize
    sleep 3
    
    # Check if process is still running
    if kill -0 $ISCSID_PID 2>/dev/null; then
        echo "iSCSI: iscsid daemon is running (PID: $ISCSID_PID)"
    else
        echo "iSCSI: WARNING: iscsid process exited, checking for other instances..."
    fi
else
    echo "iSCSI: ERROR - iscsid not found or not executable!"
    echo "iSCSI: Checking /sbin contents:"
    ls -la /sbin/*iscsi* 2>/dev/null | while read line; do
        echo "iSCSI:   $line"
    done
fi

# Wait for iscsid to be ready - use /bin/sh compatible method
ISCSID_READY=0
echo "iSCSI: Checking for iscsid daemon..."
for i in $(seq 1 15); do
    # Check if iscsid process exists
    if [ -d /proc ] && [ -r /proc ]; then
        for pid in /proc/[0-9]*; do
            if [ -r "$pid/comm" ]; then
                comm=$(cat "$pid/comm" 2>/dev/null)
                if [ "$comm" = "iscsid" ]; then
                    echo "iSCSI: iscsid is running (PID: $(basename $pid))"
                    ISCSID_READY=1
                    break 2
                fi
            fi
        done
    fi
    if [ $((i % 5)) -eq 0 ]; then
        echo "iSCSI: Waiting for iscsid... ($i/15)"
        echo "iSCSI: Running processes:"
        cat /proc/[0-9]*/comm 2>/dev/null | sort -u | while read line; do
            echo "iSCSI:   - $line"
        done
    fi
    sleep 1
done

if [ $ISCSID_READY -eq 0 ]; then
    echo "iSCSI: WARNING - iscsid daemon not running after 15 seconds"
    echo "iSCSI: This may be OK if iscsid is not needed for basic operations"
fi

# Connect to target with RETRY logic
CONNECTED=0
MAX_RETRIES=3
RETRY_DELAY=5

echo "iSCSI: ======================================="
echo "iSCSI: Connecting to iSCSI target..."
echo "iSCSI: Max retries: $MAX_RETRIES, Delay between retries: ${RETRY_DELAY}s"
echo "iSCSI: ======================================="

for attempt in $(seq 1 $MAX_RETRIES); do
    echo ""
    echo "iSCSI: ---------------------------------------"
    echo "iSCSI: Connection attempt $attempt of $MAX_RETRIES..."
    echo "iSCSI: ---------------------------------------"
    
    # Discover target
    echo "iSCSI: Discovering target at ${ISCSI_TARGET_IP}:3260..."
    /sbin/iscsiadm -m discovery -t sendtargets -p "${ISCSI_TARGET_IP}:3260" 2>&1 | while read line; do
        echo "iSCSI: discovery: $line"
    done
    
    # Set CHAP credentials if provided
    if [ -n "$ISCSI_INITIATOR_USER" ] && [ -n "$ISCSI_INITIATOR_PASS" ]; then
        echo "iSCSI: Setting CHAP credentials (user: $ISCSI_INITIATOR_USER)..."
        /sbin/iscsiadm -m node -n "${ISCSI_TARGET_NAME}" -p "${ISCSI_TARGET_IP}:3260" \
            --op update -n node.session.auth.authmethod -v CHAP \
            --op update -n node.session.auth.username -v "${ISCSI_INITIATOR_USER}" \
            --op update -n node.session.auth.password -v "${ISCSI_INITIATOR_PASS}" 2>/dev/null && \
            echo "iSCSI: CHAP credentials set" || echo "iSCSI: Warning: Could not set CHAP credentials"
    fi
    
    # Login to target
    echo "iSCSI: Logging into target..."
    /sbin/iscsiadm -m node -n "${ISCSI_TARGET_NAME}" -p "${ISCSI_TARGET_IP}:3260" -l 2>&1 | while read line; do
        echo "iSCSI: login: $line"
    done
    
    # Wait for /dev/sda
    echo "iSCSI: Waiting for /dev/sda..."
    for i in $(seq 1 15); do
        if [ -b "/dev/sda" ]; then
            DEV_SIZE=$(blockdev --getsize64 /dev/sda 2>/dev/null || echo "unknown")
            DEV_SECTORS=$(blockdev --getsz /dev/sda 2>/dev/null || echo "unknown")
            echo "iSCSI: ======================================="
            echo "iSCSI: SUCCESS - /dev/sda is available!"
            echo "iSCSI: Size: $DEV_SIZE bytes ($DEV_SECTORS sectors)"
            echo "iSCSI: ======================================="
            CONNECTED=1
            break
        fi
        if [ $((i % 5)) -eq 0 ]; then
            echo "iSCSI: Still waiting for /dev/sda... ($i/15)"
            # Show current block devices for debugging
            echo "iSCSI: Current block devices:"
            ls -la /dev/sd* /dev/vd* /dev/xvd* 2>/dev/null | while read line; do
                echo "iSCSI:   $line"
            done
        fi
        sleep 1
    done
    
    if [ $CONNECTED -eq 1 ]; then
        break
    fi
    
    # Retry delay
    if [ $attempt -lt $MAX_RETRIES ]; then
        echo "iSCSI: Connection failed, retrying in ${RETRY_DELAY} seconds..."
        sleep $RETRY_DELAY
    fi
done

# Final status
echo ""
echo "iSCSI: ======================================="
echo "iSCSI: Final Status"
echo "iSCSI: ======================================="
if [ $CONNECTED -eq 1 ]; then
    echo "iSCSI: Block devices available:"
    ls -la /dev/sd* 2>/dev/null | while read line; do
        echo "iSCSI:   $line"
    done
    echo "iSCSI: ======================================="
    echo "iSCSI: Successfully connected to iSCSI target!"
    echo "iSCSI: ======================================="
    log_end_msg "iSCSI: Connected to target"
else
    echo "iSCSI: ERROR - Failed to connect after $MAX_RETRIES attempts"
    echo "iSCSI: Available block devices:"
    ls -la /dev/sd* /dev/vd* /dev/xvd* 2>/dev/null | while read line; do
        echo "iSCSI:   $line"
    done || echo "iSCSI:   (none found)"
    echo "iSCSI: iSCSI session info:"
    /sbin/iscsiadm -m session 2>&1 | while read line; do
        echo "iSCSI:   $line"
    done || echo "iSCSI:   (no sessions)"
    echo "iSCSI: ======================================="
fi
ISCSISCRIPT

chmod +x "$MOUNT_POINT/etc/initramfs-tools/scripts/init-premount/iscsi"
log "  Created init-premount/iscsi with verbose logging and retry logic"
    
    # -------------------------------------------------------------------------
    # Copy iSCSI kernel modules
    # Use image modules if available, otherwise fall back to knode1 modules
    # -------------------------------------------------------------------------
    log "Copying iSCSI kernel modules..."
    
    # Detect module location (supports both image and knode1 modules)
    log "  Detecting module location for kernel $IMG_KERNEL_VERSION..."
    if [[ -d "$MOUNT_POINT/lib/modules/$IMG_KERNEL_VERSION" ]]; then
        MOD_DIR="$MOUNT_POINT/lib/modules/$IMG_KERNEL_VERSION"
        log "    Using image modules at: $MOD_DIR"
    elif [[ -d "$MOUNT_POINT/usr/lib/modules/$IMG_KERNEL_VERSION" ]]; then
        MOD_DIR="$MOUNT_POINT/usr/lib/modules/$IMG_KERNEL_VERSION"
        log "    Using image modules at: $MOD_DIR"
    elif [[ -d "/lib/modules/$IMG_KERNEL_VERSION" ]]; then
        MOD_DIR="/lib/modules/$IMG_KERNEL_VERSION"
        log "    Image has no modules, using knode1 modules at: $MOD_DIR"
    elif [[ -d "/lib/modules/$KERNEL_VERSION" ]]; then
        MOD_DIR="/lib/modules/$KERNEL_VERSION"
        log "    Using knode1 modules at: $MOD_DIR (version: $KERNEL_VERSION)"
    else
        error_exit "Kernel modules not found. Checked: image /lib/modules, image /usr/lib/modules, knode1 /lib/modules"
    fi
    
    # Copy entire modules directory from knode1 (preserves modules.dep, modules.alias, etc.)
    log "  Copying complete modules directory from knode1..."
    log "    Source: $MOD_DIR"
    log "    Destination: $MOUNT_POINT/lib/modules/$KERNEL_VERSION"
    
    # Create destination directories
    mkdir -p "$MOUNT_POINT/lib/modules"
    mkdir -p "$MOUNT_POINT/usr/lib/modules"
    
    # Copy entire modules directory preserving all files (including metadata)
    cp -a "$MOD_DIR" "$MOUNT_POINT/lib/modules/"
    cp -a "$MOD_DIR" "$MOUNT_POINT/usr/lib/modules/"
    
    # Count files copied for verification
    MOD_COUNT=$(find "$MOUNT_POINT/lib/modules/$KERNEL_VERSION" -name "*.ko*" 2>/dev/null | wc -l)
    METADATA_COUNT=$(find "$MOUNT_POINT/lib/modules/$KERNEL_VERSION" -maxdepth 1 -type f 2>/dev/null | wc -l)
    log "    Copied $MOD_COUNT kernel modules"
    log "    Copied $METADATA_COUNT metadata files (modules.dep, modules.alias, etc.)"
    
    # Verify modules.dep was copied correctly
    if [[ -f "$MOUNT_POINT/lib/modules/$KERNEL_VERSION/modules.dep" ]]; then
        DEPSIZE=$(stat -c%s "$MOUNT_POINT/lib/modules/$KERNEL_VERSION/modules.dep" 2>/dev/null || echo "0")
        log "    modules.dep size: $DEPSIZE bytes (should be >1000 bytes)"
    else
        log "    WARNING: modules.dep not found!"
    fi
    
    # Check for ext4 module (needed for root filesystem)
    log "  Checking for ext4 module..."
    EXT4_FOUND=0
    for ext4_path in "$MOUNT_POINT/lib/modules/$KERNEL_VERSION/kernel/fs/ext4/ext4.ko"* \
                     "$MOUNT_POINT/usr/lib/modules/$KERNEL_VERSION/kernel/fs/ext4/ext4.ko"*; do
        if [[ -f "$ext4_path" ]]; then
            log "    ext4 module found: $ext4_path"
            EXT4_FOUND=1
            break
        fi
    done
    
    if [[ $EXT4_FOUND -eq 0 ]]; then
        # Check if ext4 is built into the kernel
        log "    ext4 module not found as .ko file"
        if grep -q "CONFIG_EXT4_FS=y" "$MOUNT_POINT/boot/config-$KERNEL_VERSION" 2>/dev/null; then
            log "    ext4 is built into the kernel (CONFIG_EXT4_FS=y)"
        else
            log "    WARNING: ext4 may not be available!"
            log "    The root filesystem requires ext4 support."
        fi
    fi
    
    # -------------------------------------------------------------------------
    # Configure initiator IQN
    # -------------------------------------------------------------------------
    log "Configuring initiator IQN..."
    echo "InitiatorName=$INITIATOR_IQN" > "$MOUNT_POINT/etc/iscsi/initiatorname.iscsi"
    
    # -------------------------------------------------------------------------
    # Create iSCSI initramfs flag file
    # -------------------------------------------------------------------------
    log "Creating iscsi.initramfs flag..."
    cat > "$MOUNT_POINT/etc/iscsi/iscsi.initramfs" << EOF
# iSCSI boot configuration for $NODE
# Generated by 04-configure-initramfs.sh

ISCSI_TARGET_IP=$ISCSI_TARGET_IP
ISCSI_TARGET_NAME=$TARGET_IQN
ISCSI_INITIATOR_USER=$ISCSI_USER
ISCSI_INITIATOR_PASS=$ISCSI_PASS
ISCSI_INTERFACE=eth0
EOF
    
    # -------------------------------------------------------------------------
    # Configure iscsid.conf for boot
    # -------------------------------------------------------------------------
    log "Creating iscsid.conf..."
    cat > "$MOUNT_POINT/etc/iscsi/iscsid.conf" << EOF
# /etc/iscsi/iscsid.conf
# iSCSI Initiator Configuration

node.startup = manual
node.leading_login = Yes

node.session.timeo.replacement_timeout = 120
node.conn[0].timeo.login_timeout = 15
node.conn[0].timeo.logout_timeout = 15
node.conn[0].timeo.noop_out_interval = 10
node.conn[0].timeo.noop_out_timeout = 90

node.session.auth.authmethod = CHAP
node.session.auth.username = $ISCSI_USER
node.session.auth.password = $ISCSI_PASS

discovery.sendtargets.auth.authmethod = CHAP
discovery.sendtargets.auth.username = $ISCSI_USER
discovery.sendtargets.auth.password = $ISCSI_PASS
EOF
    
    # -------------------------------------------------------------------------
    # Create initramfs hook to copy iSCSI tools
    # -------------------------------------------------------------------------
    log "Creating initramfs hook for iSCSI tools..."
    mkdir -p "$MOUNT_POINT/etc/initramfs-tools/hooks"
    cat > "$MOUNT_POINT/etc/initramfs-tools/hooks/iscsi_early" << 'HOOK'
#!/bin/sh
# iSCSI initramfs hook
# Copies iSCSI binaries and libraries to initramfs
# Uses COPY (not symlinks) to avoid "too many levels of symbolic links" errors

PREREQ=""
prereqs() {
    echo "$PREREQ"
}

case "$1" in
prereqs)
    prereqs
    exit 0
    ;;
esac

# copy_exec - COPY binary to initramfs
copy_exec() {
    local src="$1"
    local dest="${2:-$1}"
    
    if [ ! -e "$src" ]; then
        echo "WARNING: Source $src does not exist" >&2
        return 1
    fi
    
    if [ -d "${DESTDIR}/${dest}" ]; then
        dest="${dest}/$(basename "${src}")"
    fi
    
    mkdir -p "${DESTDIR}/$(dirname "${dest}")"
    
    # Use cp instead of ln to avoid symlink issues
    if [ -d "$src" ]; then
        cp -a "$src" "${DESTDIR}/${dest}"
    else
        cp -a "$src" "${DESTDIR}/${dest}"
    fi
}

# Copy all libraries needed by a binary
copy_libs() {
    local binary="$1"
    local lib
    
    if [ ! -f "$binary" ]; then
        echo "WARNING: Binary $binary not found" >&2
        return 1
    fi
    
    # Get list of required libraries using ldd
    ldd "$binary" 2>/dev/null | while read -r line; do
        # Handle different ldd output formats:
        # linux-vdso.so.1 (0x00007fff...)
        # libiscsi.so.7 => /lib/x86_64-linux-gnu/libiscsi.so.7 (0x00007f...)
        # /lib64/ld-linux-x86-64.so.2 (0x00007f...)
        
        echo "$line" | grep -E '=>' | while IFS=' =>' read -r left right; do
            # Extract library path after =>
            lib=$(echo "$right" | awk '{print $1}' | tr -d ' ')
            
            # Skip if empty or special
            if [ -z "$lib" ] || [ "$lib" = "linux-gate.so.1" ]; then
                continue
            fi
            
            # Handle absolute paths
            if [ "${lib:0:1}" = "/" ]; then
                if [ -f "$lib" ]; then
                    copy_lib "$lib"
                fi
            fi
        done
        
        # Also handle lines that start with /
        lib=$(echo "$line" | awk '{print $1}')
        if [ -n "$lib" ] && [ "${lib:0:1}" = "/" ] && [ -f "$lib" ]; then
            copy_lib "$lib"
        fi
    done
}

# Copy a single library and its dependencies
copy_lib() {
    local lib="$1"
    
    if [ ! -f "$lib" ]; then
        return
    fi
    
    # Avoid copying the same library twice
    local libname=$(basename "$lib")
    if [ -f "${DESTDIR}/lib/$libname" ] || [ -f "${DESTDIR}/lib64/$libname" ]; then
        return
    fi
    
    # Copy library
    local libdir=$(dirname "$lib")
    mkdir -p "${DESTDIR}${libdir}"
    cp -a "$lib" "${DESTDIR}${libdir}/"
    
    # Recursively copy dependencies of this library
    ldd "$lib" 2>/dev/null | while read -r line; do
        echo "$line" | grep -E '=>' | while IFS=' =>' read -r left right; do
            local deplib=$(echo "$right" | awk '{print $1}' | tr -d ' ')
            if [ -n "$deplib" ] && [ "${deplib:0:1}" = "/" ] && [ -f "$deplib" ]; then
                copy_lib "$deplib"
            fi
        done
    done
}

# Copy iSCSI binaries (use cp, not symlinks)
echo "Copying iSCSI binaries..."
copy_exec /sbin/iscsid
copy_exec /sbin/iscsiadm
copy_exec /sbin/iscsi_discovery

# Copy ALL shared libraries from open-iscsi package using dpkg
echo "Copying all open-iscsi package files..."
dpkg -L open-iscsi 2>/dev/null | while read file; do
    if [ -f "$file" ] && (echo "$file" | grep -qE '\.(so|so\.[0-9]+)$'); then
        libdir=$(dirname "$file")
        mkdir -p "${DESTDIR}${libdir}"
        cp -a "$file" "${DESTDIR}${libdir}/"
        echo "  Copied package lib: $file"
    fi
done

# Copy ALL shared libraries from libopeniscsiusr (main iSCSI user library)
echo "Copying libopeniscsiusr..."
for libdir in /lib/aarch64-linux-gnu /lib/arm-linux-gnueabihf /lib/x86_64-linux-gnu /usr/lib/aarch64-linux-gnu /usr/lib/arm-linux-gnueabihf /usr/lib/x86_64-linux-gnu; do
    for lib in "$libdir"/libopeniscsiusr*; do
        if [ -f "$lib" ]; then
            mkdir -p "${DESTDIR}${libdir}"
            cp -a "$lib" "${DESTDIR}${libdir}/"
            echo "  Copied: $lib"
            copy_libs "$lib"
        fi
    done
done

# Copy ALL shared libraries from libisns (iSNS client)
echo "Copying libisns..."
for libdir in /lib/aarch64-linux-gnu /lib/arm-linux-gnueabihf /lib/x86_64-linux-gnu /usr/lib/aarch64-linux-gnu /usr/lib/arm-linux-gnueabihf /usr/lib/x86_64-linux-gnu; do
    for lib in "$libdir"/libisns*; do
        if [ -f "$lib" ]; then
            mkdir -p "${DESTDIR}${libdir}"
            cp -a "$lib" "${DESTDIR}${libdir}/"
            echo "  Copied: $lib"
            copy_libs "$lib"
        fi
    done
done

# Copy ALL shared libraries from libsqlite3
echo "Copying libsqlite3..."
for libdir in /lib/aarch64-linux-gnu /lib/arm-linux-gnueabihf /lib/x86_64-linux-gnu /usr/lib/aarch64-linux-gnu /usr/lib/arm-linux-gnueabihf /usr/lib/x86_64-linux-gnu; do
    for lib in "$libdir"/libsqlite3*; do
        if [ -f "$lib" ]; then
            mkdir -p "${DESTDIR}${libdir}"
            cp -a "$lib" "${DESTDIR}${libdir}/"
            echo "  Copied: $lib"
            copy_libs "$lib"
        fi
    done
done

# Copy ALL shared libraries from libssl/libcrypto (OpenSSL)
echo "Copying OpenSSL libraries..."
for libdir in /lib/aarch64-linux-gnu /lib/arm-linux-gnueabihf /lib/x86_64-linux-gnu /usr/lib/aarch64-linux-gnu /usr/lib/arm-linux-gnueabihf /usr/lib/x86_64-linux-gnu; do
    for lib in "$libdir"/libssl* "$libdir"/libcrypto*; do
        if [ -f "$lib" ]; then
            mkdir -p "${DESTDIR}${libdir}"
            cp -a "$lib" "${DESTDIR}${libdir}/"
            echo "  Copied: $lib"
            copy_libs "$lib"
        fi
    done
done

# Copy transitive dependencies for all copied libraries
echo "Copying transitive library dependencies..."
for libdir in /lib/aarch64-linux-gnu /lib/arm-linux-gnueabihf /lib/x86_64-linux-gnu /usr/lib/aarch64-linux-gnu /usr/lib/arm-linux-gnueabihf /usr/lib/x86_64-linux-gnu; do
    find "${DESTDIR}${libdir}" -name '*.so' -type f 2>/dev/null | while read lib; do
        copy_libs "$lib"
    done
done

# Copy pgrep (used by init-premount script for iscsid check)
if [ -f /usr/bin/pgrep ]; then
    copy_exec /usr/bin/pgrep
    copy_libs /usr/bin/pgrep
fi

# Copy ip command and its libraries
if [ -f /bin/ip ]; then
    copy_exec /bin/ip
    copy_libs /bin/ip
fi

# Copy blockdev (used by init-premount script)
if [ -f /sbin/blockdev ]; then
    copy_exec /sbin/blockdev
    copy_libs /sbin/blockdev
fi

# Copy depmod (needed for updating module dependencies in initramfs)
if [ -f /sbin/depmod ]; then
    copy_exec /sbin/depmod
    copy_libs /sbin/depmod
    echo "  Copied: depmod"
elif [ -f /bin/depmod ]; then
    copy_exec /bin/depmod
    copy_libs /bin/depmod
    echo "  Copied: depmod (from /bin)"
fi

# Copy iSCSI configuration files (needed by iscsid)
echo "Copying iSCSI configuration files..."
if [ -f /etc/iscsi/iscsid.conf ]; then
    mkdir -p "${DESTDIR}/etc/iscsi"
    cp -a /etc/iscsi/iscsid.conf "${DESTDIR}/etc/iscsi/"
    echo "  Copied: /etc/iscsi/iscsid.conf"
fi
if [ -f /etc/iscsi/initiatorname.iscsi ]; then
    mkdir -p "${DESTDIR}/etc/iscsi"
    cp -a /etc/iscsi/initiatorname.iscsi "${DESTDIR}/etc/iscsi/"
    echo "  Copied: /etc/iscsi/initiatorname.iscsi"
fi

# Create required directories in initramfs
echo "Creating iSCSI directories..."
mkdir -p "${DESTDIR}/etc/iscsi/nodes"
mkdir -p "${DESTDIR}/etc/iscsi/send_targets"
mkdir -p "${DESTDIR}/var/lib/iscsi/nodes"
mkdir -p "${DESTDIR}/var/lib/iscsi/send_targets"
mkdir -p "${DESTDIR}/run/lock/iscsi"

# CRITICAL: Create symlink so /lib/modules points to /usr/lib/modules
# initramfs-tools places modules under /usr/lib/modules, but modprobe looks in /lib/modules
echo "Creating /lib/modules symlink to /usr/lib/modules..."
mkdir -p "${DESTDIR}/lib"
if [ -d "${DESTDIR}/usr/lib/modules" ]; then
    ln -sf ../usr/lib/modules "${DESTDIR}/lib/modules"
    echo "  Symlink created: /lib/modules -> ../usr/lib/modules"
else
    echo "  WARNING: /usr/lib/modules not found!"
fi

# Also ensure /lib points to /usr/lib (for usr-merge support)
if [ ! -e "${DESTDIR}/lib" ] || [ ! -d "${DESTDIR}/lib" ]; then
    ln -sf usr/lib "${DESTDIR}/lib"
    echo "  Symlink created: /lib -> usr/lib"
fi

# Copy crc32c module explicitly (may not exist on all systems)
echo "Copying crc32c module..."
for libdir in /lib /usr/lib /lib/aarch64-linux-gnu /usr/lib/aarch64-linux-gnu; do
    for modpath in "$libdir/modules" "$libdir/kernel/crypto"; do
        if [ -d "$modpath" ]; then
            for crcmod in "$modpath"/crc32c*.ko*; do
                if [ -f "$crcmod" ]; then
                    moddest="${DESTDIR}${modpath}"
                    mkdir -p "$moddest"
                    cp -a "$crcmod" "$moddest/"
                    echo "  Copied: $crcmod -> $moddest/"
                fi
            done
        fi
    done
done

# Add iSCSI modules to initramfs
for module in iscsi_tcp libiscsi crc32c; do
    if ! grep -q "^${module}" /etc/initramfs-tools/modules 2>/dev/null; then
        echo "$module" >> /etc/initramfs-tools/modules
    fi
done
HOOK
    chmod +x "$MOUNT_POINT/etc/initramfs-tools/hooks/iscsi_early"
    
    # -------------------------------------------------------------------------
    # Create init-bottom script for iSCSI (no-op since init-premount handles it)
    # -------------------------------------------------------------------------
    log "Creating init-bottom script for iSCSI root..."
    mkdir -p "$MOUNT_POINT/etc/initramfs-tools/scripts/init-bottom"
    cat > "$MOUNT_POINT/etc/initramfs-tools/scripts/init-bottom/iscsi-root" << 'ISCSISCRIPT'
#!/bin/sh
# iSCSI init-bottom script for initramfs
# NOTE: iSCSI connection is handled by init-premount/iscsi
# This script is kept for reference/debugging only

PREREQ="udev"
prereqs() {
    echo "$prereqs"
}

case "$1" in
prereqs)
    prereqs
    exit 0
    ;;
esac

. /scripts/functions

log_begin_msg "iSCSI: init-bottom script (connection handled by init-premount)"
log_end_msg "iSCSI: Skipping - already connected in init-premount phase"
ISCSISCRIPT
    chmod +x "$MOUNT_POINT/etc/initramfs-tools/scripts/init-bottom/iscsi-root"
    log "  Created init-bottom/iscsi-root (no-op, connection handled by init-premount)"
    
    # Add modules to initramfs modules list
    log "Adding modules to initramfs..."
    for module in iscsi_tcp libiscsi crc32c; do
        if ! grep -q "^${module}" "$MOUNT_POINT/etc/initramfs-tools/modules" 2>/dev/null; then
            echo "$module" >> "$MOUNT_POINT/etc/initramfs-tools/modules"
        fi
    done
    
    # -------------------------------------------------------------------------
    # Rebuild initramfs with initramfs-tools
    # -------------------------------------------------------------------------
    log "Rebuilding initramfs with initramfs-tools..."
    log "  Image reports kernel version: $IMG_KERNEL_VERSION"
    
    # List available kernel modules in the chroot for debugging
    log "  Available kernel modules in chroot:"
    ls "$MOUNT_POINT/lib/modules/" 2>/dev/null | head -5 | while read -r mod_dir; do
        log "    - $mod_dir"
    done
    
    # Verify scripts exist BEFORE building initramfs
    log "  Verifying init-premount/iscsi exists..."
    if [[ ! -f "$MOUNT_POINT/etc/initramfs-tools/scripts/init-premount/iscsi" ]]; then
        error_exit "init-premount/iscsi not found! Cannot build initramfs."
    fi
    log "    OK: init-premount/iscsi exists"
    log "    Verifying init-bottom/iscsi-root exists..."
    if [[ ! -f "$MOUNT_POINT/etc/initramfs-tools/scripts/init-bottom/iscsi-root" ]]; then
        error_exit "init-bottom/iscsi-root not found! Cannot build initramfs."
    fi
    log "    OK: init-bottom/iscsi-root exists"
    
    # Verify the initramfs hook exists
    log "  Verifying initramfs hook exists..."
    if [[ ! -f "$MOUNT_POINT/etc/initramfs-tools/hooks/iscsi_early" ]]; then
        error_exit "initramfs hook iscsi_early not found! Cannot build initramfs."
    fi
    if [[ ! -x "$MOUNT_POINT/etc/initramfs-tools/hooks/iscsi_early" ]]; then
        log "    WARNING: Hook not executable, making it executable..."
        chmod +x "$MOUNT_POINT/etc/initramfs-tools/hooks/iscsi_early"
    fi
    log "    OK: initramfs hook exists and is executable"
    
    # Ensure modules directory exists for the kernel version
    log "  Ensuring modules directory exists for $IMG_KERNEL_VERSION..."
    if [[ ! -d "$MOUNT_POINT/lib/modules/$IMG_KERNEL_VERSION" ]]; then
        log "    WARNING: Module directory not found, creating..."
        mkdir -p "$MOUNT_POINT/lib/modules/$IMG_KERNEL_VERSION"
        mkdir -p "$MOUNT_POINT/lib/modules/$IMG_KERNEL_VERSION/kernel/drivers/scsi"
        mkdir -p "$MOUNT_POINT/lib/modules/$IMG_KERNEL_VERSION/kernel/crypto"
    fi
    
    # Build initramfs for the EXPLICIT kernel version (not "current")
    log "  Building initramfs for kernel: $IMG_KERNEL_VERSION"
    chroot "$MOUNT_POINT" update-initramfs -u -k "$IMG_KERNEL_VERSION"
    
    # Find the initramfs for the kernel version we just built
    log "Verifying initramfs..."
    
    # Look for initramfs matching the kernel version we built for
    ACTUAL_INITRAMFS="$MOUNT_POINT/boot/initrd.img-$IMG_KERNEL_VERSION"
    
    if [[ ! -f "$ACTUAL_INITRAMFS" ]]; then
        # Fallback: find most recent initramfs if exact match not found
        log "  Exact initramfs not found, searching for alternatives..."
        ACTUAL_INITRAMFS=$(ls -t "$MOUNT_POINT/boot"/initrd.img-* 2>/dev/null | head -1)
    fi
    
    if [[ -z "$ACTUAL_INITRAMFS" ]] || [[ ! -f "$ACTUAL_INITRAMFS" ]]; then
        error_exit "No initramfs found in /boot for kernel $IMG_KERNEL_VERSION"
    fi
    
    # Extract the kernel version from the actual initramfs
    ACTUAL_KERNEL=$(basename "$ACTUAL_INITRAMFS" | sed 's/initrd.img-//')
    INITRAMFS_SIZE=$(du -h "$ACTUAL_INITRAMFS" | cut -f1)
    
    log "  Initramfs found: $ACTUAL_INITRAMFS"
    log "  Initramfs size: $INITRAMFS_SIZE"
    log "  Kernel version in initramfs: $ACTUAL_KERNEL"
    log "  Target kernel version: $IMG_KERNEL_VERSION"
    
    # Check for kernel version mismatch (if using fallback)
    if [[ "$ACTUAL_KERNEL" != "$IMG_KERNEL_VERSION" ]]; then
        log "  WARNING: Kernel version mismatch!"
        log "    Target kernel:  $IMG_KERNEL_VERSION"
        log "    Initramfs kernel: $ACTUAL_KERNEL"
        log "    This may cause boot issues."
    else
        log "  OK: Kernel versions match"
    fi
    
    # Verify the initramfs contents
    log "  Checking initramfs contents..."
    
    # Debug: List all scripts in the initramfs
    log "    Debug: Scripts in initramfs:"
    lsinitramfs "$ACTUAL_INITRAMFS" 2>/dev/null | grep "scripts/" | while read -r line; do
        log "      $line"
    done
    
    # CRITICAL: Check that dracut is NOT in the initramfs
    log "    Checking for dracut contamination..."
    if lsinitramfs "$ACTUAL_INITRAMFS" 2>/dev/null | grep -q "dracut"; then
        error_exit "CRITICAL: dracut found in initramfs! This will cause boot failures."
    else
        log "    OK: No dracut contamination detected"
    fi
    
    # CRITICAL: Check that open-iscsi local-top/iscsi is NOT in the initramfs
    # This script calls iscsistart which fails with NETLINK_ISCSI error on RPi
    log "    Checking for open-iscsi problematic scripts..."
    if lsinitramfs "$ACTUAL_INITRAMFS" 2>/dev/null | grep -q "scripts/local-top/iscsi"; then
        error_exit "CRITICAL: open-iscsi local-top/iscsi found in initramfs! This will cause boot failures."
    else
        log "    OK: No open-iscsi local-top/iscsi (iscsistart) in initramfs"
    fi
    
    # Check for our custom init-premount script (primary iSCSI connection handler)
    log "    Checking for init-premount/iscsi (primary connection handler)..."
    if lsinitramfs "$ACTUAL_INITRAMFS" 2>/dev/null | grep -q "scripts/init-premount/iscsi"; then
        log "    OK: Custom init-premount/iscsi found in initramfs"
    else
        error_exit "CRITICAL: init-premount/iscsi not found! This is the primary iSCSI connection handler."
    fi
    
    # Check for our custom init-bottom script (no-op, kept for reference)
    log "    Checking for init-bottom/iscsi-root (no-op for debugging)..."
    if lsinitramfs "$ACTUAL_INITRAMFS" 2>/dev/null | grep -q "scripts/init-bottom/iscsi-root"; then
        log "    OK: init-bottom/iscsi-root found (no-op, connection handled by init-premount)"
    else
        log "    WARNING: init-bottom/iscsi-root not found (optional)"
    fi
    
    # Check for iSCSI tools in initramfs
    log "    Checking for iSCSI tools..."
    if lsinitramfs "$ACTUAL_INITRAMFS" 2>/dev/null | grep -q iscsid; then
        log "    OK: iscsid found in initramfs"
    else
        log "    WARNING: iscsid may not be in initramfs"
    fi
    
    if lsinitramfs "$ACTUAL_INITRAMFS" 2>/dev/null | grep -q iscsiadm; then
        log "    OK: iscsiadm found in initramfs"
    else
        log "    WARNING: iscsiadm may not be in initramfs"
    fi
    
    # Check for awk (used by hook for library extraction)
    if lsinitramfs "$ACTUAL_INITRAMFS" 2>/dev/null | grep -q usr/bin/awk; then
        log "    OK: awk found in initramfs"
    else
        log "    WARNING: awk may not be in initramfs (used for library extraction)"
    fi
    
    # Verify initramfs has init binary
    if lsinitramfs "$ACTUAL_INITRAMFS" 2>/dev/null | grep -q "init"; then
        log "    OK: init binary found in initramfs"
    fi
    
    # -------------------------------------------------------------------------
    # Copy rebuilt initramfs to TFTP directory
    # -------------------------------------------------------------------------
    log "Copying rebuilt initramfs to TFTP directory..."
    
    # Determine TFTP serial for this node
    case "$NODE" in
        knode2) TFTP_SERIAL="0f529cee" ;;
        knode3) TFTP_SERIAL="f4e29afb" ;;
        knode4) TFTP_SERIAL="afa90f6a" ;;
    esac
    
    TFTP_ROOT="/srv/tftp"
    
    # Copy the actual initramfs to TFTP directory
    cp "$ACTUAL_INITRAMFS" "$TFTP_ROOT/$TFTP_SERIAL/initrd.img"
    log "  Copied initramfs to $TFTP_ROOT/$TFTP_SERIAL/initrd.img"
    log "  NOTE: Using kernel $ACTUAL_KERNEL (may differ from image kernel $IMG_KERNEL_VERSION)"
    
    # -------------------------------------------------------------------------
    # Cleanup chroot mounts
    # -------------------------------------------------------------------------
    log "Cleaning up chroot mounts..."
    umount "$MOUNT_POINT/tmp" 2>/dev/null || true
    umount "$MOUNT_POINT/run" 2>/dev/null || true
    umount "$MOUNT_POINT/sys" 2>/dev/null || true
    umount "$MOUNT_POINT/proc" 2>/dev/null || true
    umount "$MOUNT_POINT/dev" 2>/dev/null || true
    
    # Unmount image
    umount "$MOUNT_POINT" 2>/dev/null || true
    losetup -d "$LOOP_DEV" 2>/dev/null || true
    rmdir "$MOUNT_POINT" 2>/dev/null || true
    
    log "Configured $NODE successfully!"
done

log ""
log "============================================"
log "Initramfs configuration complete!"
log "============================================"
log ""
log "All nodes configured with iSCSI network boot support."
log "Using: initramfs-tools + iscsid + iscsiadm"
log ""
log "IMPORTANT: Update cmdline.txt with iSCSI parameters:"
log "  iscsi_target_ip=$ISCSI_TARGET_IP"
log "  iscsi_target_name=<target_iqn>"
log "  iscsi_initiator_username=$ISCSI_USER"
log "  iscsi_initiator_password=$ISCSI_PASS"
log ""
log "Next steps:"
log "  1. Update cmdline.txt in /srv/tftp/<serial>/ with iSCSI parameters"
log "  2. Test boot on knode4 first"
log "  3. If successful, proceed with knode2 and knode3"
