#!/bin/bash
# Run as root on master

TFTP_ROOT='/srv/tftp'
NFS_ROOT_BOOT='/srv/nfs/rpi-root/boot'

# Check if at least one serial number is provided
if [ $# -lt 1 ]; then
  echo "Usage: $0 <serial_number1> [serial_number2 ...]"
  exit 1
fi

# Create subdirectories and copy boot files for each serial
for serial in "$@"; do
  echo "Setting up TFTP directory for serial: $serial"
  mkdir -p "$TFTP_ROOT/$serial"
  cp -a "$NFS_ROOT_BOOT"/* "$TFTP_ROOT/$serial/"
done

# Create cmdline.txt for each serial
for serial in "$@"; do
  echo "creating cmdline.txt for $serial..."
  CMDLINE_PATH="$TFTP_ROOT/$serial/cmdline.txt"
  echo "console=serial0,115200 console=tty1 ip=dhcp root=/dev/nfs nfsroot=10.200.0.101:/,vers=4 ro rootwait elevator=deadline" > "$CMDLINE_PATH"
done

# Create a multi-entry iPXE script for all serials
echo "creating ipxe script..."
cat <<EOF > "$TFTP_ROOT/boot.ipxe"
#!ipxe
dhcp
EOF

for serial in "$@"; do
  echo "set initiator-iqn iqn.2025-05.net.rpi:$serial" >> "$TFTP_ROOT/boot.ipxe"
  echo "sanboot iscsi:10.200.0.101::::iqn.2025-05.net.rpi:$serial" >> "$TFTP_ROOT/boot.ipxe"
done

echo "TFTP configuration complete for all provided serial numbers."
