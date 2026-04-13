#!/bin/bash
# /etc/set-hostname.sh

# Get the node's IP address (first non-loopback IPv4)
MYIP=$(hostname -I | awk '{print $1}')

case "$MYIP" in
  10.200.0.102)
    MYNAME="knode2"
    ;;
  10.200.0.103)
    MYNAME="knode3"
    ;;
  10.200.0.104)
    MYNAME="knode4"
    ;;
  *)
    MYNAME="unknown"
    ;;
esac

echo "$MYNAME" > /var/local/hostname
hostnamectl set-hostname "$MYNAME"

# Optionally update /etc/hosts
sed -i "/127.0.1.1/d" /var/local/hosts
echo "127.0.1.1 $MYNAME" >> /var/local/hosts
