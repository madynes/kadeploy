#!/bin/bash
# make_febootstrap.sh
# Generate a Kadeploy-compliant initrd content on a Fedora-like system
# Authors:  Xavier Delaruelle <xavier.delaruelle@cea.fr>
#           Joseph Ligier <ligierj@ocre.cea.fr>
# Requires: febootstrap >= 2.5

DIR=bootstrap-dir
SCRIPTS_DIR=scripts


# WARNING: all of the following packages have to be available in the yum
# repositories specified on the command-line. So TakTuk & GRUB2 RPMs have to
# be added to your local yum repository since they are not part of the
# official Fedora repositories
FEBOOTSTRAP_INCLUDE_PACKAGES="filesystem coreutils setup net-tools \
  grep sed bash perl module-init-tools openssh-clients openssh-server \
  util-linux dhclient bzip2 gzip ctorrent kexec-tools parted.x86_64 \
  busybox grub2 nc tar taktuk"


# WARNING: make_febootstrap.sh has to be executed by root since febootstrap
# needs super-user privileges. If febootstrap is executed by a lambda-user:
# - /root directory will not be created
# - /dev/* will not be generated as device file but as regular files
# - files in the build dir will be owned by the user who has executed the 
#   the script and corresponding initrd will fail to execute the content of
#   the /linuxrc script and will print "only root can do that" error messages
if [ "$(id -u)" != "0" ]; then
    echo "make_febootstrap.sh needs root privileges to run correctly"
    exit 2
fi

#######################################
# Parse command-line
#######################################

# check command-line options
if [ $# -lt 1 ]; then
    echo "Usage: make_febootstrap.sh repo1url [ repo2url ... ]

Examples:
- make_febootstrap.sh http://master/fedora/releases/11/Everything/x86_64/os/
- make_febootstrap.sh http://master/pub/CentOS/5.2/os/x86_64/ \\
    http://master/pub/CentOS/5.2/extras/x86_64/
"
    exit 1
fi

mainrepo=''
if [ -n "$1" ]; then
    mainrepo=$1
    shift
fi

extrarepo=''
while [ -n "$1" ]; do
    extrarepo="$extrarepo -u $1"
    shift
done


#######################################
# Install packages in build tree
#######################################

# arch of some packages have to be precised to avoid yum
# installing both x86_64 and i386 versions
FEBOOTSTRAP_OPTIONS="-i $(echo $FEBOOTSTRAP_INCLUDE_PACKAGES \
  | sed 's/ / \-i /g') $extrarepo"

/usr/bin/febootstrap $FEBOOTSTRAP_OPTIONS dummy $DIR $mainrepo || exit 3


#######################################
# Clean build tree
#######################################

# remove unecessary content from the builddir (doc, locales, etc)
/usr/bin/febootstrap-minimize --all $DIR 


#######################################
# Adapt build tree to Kadeploy needs
#######################################

echo "127.0.0.1       localhost" > $DIR/etc/hosts

# RedHat systems use /etc/sysconfig/network instead of /etc/hostname
cat >$DIR/etc/sysconfig/network <<EOF
NETWORKING=yes
NETWORKING_IPV6=no
NOZEROCONF=yes
HOSTNAME=localhost
DOMAINNAME=localdomain
EOF

# a default fstab file is needed by /etc/rc.d/rc.sysinit
cat >$DIR/etc/fstab <<EOF
tmpfs                   /dev/shm                tmpfs   defaults        0 0
devpts                  /dev/pts                devpts  gid=5,mode=620  0 0
sysfs                   /sys                    sysfs   defaults        0 0
proc                    /proc                   proc    defaults        0 0
EOF

cat >$DIR/root/.bashrc <<EOF
export PATH=/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/bin
export LC_ALL="C"
EOF

mkdir -m 700 $DIR/root/.ssh
cat ../../ssh/id_deploy.pub > $DIR/root/.ssh/authorized_keys
mkdir -p $DIR/etc/kadeploy3/keys
cp ../../ssh/* $DIR/etc/kadeploy3/keys/
chmod 400 $DIR/etc/kadeploy3/keys/*

# create ssh host keys
ssh-keygen -t rsa -C '' -N '' -f $DIR/etc/ssh/ssh_host_rsa_key
ssh-keygen -t dsa -C '' -N '' -f $DIR/etc/ssh/ssh_host_dsa_key

# We add the deploy user with root rights
head -n 1 $DIR/etc/passwd | sed -e 's/root/deploy/1' -e 's/root/deploy/1' >> $DIR/etc/passwd
head -n 1 $DIR/etc/shadow | sed 's/root/deploy/' >> $DIR/etc/shadow
head -n 1 $DIR/etc/shadow- | sed 's/root/deploy/' >> $DIR/etc/shadow-

# Thanks to Busybox, we are able to provide ash and start-stop-daemon
# which are not available on RedHat-like systems.
ln -s /sbin/busybox $DIR/bin/ash
ln -s busybox $DIR/sbin/start-stop-daemon

cp linuxrc-redhat $DIR/linuxrc

cp mkdev $DIR/dev/

mkdir -p $DIR/usr/local/bin
cp $SCRIPTS_DIR/* $DIR/usr/local/bin

chmod +x $DIR/usr/local/bin/*

mkdir $DIR/mnt/dest
mkdir $DIR/rambin
mkdir $DIR/mnt/tmp

# remove unneeded stuff like images
for d in $(find $DIR/usr/share -mindepth 1 -maxdepth 1 | grep -v grub)
do
    rm -rf $d
done
