#!/bin/sh

#
# Script running on unbound server to get DNS going
#

set -e
set -x

if [ -e unbound.pkg-cache.tar.xz ]; then
    mkdir -p /var/cache/pkg
    tar xvf unbound.pkg-cache.tar.xz -C /var/cache/pkg
fi

pkg install -y unbound doas

cat <<EOF > /usr/local/etc/doas.conf
permit nopass lab
EOF

# then set up local zone
mkdir -p /usr/local/etc/unbound
mv unbound.conf /usr/local/etc/unbound/unbound.conf
mv nycentral.zone /usr/local/etc/unbound/ny-central.lab.zone
mv eurobsdcon.zone /usr/local/etc/unbound/eurobsdcon.lab.zone
mv 10.193.167.zone /usr/local/etc/unbound/

DNS=$(cat /etc/resolv.conf | grep nameserver | head -1 | awk '{print $2}')

sed -i '' "s@DNSSERVER@${DNS}@g" /usr/local/etc/unbound/unbound.conf

# Update resolver
echo "nameserver localhost" > /etc/resolv.conf

service unbound enable
service unbound start

tar cvf /home/lab/unbound.pkg-cache.tar -C /var/cache/pkg .
rm -f /home/lab/unbound.pkg-cache.tar.xz
xz /home/lab/unbound.pkg-cache.tar
chown lab:lab /home/lab/unbound.pkg-cache.tar.xz
