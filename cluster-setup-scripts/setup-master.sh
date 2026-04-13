#!/bin/bash
# Run as root on the master node (10.200.0.101)

# Install required packages
apt update
apt install -y nfs-kernel-server tgt tftpd-hpa btrfs-progs

# Configure TFTP
mkdir -p /srv/tftp

cat <<EOF > /etc/default/tftpd-hpa
TFTP_USERNAME="tftp"
TFTP_DIRECTORY="/srv/tftp"
TFTP_ADDRESS=":69"
TFTP_OPTIONS="--secure"
EOF

systemctl restart tftpd-hpa

# Prepare NFS root
mkdir -p /srv/nfs/rpi-root

echo "/srv/nfs/rpi-root 10.200.0.0/24(ro,sync,no_subtree_check,no_root_squash,fsid=0)" >> /etc/exports

exportfs -ra
systemctl restart nfs-kernel-server

# Create BTRFS volume for iSCSI
mkdir -p /srv/iscsi
btrfs subvolume create /srv/iscsi

# Create thin-provisioned images for nodes
for node in knode2 knode3 knode4; do
  truncate -s 15G /srv/iscsi/$node.img
  mkfs.ext4 /srv/iscsi/$node.img
done

# Configure iSCSI targets
cat <<EOF > /etc/tgt/conf.d/rpi-cluster.conf
<target iqn.2025-05.net.rpi:knode2>
    backing-store /srv/iscsi/knode2.img
    initiator-address 10.200.0.102
</target>
<target iqn.2025-05.net.rpi:knode3>
    backing-store /srv/iscsi/knode3.img
    initiator-address 10.200.0.103
</target>
<target iqn.2025-05.net.rpi:knode4>
    backing-store /srv/iscsi/knode4.img
    initiator-address 10.200.0.104
</target>
EOF

systemctl restart tgt

echo "Master node setup complete!"
