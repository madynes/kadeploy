#!/bin/bash
DIR=debootstrap
SCRIPTS_DIR=scripts

DEBOOTSTRAP="/usr/sbin/debootstrap"

DEBOOTSTRAP_INCLUDE_PACKAGES=dhcpcd,openssh-client,openssh-server,kexec-tools,bzip2,taktuk,grub-pc,ctorrent,hdparm,parted

DEBOOTSTRAP_EXCLUDE_PACKAGE=vim-common,vim-tiny,traceroute,manpages,man-db,adduser,cron,logrotate,laptop-detect,tasksel,tasksel-data,dhcp3-client,dhcp3-common,wget

mkdir -p $DIR

$DEBOOTSTRAP --include=$DEBOOTSTRAP_INCLUDE_PACKAGES --exclude=$DEBOOTSTRAP_EXCLUDE_PACKAGE lenny $DIR

chroot $DIR apt-get -y --force-yes install ash 2>/dev/null
chroot $DIR apt-get -y --force-yes clean 2>/dev/null

echo "127.0.0.1       localhost" > $DIR/etc/hosts

echo "localhost" >  $DIR/etc/hostname

cat >> $DIR/root/.bashrc <<EOF
export PATH=/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/bin
export LC_ALL="C"
EOF

mkdir -p $DIR/root/.ssh
cat ../../ssh/id_deploy.pub > $DIR/root/.ssh/authorized_keys
mkdir -p $DIR/.keys
cp ../../ssh/* $DIR/.keys/

cat > $DIR/etc/nsswitch.conf <<EOF
passwd:     files
group:      files

hosts:      files dns

ethers:     files
etmasks:    files
networks:   files
protocols:  files
rpc:        files
services:   files

netgroup:   nisplus

publickey:  nisplus

automount:  files
aliases:    files nisplus
EOF

#We add the deploy user with root rights
head -n 1 $DIR/etc/passwd |sed -e 's/root/deploy/1' -e 's/root/deploy/1'>> $DIR/etc/passwd
head -n 1 $DIR/etc/shadow |sed 's/root/deploy/' >> $DIR/etc/shadow
head -n 1 $DIR/etc/shadow- |sed 's/root/deploy/' >> $DIR/etc/shadow-

cp linuxrc $DIR/
cp mkdev $DIR/dev

cp $SCRIPTS_DIR/* $DIR/usr/local/bin

chmod +x $DIR/usr/local/bin/*

mkdir $DIR/mnt/dest
mkdir $DIR/rambin
mkdir $DIR/mnt/tmp

for d in `find $DIR/usr/share -mindepth 1 -maxdepth 1|grep -v perl`
do
    rm -rf $d
done
