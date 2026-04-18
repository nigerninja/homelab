#!/bin/bash
# =============================================================================
# 05-customize-node-images.sh
# =============================================================================
# Customizes each node's disk image with:
#   - Unique hostname
#   - Static IP configuration via netplan
#   - SSH server configuration
#   - Ansible user with sudo access
#   - SSH authorized_keys for ansible access
#   - /etc/hosts entries for cluster
#
# Prerequisites:
#   - Run as root on knode1 (10.200.0.101)
#   - SSH public key at /root/.ssh/ansible_rsa.pub or $HOME/.ssh/ansible_rsa.pub
#   - Images configured by 04-configure-initramfs.sh
# =============================================================================

set -e

# Configuration
WORK_DIR="/srv/iscsi"
NODES=("knode2" "knode3" "knode4")
NODE_IPS=("10.200.0.102" "10.200.0.103" "10.200.0.104")
NETMASK="255.255.255.0"
GATEWAY="10.200.0.1"
DNS_SERVERS="10.200.0.1"

# Ansible user settings
ANSIBLE_USER="ansible"
ANSIBLE_SUDO="ALL=(ALL) NOPASSWD:ALL"

# Cluster settings
CLUSTER_DOMAIN="litaninja.dev"
MASTER_IP="10.200.0.101"

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

# Find SSH public key
find_ssh_key() {
    local key_paths=(
        "/root/.ssh/ansible_rsa.pub"
        "/root/.ssh/id_ed25519.pub"
        "/root/.ssh/id_rsa.pub"
        "$HOME/.ssh/ansible_rsa.pub"
        "$HOME/.ssh/id_ed25519.pub"
        "$HOME/.ssh/id_rsa.pub"
    )
    
    for key_path in "${key_paths[@]}"; do
        # Use test -f directly (more reliable in sudo context)
        if test -f "$key_path"; then
            echo "$key_path"
            return 0
        fi
    done
    
    return 1
}

cleanup_mount() {
    log "Cleaning up mount..."
    # Detach loop devices first
    losetup -D 2>/dev/null || true
    sleep 1
    # Then unmount
    for NODE in "${NODES[@]}"; do
        MOUNT_POINT="/mnt/${NODE}_custom"
        umount -l "$MOUNT_POINT" 2>/dev/null || true
        rmdir "$MOUNT_POINT" 2>/dev/null || true
    done
    # Final cleanup
    losetup -D 2>/dev/null || true
}

trap cleanup_mount EXIT

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------
log "Starting node customization"

# Check if running as root
if [[ $EUID -ne 0 ]]; then
    error_exit "This script must be run as root"
fi

# Install required packages
log "Installing required packages..."
apt-get update
apt-get install -y parted kpartx || error_exit "Failed to install packages"

# Find SSH public key
SSH_KEY_PATH=$(find_ssh_key) || SSH_KEY_PATH=""
if [[ -z "$SSH_KEY_PATH" ]]; then
    log "WARNING: No SSH public key found. Generating new key pair..."
    ssh-keygen -t ed25519 -f /root/.ssh/ansible_rsa -N "" -C "ansible@knode1" 2>&1
    SSH_KEY_PATH="/root/.ssh/ansible_rsa.pub"
    
    # Verify key was created
    if test -f "$SSH_KEY_PATH"; then
        log "Generated key pair at /root/.ssh/ansible_rsa"
        log "IMPORTANT: Copy /root/.ssh/ansible_rsa to your devcontainer for Ansible access"
    else
        error_exit "Failed to generate SSH key"
    fi
fi

SSH_KEY=$(cat "$SSH_KEY_PATH")
log "Using SSH key: $SSH_KEY_PATH"

# Process each node
for i in "${!NODES[@]}"; do
    NODE="${NODES[$i]}"
    NODE_IP="${NODE_IPS[$i]}"
    IMG_FILE="$WORK_DIR/${NODE}.img"
    
    log ""
    log "============================================"
    log "Customizing $NODE ($NODE_IP)"
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
    MOUNT_POINT="/mnt/${NODE}_custom"
    mkdir -p "$MOUNT_POINT"
    
    # Mount partition
    mount "$PART" "$MOUNT_POINT" || error_exit "Failed to mount ${NODE}.img"
    
    # Mount pseudo-filesystems for chroot
    log "Mounting pseudo-filesystems for chroot..."
    mount --bind /dev "$MOUNT_POINT/dev"
    mount --bind /proc "$MOUNT_POINT/proc"
    mount --bind /sys "$MOUNT_POINT/sys"
    mount --bind /run "$MOUNT_POINT/run"
    mount --bind /tmp "$MOUNT_POINT/tmp"
    
    # Create resolv.conf (avoid copying symlinks)
    log "Creating resolv.conf..."
    if test -L "$MOUNT_POINT/etc/resolv.conf"; then
        rm -f "$MOUNT_POINT/etc/resolv.conf"
    fi
    cat > "$MOUNT_POINT/etc/resolv.conf" << 'RESOLV'
nameserver 10.200.0.1
RESOLV
    
    # -------------------------------------------------------------------------
    # Set hostname
    # -------------------------------------------------------------------------
    log "  Setting hostname to $NODE..."
    echo "$NODE" > "$MOUNT_POINT/etc/hostname"
    
    # -------------------------------------------------------------------------
    # Configure /etc/hosts
    # -------------------------------------------------------------------------
    log "  Configuring /etc/hosts..."
    cat > "$MOUNT_POINT/etc/hosts" << EOF
127.0.0.1   localhost
127.0.1.1   ${NODE}.${CLUSTER_DOMAIN} ${NODE}

# Cluster nodes
${MASTER_IP}   knode1.${CLUSTER_DOMAIN} knode1
10.200.0.102  knode2.${CLUSTER_DOMAIN} knode2
10.200.0.103  knode3.${CLUSTER_DOMAIN} knode3
10.200.0.104  knode4.${CLUSTER_DOMAIN} knode4

# IPv6
::1     ip6-localhost ip6-loopback
fe00::0 ip6-localnet
ff00::0 ip6-mcastprefix
ff02::1 ip6-allnodes
ff02::2 ip6-allrouters
EOF
     
    # -------------------------------------------------------------------------
    # Configure static IP via systemd-networkd
    # -------------------------------------------------------------------------
    log "  Configuring systemd-networkd..."

    mkdir -p "$MOUNT_POINT/etc/systemd/network"

    cat > "$MOUNT_POINT/etc/systemd/network/10-eth0.network" << EOF
[Match]
Name=eth0

[Network]
Address=${NODE_IP}/24
Gateway=${GATEWAY}
DNS=${DNS_SERVERS}

[DHCP]
UseDNS=no
EOF

    chmod 644 "$MOUNT_POINT/etc/systemd/network/10-eth0.network"

    chroot "$MOUNT_POINT" systemctl enable systemd-networkd

    # -------------------------------------------------------------------------
    # Remove cloud-init package (files remain, network config disabled)
    # -------------------------------------------------------------------------
    log "  Removing cloud-init package..."
    chroot "$MOUNT_POINT" apt-get remove -y cloud-init || true
    chroot "$MOUNT_POINT" apt-get autoremove -y || true

    # Mask systemd-resolved to avoid DNS conflicts
    chroot "$MOUNT_POINT" systemctl mask systemd-resolved
    
    # -------------------------------------------------------------------------
    # Create ansible user
    # -------------------------------------------------------------------------
    log "  Creating ansible user..."
    chroot "$MOUNT_POINT" useradd -m -s /bin/bash -G sudo "$ANSIBLE_USER" 2>/dev/null || true
    
    # Set password (will be disabled for key-only auth)
    echo "${ANSIBLE_USER}:changeme" | chroot "$MOUNT_POINT" chpasswd
    
    # Configure sudo for ansible user
    echo "${ANSIBLE_USER} ${ANSIBLE_SUDO}" > "$MOUNT_POINT/etc/sudoers.d/ansible"
    chmod 440 "$MOUNT_POINT/etc/sudoers.d/ansible"
    
    # -------------------------------------------------------------------------
    # Configure SSH for ansible user
    # -------------------------------------------------------------------------
    log "  Configuring SSH access for ansible user..."
    chroot "$MOUNT_POINT" mkdir -p "/home/${ANSIBLE_USER}/.ssh"
    chroot "$MOUNT_POINT" chmod 700 "/home/${ANSIBLE_USER}/.ssh"
    echo "$SSH_KEY" > "$MOUNT_POINT/home/${ANSIBLE_USER}/.ssh/authorized_keys"
    chroot "$MOUNT_POINT" chmod 600 "/home/${ANSIBLE_USER}/.ssh/authorized_keys"
    chroot "$MOUNT_POINT" chown -R "${ANSIBLE_USER}:${ANSIBLE_USER}" "/home/${ANSIBLE_USER}/.ssh"

    # Generate SSH host keys
    log "  Generating SSH host keys..."
    chroot "$MOUNT_POINT" ssh-keygen -A

    # Configure SSH server
    log "  Configuring SSH server..."
    cat > "$MOUNT_POINT/etc/ssh/sshd_config.d/ansible.conf" << EOF
# SSH server configuration for ansible access
PermitRootLogin yes
PubkeyAuthentication yes
PasswordAuthentication no
ChallengeResponseAuthentication no
UsePAM yes
X11Forwarding no
AllowAgentForwarding yes
AllowTcpForwarding yes
EOF
    chmod 644 "$MOUNT_POINT/etc/ssh/sshd_config.d/ansible.conf"
    
    # Enable SSH service to start on boot
    chroot "$MOUNT_POINT" systemctl enable ssh
    
    # -------------------------------------------------------------------------
    # Configure fstab with UUID
    # -------------------------------------------------------------------------
    log "  Configuring /etc/fstab..."
    ROOT_UUID=$(blkid -s UUID -o value "${PART}")
    cat > "$MOUNT_POINT/etc/fstab" << EOF
UUID=${ROOT_UUID} / ext4 defaults,errors=remount-ro 0 1
EOF
    
    # -------------------------------------------------------------------------
    # Install basic packages needed for K3s
    # -------------------------------------------------------------------------
    log "  Installing basic packages..."
    
    # Create apt cache directories (needed for chroot apt-get)
    mkdir -p "$MOUNT_POINT/var/cache/apt/archives/partial"
    mkdir -p "$MOUNT_POINT/var/lib/apt/lists/partial"
    chmod 755 "$MOUNT_POINT/var/cache/apt"
    chmod 755 "$MOUNT_POINT/var/lib/apt"
    
    chroot "$MOUNT_POINT" apt-get update
    chroot "$MOUNT_POINT" apt-get install -y \
        curl \
        net-tools \
        wget \
        vim \
        git \
        ca-certificates \
        gnupg \
        lsb-release
    
    # -------------------------------------------------------------------------
    # Cleanup
    # -------------------------------------------------------------------------
    log "  Cleaning up..."
    umount "$MOUNT_POINT/tmp" 2>/dev/null || true
    umount "$MOUNT_POINT/run" 2>/dev/null || true
    umount "$MOUNT_POINT/sys" 2>/dev/null || true
    umount "$MOUNT_POINT/proc" 2>/dev/null || true
    umount "$MOUNT_POINT/dev" 2>/dev/null || true
    umount "$MOUNT_POINT" 2>/dev/null || true
    losetup -d "$LOOP_DEV" 2>/dev/null || true
    rmdir "$MOUNT_POINT" 2>/dev/null || true
    
    log "  Configured $NODE successfully!"
done

log ""
log "Node customization complete!"
log ""
log "Summary:"
log "  - Ansible user: $ANSIBLE_USER"
log "  - SSH key: $SSH_KEY_PATH"
log "  - Domain: $CLUSTER_DOMAIN"
log ""
log "IMPORTANT: Copy /root/.ssh/ansible_rsa to your devcontainer!"
log ""
log "Next steps:"
log "  1. Boot knode2, knode3, knode4 via iSCSI"
log "  2. Verify SSH access: ssh -i /root/.ssh/ansible_rsa ansible@10.200.0.102"
log "  3. Proceed with Ansible setup"
