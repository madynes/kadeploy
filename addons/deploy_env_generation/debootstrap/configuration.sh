#!/bin/bash

PATH=/bin:/sbin:/usr/bin:/usr/sbin

# Fill-in these values (absolute path is needed)
KERNEL_CONFIG=""
KERNEL_VERSION=""
OUTPUT_KERNEL="deploy-vmlinuz"
OUTPUT_INITRD="deploy-initrd"
KERNEL_2_6_ARCHIVE_URL="http://www.eu.kernel.org/pub/linux/kernel/v2.6/"

# Ramdisk size in Ko
INITRD_SIZE="200000"
INITRD_ROOTDEVICE="/dev/ram0"

# For // kernel compilation
NUMBER_OF_CPU=2
NUMBER_OF_CORE=2
COMPILATION_PARALLELISM=$(( ${NUMBER_OF_CPU} * ${NUMBER_OF_CORE} ))

# TMP_INITRD=$OUTPUT_INITRD.uncompressed
CURRENT_DIR=$( pwd )
TODAY=$( date +%Y%m%d-%H%M-%N )
CURRENT_BUILTDIR="$CURRENT_DIR/built-$TODAY"
TMP_ROOTDIR="/tmp"
RD_MOUNT="$TMP_ROOTDIR/__mountrd"
RD_FILE="$TMP_ROOTDIR/initrd.build"
TMP_KERNELDIR="$TMP_ROOTDIR/__buildkernel"

DEBOOTSTRAP_DIR=bootstrap-dir
SCRIPTS_DIR=scripts

DEBOOTSTRAP="/usr/sbin/debootstrap"
DEBOOTSTRAP_INCLUDE_PACKAGES=dhcpcd,openssh-client,openssh-server,kexec-tools,bzip2,taktuk,grub-pc,ctorrent,hdparm,parted,ntpdate
DEBOOTSTRAP_EXCLUDE_PACKAGE=vim-common,vim-tiny,traceroute,manpages,man-db,adduser,cron,logrotate,laptop-detect,tasksel,tasksel-data,dhcp3-client,dhcp3-common,wget,network-manager

SSH_DEPLOY_PUBLIC_KEY=../../ssh/id_deploy.pub
SSH_DEPLOY_PRIVATE_KEY=../../ssh/id_deploy
