#!/bin/bash
# =============================================================================
# 05b-setup-knode1.sh
# =============================================================================
# Adds ansible user to knode1 (the iSCSI target/master node)
# Run on knode1 directly (not via chroot)
#
# Prerequisites:
#   - Run as root on knode1 (10.200.0.101)
#   - SSH public key at /root/.ssh/ansible_rsa.pub or similar
# =============================================================================

set -e

ANSIBLE_USER="ansible"

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Setting up ansible user on knode1..."

# Add ansible user with sudo access
useradd -m -s /bin/bash -G sudo "$ANSIBLE_USER" 2>/dev/null || true
echo "${ANSIBLE_USER}:changeme" | chpasswd
echo "${ANSIBLE_USER} ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/ansible
chmod 440 /etc/sudoers.d/ansible

# Find SSH public key
KEY_PATH=$(find /root/.ssh/ansible_rsa.pub /root/.ssh/id_ed25519.pub /root/.ssh/id_rsa.pub -type f 2>/dev/null | head -1)
if [[ -z "$KEY_PATH" ]]; then
    echo "ERROR: No SSH public key found in /root/.ssh/"
    exit 1
fi

# Add SSH authorized_keys for ansible user
SSH_KEY=$(cat "$KEY_PATH")
mkdir -p "/home/${ANSIBLE_USER}/.ssh"
chmod 700 "/home/${ANSIBLE_USER}/.ssh"
echo "$SSH_KEY" > "/home/${ANSIBLE_USER}/.ssh/authorized_keys"
chmod 600 "/home/${ANSIBLE_USER}/.ssh/authorized_keys"
chown -R "${ANSIBLE_USER}:${ANSIBLE_USER}" "/home/${ANSIBLE_USER}/.ssh"

# Generate SSH host keys (idempotent - won't overwrite existing)
ssh-keygen -A

# Configure SSH server
cat > /etc/ssh/sshd_config.d/ansible.conf << 'EOF'
PermitRootLogin yes
PubkeyAuthentication yes
PasswordAuthentication no
ChallengeResponseAuthentication no
UsePAM yes
X11Forwarding no
AllowAgentForwarding yes
AllowTcpForwarding yes
EOF
chmod 644 /etc/ssh/sshd_config.d/ansible.conf

systemctl enable ssh

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Done. Ansible user configured on knode1."
echo "Test with: ssh ansible@10.200.0.101"
