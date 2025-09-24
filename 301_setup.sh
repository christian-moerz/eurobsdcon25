#!/bin/sh

# Use 101 to set up a lab env first!

#
# Sets up lab environment for mail server:
# 
# * creates a dns server VM
# * creates two mail server VMs to be able to
#   talk to one another
#
# We are using the bhyve 101 and bhyve 102 scripts
# to set this up
#
# We assume we are starting from an empty lab
# environment.
#
# 101_setup_jails.sh must have already been run
# This needs to run inside base jail
#
# 102 and 103 will be set up/run by this script
# it will register its completion, so it won't
# run again later.
#

set -x
set -e

. ./utils.sh

ensure_jailed

if [ ! -e config.sh ]; then
    echo Missing config.sh.
    exit 1
fi

. ./config.sh

if [ -e lab.pkg-cache.tar.xz ]; then
    mkdir -p /var/cache/pkg
    tar -C /var/cache/pkg -xvf lab.pkg-cache.tar.xz
fi

generate_ssh

# Clean up
rm -f ny-central.lab.dns

PUBKEY=$(cat .ssh/id_ecdsa.pub)
NAMESERVER=${DNS}

if [ "${DNS}" == "" ]; then
    NAMESERVER=$(cat /etc/resolv.conf | grep nameserver | head -1 | awk '{print $2}')
    DNS=${NAMESERVER}
fi

# gen_media et al moved to utils.sh

if [ "3" != "${STAGE}" ]; then

    # setup base jail after first start
    ./102_setup_subjail.sh

    # setup switch
    ./103_setup_switch.sh

    # reload config.sh after network setup changes
    . ./config.sh

    # we prepare installation media for the three servers
    if [ ! -e /usr/src/UPDATING ]; then
	echo Missing /usr/src

	if [ -e src.txz ]; then
	    echo % src.txz ${ZPATH}/src.txz
	    cp src.txz ${ZPATH}/src.txz
	fi

	CURRENT=$(pwd)
	cd /usr/src
	if [ -e ${ZPATH}/src.txz ]; then
	    echo % tar -C / -xvf ${ZPATH}/src.txz
	    tar -C / -xvf ${ZPATH}/src.txz
	else
	    echo % git clone --branch releng/${MAJOR}.${MINOR} --depth 1 https://github.com/freebsd/freebsd-src /usr/src
	    git clone --branch releng/${MAJOR}.${MINOR} --depth 1 https://github.com/freebsd/freebsd-src /usr/src
	    echo % tar -C /usr/src -cvf ${ZPATH}/src.tar .
	    tar -C / -cvf ${ZPATH}/src.tar /usr/src
	    echo "% xz -c ${ZPATH}/src.tar > ${ZPATH}/src.txz &"
	    xz -c ${ZPATH}/src.tar > ${ZPATH}/src.txz &
	fi
	cd ${CURRENT}
    fi

    echo "STAGE=3" >> config.sh
fi

CONF_HOSTNAME="unbound"
CONF_IP="10.193.167.10"
NAMESERVER=$(cat /etc/resolv.conf | grep nameserver | head -1 | awk '{print $2}')
CONF_SUBNET="255.255.255.0"
CONF_ROUTER=${SWITCHIP}
gen_media unbound

CONF_HOSTNAME="mail1"
CONF_IP="10.193.167.11"
NAMESERVER="10.193.167.10"
SEARCH="ny-central.lab"
gen_media mail1

CONF_HOSTNAME="mail2"
CONF_IP="10.193.167.12"
SEARCH="eurobsdcon.lab"
gen_media mail2

CONF_HOSTNAME="client"
CONF_IP="10.193.167.19"
SEARCH="lab"
gen_media client

#
# remove any previous entries from known hosts
#
if [ -e /root/.ssh/known_hosts ]; then
    sed -i '' '/10.193.167.10/d' /root/.ssh/known_hosts
    sed -i '' '/10.193.167.11/d' /root/.ssh/known_hosts
    sed -i '' '/10.193.167.19/d' /root/.ssh/known_hosts
    sed -i '' '/unbound/d' /root/.ssh/known_hosts
    sed -i '' '/mail1/d' /root/.ssh/known_hosts
    sed -i '' '/mail2/d' /root/.ssh/known_hosts
    sed -i '' '/client/d' /root/.ssh/known_hosts
    sed -i '' '/cloud/d' /root/.ssh/known_hosts
fi

./104_setup_vmjail.sh -m 1G -c unbound.iso unbound

./104_setup_vmjail.sh -m 4G -c mail1.iso mail1

./104_setup_vmjail.sh -m 4G -c mail2.iso mail2

./104_setup_vmjail.sh -m 2G -c client.iso client

# enter those addresses into hosts file to help simplify
# access later on
set +e
cat /etc/hosts | grep mail1 > /dev/null
if [ "0" != "$?" ]; then
    cat <<EOF >/etc/hosts
10.193.167.10 unbound
10.193.167.11 mail1
10.193.167.12 mail2
10.193.167.19 client
EOF
fi
set -e

# after setting servers up, we install unbound and
# configure our two domains to talk to each other

if [ ! -e /ca ]; then
    # create a CA for our tests
    pkg install -y easy-rsa
    mkdir -p /ca
    CURRENT=$(pwd)
    cd /ca && easy-rsa init-pki
    echo "set_var EASYRSA_REQ_CN \"ca.lab\"" > /ca/pki/vars
    echo "set_var EASYRSA_DN \"cn_only\"" >> /ca/pki/vars
    echo "set_var EASYRSA_BATCH       \"yes\"" >> /ca/pki/vars
    easyrsa build-ca nopass
    
    # generate server certificates
    echo "set_var EASYRSA_REQ_CN \"mail.ny-central.lab\"" > /ca/pki/vars
    echo "set_var EASYRSA_DN \"cn_only\"" >> /ca/pki/vars
    echo "set_var EASYRSA_BATCH       \"yes\"" >> /ca/pki/vars
    easyrsa build-server-full mail.ny-central.lab nopass
    echo "set_var EASYRSA_REQ_CN \"mail.eurobsdcon.lab\"" > /ca/pki/vars
    echo "set_var EASYRSA_DN \"cn_only\"" >> /ca/pki/vars
    echo "set_var EASYRSA_BATCH       \"yes\"" >> /ca/pki/vars
    easyrsa build-server-full mail.eurobsdcon.lab nopass

    cd ${CURRENT}
fi    
cp /ca/pki/issued/mail.ny-central.lab.crt .
cp /ca/pki/private/mail.ny-central.lab.key .
cp /ca/pki/issued/mail.eurobsdcon.lab.crt .
cp /ca/pki/private/mail.eurobsdcon.lab.key .

set +e
pkg info | grep ca_root_nss > /dev/null
if [ "0" != "$?" ]; then
    pkg install -y ca_root_nss
fi
set -e

# install the CA certificate locally, so we can trust
# those mail servers when accessing as client
if [ ! -e /usr/local/etc/ssl/cert.pem.ca ]; then
    cp /usr/local/etc/ssl/cert.pem /usr/local/etc/ssl/cert.pem.ca
    cat /ca/pki/ca.crt >> /usr/local/etc/ssl/cert.pem
    cat /ca/pki/ca.crt >> /etc/ssl/cert.pem
fi
mkdir -p /usr/share/certs/trusted
if [ ! -e /usr/share/certs/trusted/localca.pem ]; then
    install -m 0444 /ca/pki/ca.crt /usr/share/certs/trusted/localca.pem
    certctl trust /ca/pki/ca.crt
    openssl rehash /etc/ssl/certs
    certctl rehash
fi

# for simplicity, we create a single dhparam file for all
if [ ! -e dhparams.pem ]; then
    openssl dhparam -out dhparams.pem 4096
fi

# wait for unbound to complete booting
set +e
await_ip 10.193.167.10
set -e

# ssh_copy moved to utils.sh

ssh_copy mailsrv/01_setup_unbound.sh 10
ssh_copy mailsrv/unbound.conf 10
ssh_copy 'mailsrv/*.zone' 10

if [ -e unbound.pkg-cache.tar.xz ]; then
    ssh_copy unbound.pkg-cache.tar.xz 10
fi

echo Connecting to unbound - run 01_setup_unbound.sh as root!
echo Press ENTER to continue.
read ENTER
ssh -i .ssh/id_ecdsa lab@10.193.167.10

# retrieve updated pkg-cache.tar.xz to be used for 2nd mail server
scp -i .ssh/id_ecdsa lab@10.193.167.10:unbound.pkg-cache.tar.xz .

set +e
await_ip 10.193.167.11
set -e
#sleep_dot 10

# connect to mail server 1 and set up mail domain
# ny-central.lab
ssh_copy mailsrv/install.sh 11
if [ -e clamav.tar.xz ]; then
    ssh_copy clamav.tar.xz 11
fi
if [ -e mailsrv.pkg-cache.tar.xz ]; then
    ssh_copy mailsrv.pkg-cache.tar.xz 11
fi
if [ -e spamassassin.tar.xz ]; then
    ssh_copy spamassassin.tar.xz 11
fi
cp mailsrv/config.sh mailsrv/config.mail1.sh
sed -i '' 's/mailsrv.ny-central.local/mail1.ny-central.lab/' \
    mailsrv/config.mail1.sh
sed -i '' 's/ny-central.local/ny-central.lab/' \
    mailsrv/config.mail1.sh
sysrc -f mailsrv/config.mail1.sh NETWORKS="10.193.167.0/24"
sysrc -f mailsrv/config.mail1.sh SSHUSERS=lab
sysrc -f mailsrv/config.mail1.sh EXTIF=vtnet0
mv mailsrv/config.mail1.sh /tmp/config.sh
ssh_copy /tmp/config.sh 11
rm -f /tmp/config.sh

if [ -e mail.ny-central.lab.crt ]; then
    mv mail.ny-central.lab.crt /tmp/server.crt
    mv mail.ny-central.lab.key /tmp/server.key
    ssh_copy /tmp/server.crt 11
    ssh_copy /tmp/server.key 11
    rm -f /tmp/server.crt
    rm -f /tmp/server.key
fi
ssh_copy /ca/pki/ca.crt 11

ssh_copy dhparams.pem 11

echo Connecting to mail1 - run install.sh as root
echo Press ENTER to continue.
read ENTER
ssh -i .ssh/id_ecdsa lab@10.193.167.11

# retrieve updated pkg-cache.tar.xz to be used for 2nd mail server
scp -i .ssh/id_ecdsa lab@10.193.167.11:mailsrv.pkg-cache.tar.xz .

# Copy down dns record to unbound server
set +e
scp -i .ssh/id_ecdsa lab@10.193.167.11:ny-central.lab.dns .
# retrieve updated clamav.tar.xz to be used for 2nd mail server
scp -i .ssh/id_ecdsa lab@10.193.167.11:clamav.tar.xz .
set -e
if [ -e ny-central.lab.dns ]; then
    # Copy up to unbound
    ssh_copy ny-central.lab.dns 10
    # Copy follow up script to server
    ssh_copy mailsrv/02_update_unbound.sh 10
    ssh -i .ssh/id_ecdsa lab@10.193.167.10 'doas /bin/sh 02_update_unbound.sh'
else
    echo Skipping DNS - installation mode?
fi

#
# Setup eurobsdcon.lab server
#

# prepare an install script without final clamav tar command for
# next host, because we no longer need to do that
cp mailsrv/install.sh /tmp/install.sh
sed -i '' 's@tar -C \/var\/db\/clamav -cJf clamav.tar.xz \.@@g' /tmp/install.sh
ssh_copy /tmp/install.sh 12
scp -o ConnectionAttempts=50 -o ConnectTimeout=3600 \
	-o StrictHostKeyChecking=no \
	-i .ssh/id_ecdsa /tmp/install.sh lab@10.193.167.12:doinstall.sh

rm -f /tmp/install.sh
if [ -e mailsrv.pkg-cache.tar.xz ]; then
    ssh_copy mailsrv.pkg-cache.tar.xz 12
fi
if [ -e clamav.tar.xz ]; then
    ssh_copy clamav.tar.xz 12
fi
if [ -e spamassassin.tar.xz ]; then
    ssh_copy spamassassin.tar.xz 12
fi
cp mailsrv/config.sh mailsrv/config.mail2.sh
sed -i '' 's/mailsrv.ny-central.local/mail2.eurobsdcon.lab/' \
    mailsrv/config.mail2.sh
sed -i '' 's/ny-central.local/eurobsdcon.lab/' \
    mailsrv/config.mail2.sh
sysrc -f mailsrv/config.mail2.sh NETWORKS="10.193.167.0/24"
sysrc -f mailsrv/config.mail2.sh SSHUSERS=lab
sysrc -f mailsrv/config.mail2.sh EXTIF=vtnet0
mv mailsrv/config.mail2.sh /tmp/config.sh
ssh_copy /tmp/config.sh 12
rm -f /tmp/config.sh

if [ -e mail.eurobsdcon.lab.crt ]; then
    mv mail.eurobsdcon.lab.crt /tmp/server.crt
    mv mail.eurobsdcon.lab.key /tmp/server.key
    ssh_copy /tmp/server.crt 12
    ssh_copy /tmp/server.key 12
    rm -f /tmp/server.crt
    rm -f /tmp/server.key
fi
ssh_copy /ca/pki/ca.crt 12

ssh_copy dhparams.pem 12

#echo Connecting to mail2 - run install.sh as root
#echo Press ENTER to continue.
#read ENTER
#ssh -i .ssh/id_ecdsa lab@10.193.167.12
service jail stop mail2

# Run interactively for doinstall.sh installation
./104a_run_interactively.sh mail2
# Restart as regular VM
service jail onestart mail2

# retrieve updated pkg-cache.tar.xz to be used for 2nd mail server
scp -o ConnectionAttempts=50 -o ConnectTimeout=3600 \
    -i .ssh/id_ecdsa lab@10.193.167.12:mailsrv.pkg-cache.tar.xz .

# Copy down dns record
set +e
scp -i .ssh/id_ecdsa lab@10.193.167.12:eurobsdcon.lab.dns .
set -e
if [ -e eurobsdcon.lab.dns ]; then
    # Copy up to unbound
    ssh_copy eurobsdcon.lab.dns 10
    # Copy follow up script to server
    ssh_copy mailsrv/02_update_unbound.sh 10
    ssh -i .ssh/id_ecdsa lab@10.193.167.10 'doas /bin/sh 02_update_unbound.sh'
else
    echo Skipping DNS update - installation mode?
fi

#
# Ready the client
#
ssh_copy /ca/pki/ca.crt 19
ssh_copy mailsrv/pinerc.tar 19
ssh_copy mailsrv/03_setup_client.sh 19
scp -o ConnectionAttempts=50 -o ConnectTimeout=3600 \
	-o StrictHostKeyChecking=no \
	-i .ssh/id_ecdsa mailsrv/03_setup_client.sh lab@10.193.167.19:doinstall.sh
if [ -e client.pkg-cache.tar.xz ]; then
    ssh_copy client.pkg-cache.tar.xz 19
fi

#echo Connection to client - run 03_setup_client.sh as root
#echo Press ENTER to continue.
#read ENTER
#ssh -i .ssh/id_ecdsa lab@10.193.167.19
service jail stop client

# Run doinstall.sh installation interactively
./104a_run_interactively.sh client
# Restart VM
service jail start client

scp -o ConnectionAttempts=50 -o ConnectTimeout=3600 \
    -i .ssh/id_ecdsa lab@10.193.167.19:client.pkg-cache.tar.xz .

tar -C /var/cache/pkg -cvf lab.pkg-cache.tar .
rm -f lab.pkg-cache.tar.xz
xz lab.pkg-cache.tar

echo Base setup completed.
