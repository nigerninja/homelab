# RPi Cluster iSCSI Boot Setup

This directory contains scripts to set up iSCSI boot for Raspberry Pi worker nodes in the K3s cluster.

**Approach**: Create fresh 15GB disk images with proper partition tables, then copy Ubuntu data from source image. Configure iSCSI network boot with **initramfs-tools** containing iscsid + iscsiadm for reliable boot.

**Why iscsid + iscsiadm?** This approach is recommended by the open-iscsi maintainer. It avoids the NETLINK_ISCSI kernel protocol issues that plague iscsistart. The initramfs contains:
- iscsid daemon (for iSCSI management)
- iscsiadm (for discovery and login)
- iSCSI kernel modules (iscsi_tcp, libiscsi, crc32c)
- Simplified `copy_exec` function with awk-based library extraction (for reliable hook execution)

## Overview

```
┌─────────────────────────────────────────────────────────────────┐
│                         knode1 (Master)                         │
│                    USB SSD - Ubuntu 22.04                        │
│                              │                                   │
│              ┌───────────────┼───────────────┐                   │
│              │               │               │                   │
│         TFTP (69)       iSCSI (3260)       SSH (22)             │
│              │               │               │                   │
└──────────────┼───────────────┼───────────────┼───────────────────┘
               │               │               │
               ▼               ▼               ▼
        OpenWrt DHCP    ┌───────────┐      DevContainer
        (PXE boot)      │  knode2   │◄───── Ansible
        serial=0f529cee  │  knode3   │       (GitOps)
        serial=f4e29afb  │  knode4   │
        serial=afa90f6a   └───────────┘
```

### RPi 4 Network Boot Flow

```
1. RPi EEPROM → DHCP (gets TFTP server IP)
2. EEPROM → TFTP: /<serial>/start4.elf
3. start4.elf → TFTP: /<serial>/config.txt, fixup4.dat
4. start4.elf → TFTP: /<serial>/vmlinuz, initrd.img
5. Linux kernel boots with iSCSI root parameters (including static IP)
6. initramfs init-premount/iscsi configures static IP and connects to iSCSI
7. Kernel mounts root filesystem from iSCSI
```

**Note on Static IP**: The initramfs uses static IP (not DHCP) because the initramfs environment doesn't run a DHCP client. Each node has a pre-configured static IP in cmdline.txt.

## Prerequisites

- **knode1** running Ubuntu 22.04 with SSH access
- At least 60GB free disk space on knode1
- SSH key generated at `/root/.ssh/ansible_rsa`
- OpenWrt router configured for:
  - Static DHCP reservations for knode2-4
  - PXE boot pointing to `10.200.0.101` (knode1)

## Scripts

| Script | Purpose |
|--------|---------|
| `01-extract-ubuntu-images.sh` | Clone Ubuntu image to 3x 15GB disk images with resize |
| `02-setup-iscsi-targets.sh` | Configure tgt (iSCSI target) to serve disk images |
| `03-setup-tftp-server.sh` | Install and configure TFTP for PXE boot |
| `04-configure-initramfs.sh` | Configure iSCSI initiator in initramfs for each node |
| `05-customize-node-images.sh` | Set hostname, static IP, SSH keys, ansible user |

## Quick Start

Run these scripts **in order** on knode1:

```bash
# 1. Clone Ubuntu image to disk images and resize to 15GB
sudo ./01-extract-ubuntu-images.sh

# 2. Configure iSCSI targets
sudo ./02-setup-iscsi-targets.sh

# 3. Setup TFTP server
sudo ./03-setup-tftp-server.sh

# 4. Configure initramfs for iSCSI boot
#    NOTE: This script PURGES dracut and uses initramfs-tools + iscsid
sudo ./04-configure-initramfs.sh

# 5. Customize each node (hostname, IP, SSH, ansible user)
sudo ./05-customize-node-images.sh
```

## Important: Why We Purge dracut and open-iscsi Scripts

### Issue 1: dracut

Ubuntu 22.04's dracut package has broken iSCSI support (Bug #2081172). When dracut is installed:
- Boot fails with: `dracut: FATAL: iscsiroot requested but kernel/initrd does not support iscsi`
- The dracut initramfs lacks necessary iSCSI components

**Solution**: Script 04 purges dracut and uses initramfs-tools instead.

### Issue 2: open-iscsi's iscsistart

Even after removing dracut, the open-iscsi package installs scripts that call `iscsistart`:
- `scripts/local-top/iscsi` calls `iscsistart`
- `iscsistart` requires NETLINK_ISCSI kernel protocol
- RPi kernel doesn't support NETLINK_ISCSI → boot fails with `NETLINK_ISCSI socket not supported`

**Solution**: Script 04 removes the open-iscsi initramfs scripts (`local-top/iscsi`) while keeping the `iscsid` and `iscsiadm` binaries. Our custom `init-bottom/iscsi-root` script uses iscsid + iscsiadm instead.

### Summary

| Package | Component | Status |
|---------|----------|--------|
| dracut | Entire package | Purged |
| open-iscsi | `local-top/iscsi` (calls iscsistart) | Removed |
| open-iscsi | `iscsid` and `iscsiadm` binaries | Kept |
| Custom script | `init-premount/iscsi` | Added (primary connection handler) |
| Custom script | `init-bottom/iscsi-root` | Added (no-op, for debugging) |

### Boot Sequence

The iSCSI boot uses **initramfs-tools** with a two-phase approach:

```
1. init-premount/iscsi     ← Connects to iSCSI (with retry logic, verbose logging)
2. init-premount           ← Root mount attempt (should find /dev/sda now)
3. local-block            ← Wait for root device (if needed)
4. init-bottom/iscsi-root  ← No-op (connection already done)
```

**Why init-premount?** The `init-bottom` scripts run AFTER the mount attempt, so iSCSI connection must happen in `init-premount` phase (runs BEFORE root mount).

**init-premount/iscsi features**:
- Verbose logging at each step for debugging
- Network wait with IP detection
- Kernel module loading with status
- iscsid daemon start with verification
- Retry logic: 3 attempts, 5 second delay, 15 second wait per attempt
- CHAP credential configuration
- Block device listing after connection

## Configuration

### Network

| Node | IP Address | Serial | Role |
|------|------------|--------|------|
| knode1 | 10.200.0.101 | - | Control Plane (Master) |
| knode2 | 10.200.0.102 | 0f529cee | Worker |
| knode3 | 10.200.0.103 | f4e29afb | Worker |
| knode4 | 10.200.0.104 | afa90f6a | Worker |

### Domain

- Internal domain: `litaninja.dev`
- Configure OpenWrt DNS to resolve `*.litaninja.dev` to cluster IPs

### iSCSI Settings

| Setting | Value |
|---------|-------|
| Target IQN Base | `iqn.2025-05.litaninja.dev` |
| Initiator IQN Base | `iqn.2025-05.litaninja.dev:initiator-` |
| Target Portal | `10.200.0.101:3260` |
| CHAP User | `iscsi-user` |
| CHAP Password | `iscsi-pass` |
| Image Size | 15GB |

## After Setup

### 1. Boot Worker Nodes

Power on knode2, knode3, knode4. They should:
1. PXE boot (via OpenWrt DHCP)
2. Load kernel and initramfs from TFTP
3. Connect to iSCSI target on knode1
4. Boot from iSCSI disk

### 2. Verify SSH Access

```bash
ssh -i /root/.ssh/ansible_rsa ansible@10.200.0.102
ssh -i /root/.ssh/ansible_rsa ansible@10.200.0.103
ssh -i /root/.ssh/ansible_rsa ansible@10.200.0.104
```

### 3. Transfer SSH Key

Copy the private key to your devcontainer:
```bash
# On knode1
scp /root/.ssh/ansible_rsa user@your-devcontainer:/path/to/.ssh/

# Or in your devcontainer
ssh-copy-id -i /root/.ssh/ansible_rsa ansible@10.200.0.101
```

### 4. Run Ansible

```bash
# From devcontainer
cd homelab

# Install tools
ansible-playbook pb_rpi_cluster.yml --tags tools

# Update packages
ansible-playbook pb_rpi_cluster.yml --tags servers

# Install K3s
ansible-playbook pb_rpi_cluster.yml --tags k3s

# Deploy cluster services
ansible-playbook pb_rpi_cluster.yml --tags cluster
```

## Troubleshooting

### iSCSI Connection Issues

```bash
# On knode1, check targets
tgt-admin --show

# On worker, check initiator
sudo iscsiadm -m discovery -t st -p 10.200.0.101
sudo iscsiadm -m node -L all
```

### TFTP Issues

```bash
# Test TFTP from another machine (RPi serial directory)
tftp 10.200.0.101 -c get 0f529cee/start4.elf /tmp/start4.elf

# Test kernel retrieval
tftp 10.200.0.101 -c get 0f529cee/vmlinuz /tmp/vmlinuz

# Check TFTP logs
journalctl -u tftpd-hpa -f
```

### RPi 4 Network Boot Issues

The RPi 4 bootloader looks for boot files in a directory named after its serial number.
Verify the directory structure:

```bash
# List TFTP directories
ls -la /srv/tftp/

# Verify each node directory has required files
ls -la /srv/tftp/0f529cee/  # knode2
ls -la /srv/tftp/f4e29afb/  # knode3
ls -la /srv/tftp/afa90f6a/  # knode4
```

Required files per node directory:
- `start4.elf` - RPi 4 bootloader
- `fixup4.dat` - SDRAM fixup
- `config.txt` - Boot configuration
- `cmdline.txt` - Kernel parameters (iSCSI)
- `vmlinuz` - Linux kernel
- `initrd.img` - Initial ramdisk (with iSCSI support - rebuilt by script 04)

### iSCSI Network Boot Issues

This setup uses **initramfs-tools + iscsid + iscsiadm** for iSCSI boot. The init-bottom script parses `iscsi_*` parameters from the kernel command line and uses iscsid + iscsiadm to connect.

**Key cmdline.txt parameters** (parsed by init-premount/iscsi):
```
root=/dev/sda2
ip=<node_ip>:::<netmask>:<hostname>:<device>:none
iscsi_target_ip=<target_ip>
iscsi_target_name=<target_iqn>
iscsi_initiator_username=<user>
iscsi_initiator_password=<pass>
```

**Important**: `root=/dev/sda2` specifies partition 2 (the Linux ext4 partition), not the whole disk `/dev/sda`.

**Static IP Configuration**:

The `ip=` parameter is required for iSCSI boot because:
- The initramfs environment doesn't run a DHCP client
- Each node gets a static IP assigned directly in cmdline.txt
- Format: `ip=<client-ip>:::<netmask>:<hostname>:<device>:none`

Example per node:
| Node | ip= parameter |
|------|---------------|
| knode2 | `ip=10.200.0.102:::255.255.255.0:knode2:eth0:none` |
| knode3 | `ip=10.200.0.103:::255.255.255.0:knode3:eth0:none` |
| knode4 | `ip=10.200.0.104:::255.255.255.0:knode4:eth0:none` |

These parameters are parsed from `cmdline.txt` by the `init-premount/iscsi` script, which:
1. Parses `ip=` parameter and configures static IP on the interface
2. Loads iSCSI kernel modules
3. Starts iscsid daemon
4. Performs discovery and login with 3 retries
5. Verifies block device appears

If boot fails with errors like:
- `Gave up waiting for root file system device`
- iSCSI device not appearing at `/dev/sda`

**Troubleshooting steps**:

```bash
# 1. CRITICAL: Check if dracut contaminated the initramfs
lsinitramfs /srv/tftp/afa90f6a/initrd.img | grep dracut
# If this shows "dracut", re-run script 04

# 2. CRITICAL: Check if open-iscsi local-top/iscsi is present
lsinitramfs /srv/tftp/afa90f6a/initrd.img | grep "scripts/local-top/iscsi"
# If this shows a match, re-run script 04 (it should remove this)

# 3. CRITICAL: Verify init-premount/iscsi is present (primary connection handler)
lsinitramfs /srv/tftp/afa90f6a/initrd.img | grep "scripts/init-premount/iscsi"
# If missing, re-run script 04

# 4. Verify initramfs contains iSCSI tools
lsinitramfs /srv/tftp/afa90f6a/initrd.img | grep -E "(iscsid|iscsiadm)"

# 5. Verify our custom init-bottom script exists in initramfs (no-op)
lsinitramfs /srv/tftp/afa90f6a/initrd.img | grep "scripts/init-bottom/iscsi-root"

# 6. Verify cmdline.txt has correct iSCSI parameters AND static IP
cat /srv/tftp/afa90f6a/cmdline.txt
# Should contain: ip=10.200.0.104:::255.255.255.0:knode4:eth0:none

# 7. Check iSCSI target is running on knode1
tgt-admin --show

# 8. Check TFTP server is serving the initramfs
tftp 10.200.0.101 -c get afa90f6a/initrd.img /tmp/test-initrd.img
```

**Common issues**:
- **dracut contamination**: Boot shows "dracut: FATAL: iscsiroot requested" → Re-run script 04 to purge dracut
- **open-iscsi scripts**: Boot shows "iscsistart: can not create NETLINK_ISCSI socket" → Re-run script 04 to remove open-iscsi scripts
- **init-premount missing**: Boot fails to mount root → Check init-premount/iscsi is in initramfs
- **Static IP not configured**: Boot shows "Waiting for network..." → Check cmdline.txt has `ip=` parameter, re-run script 03
- **No IP address**: Boot shows "No network interface with IP" → Verify static IP in cmdline.txt matches OpenWrt reservation
- iscsid not running: Check iscsid binary is in initramfs
- Target not found: Verify target IQN matches in cmdline.txt and tgt config
- Retry exhausted: Check network connectivity, IQN, CHAP credentials
- `*.dtb` - Device tree blobs

## Cleanup

To remove all iSCSI configuration:

```bash
# Stop services
systemctl stop tgt tftpd-hpa

# Remove configuration
rm -rf /srv/iscsi
rm -rf /srv/tftp
rm -f /etc/tgt/conf.d/rpi-cluster.conf

# Remove packages
apt purge -y tgt tftpd-hpa
```
