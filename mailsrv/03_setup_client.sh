#!/bin/sh

#
# Run on client to ready for client use
#

set -x

pkg -y

gen_user()
{
    id $1 > /dev/null 2>&1
    if [ "0" != "$?" ]; then
	pw user add $1 -m
	NEWPASS=$(echo $1.mail | openssl passwd -6 -stdin)
	chpass -p ${NEWPASS} $1
    fi
}

if [ -e client.pkg-cache.tar.xz ]; then
    mkdir -p /var/cache/pkg
    tar -C /var/cache/pkg -xvf client.pkg-cache.tar.xz
fi

gen_user ny_central
gen_user eurobsdcon

# install a local mail client
pkg install -y alpine ca_root_nss

if [ ! -e /usr/local/etc/ssl/cert.pem.ca ]; then
    cp /usr/local/etc/ssl/cert.pem /usr/local/etc/ssl/cert.pem.ca
    cat /home/lab/ca.crt >> /usr/local/etc/ssl/cert.pem
    cat /home/lab/ca.crt >> /etc/ssl/cert.pem
fi
install -m 0444 ca.crt /usr/share/certs/trusted/NY_Central.pem
certctl trust /home/lab/ca.crt
openssl rehash /etc/ssl/certs
certctl rehash

# install pine rc alpine configs for ny_central and eurobsdcon
tar -C /home -xvf /home/lab/pinerc.tar

tar -cvf /home/lab/client.pkg-cache.tar -C /var/cache/pkg .
rm -f /home/lab/client.pkg-cache.tar.xz
xz /home/lab/client.pkg-cache.tar
chown lab:lab /home/lab/client.pkg-cache.tar.xz

echo Setup completed.
