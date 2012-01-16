#!/usr/bin/ruby


NEST = 'nest'
ROOT = 'root'
RPM_MIRROR = 'http://ftp.ciril.fr/pub/linux/centos/6.1/os/x86_64/'
INCLUDES = 'filesystem coreutils setup net-tools grep sed bash perl module-init-tools openssh-clients openssh-server util-linux dhclient bzip2 gzip ctorrent kexec-tools parted.x86_64 busybox grub2 nc tar e2fsprogs grub'

def exec(cmd)
  system(cmd)
end

def msg(msg)
  puts(msg)
end

def add_extra_kadeploy_stuff
  msg("Configure some stuffs for Kadeploy")
  exec("sed -i 's/^root:x:/root::/' #{ROOT}/etc/passwd")
  exec("mkdir -p #{ROOT}/mnt/dest")
  exec("mkdir -p #{ROOT}/rambin")
  exec("mkdir -p #{ROOT}/mnt/tmp")
  exec("mkdir -p #{ROOT}/usr/local/bin")
  exec("cp kadeploy_specific/scripts/* #{ROOT}/usr/local/bin")
  exec("chmod +x #{ROOT}/usr/local/bin/*")

  fstab_str = <<EOF
tmpfs     /dev/shm    tmpfs    defaults         0 0
devpts    /dev/pts    devpts   gid=5,mode=620   0 0
sysfs     /sys        sysfs    defaults         0 0
proc      /proc       proc     defaults         0 0

EOF
  fstab_file = File.new("#{ROOT}/etc/fstab",  "w")
  fstab_file.write(fstab_str)
  fstab_file.close

  rclocal_str = <<EOF
dhclient eth0

HOSTNAME=`cat /var/lib/dhclient/dhclient.leases|sort -u|grep "host-name"|sed 's/  option host-name \\"\\(.*\\)\\";/\\1/'`
DOMAIN=`cat /var/lib/dhclient/dhclient.leases|sort -u|grep "domain-name "|sed 's/  option domain-name \\"\\(.*\\)\\";/\\1/'`
DNSSERVER=`cat /var/lib/dhclient/dhclient.leases|sort -u|grep "domain-name-servers"|sed 's/  option domain-name-servers \\(.*\\);/\\1/'`
IPADDR=`cat /var/lib/dhclient/dhclient.leases|sort -u|grep "fixed-address"|sed 's/  option fixed-address \\(.*\\);/\\1/'`

echo "$HOSTNAME.$DOMAIN" > /etc/hostname
echo "$IPADDR $HOSTNAME.$DOMAIN $HOSTNAME" >> /etc/hosts
/bin/hostname $HOSTNAME.$DOMAIN

ln -s /sbin/busybox /bin/ash

(while true; do nc -l 25300; done) &
exit 0
EOF
  rclocal_file = File.new("#{ROOT}/etc/rc.local",  "w+")
  rclocal_file.write(rclocal_str)
  rclocal_file.close

  bashrc_str = <<EOF
export LANG=C
export PATH=/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/bin
EOF
  bashrc_file = File.new("#{ROOT}/root/.bashrc", "w")
  bashrc_file.write(bashrc_str)
  bashrc_file.close

  exec("mkdir -p #{ROOT}/root/.ssh")
  exec("cat kadeploy_specific/ssh/id_deploy.pub >> #{ROOT}/root/.ssh/authorized_keys")
  exec("mkdir -p #{ROOT}/etc/kadeploy3/keys")
  exec("cp kadeploy_specific/ssh/id_deploy #{ROOT}/etc/kadeploy3/keys/")
  exec("chmod 400 #{ROOT}/etc/kadeploy3/keys/*")
end

def make_rootfs
  exec("febootstrap -i #{INCLUDES.split(" ").join(" -i ")} centos-6.1 #{ROOT} #{RPM_MIRROR}")
  exec("febootstrap-minimize #{ROOT}")
end

def pack_rootfs(dest)
  exec("chroot #{ROOT} sh -c \"find * | cpio --create -H newc\" | gzip -9 > #{dest}")
end

def make_nest
  exec("rm -rf #{NEST}")
  exec("mkdir -p #{NEST}/bin")
  exec("cp -f #{ROOT}/sbin/busybox #{NEST}/bin")
  utils = ['awk', 'cpio', 'free', 'grep', 'gunzip', 'ls', 'mkdir', 'mount', 'rm', 'sh', 'umount']
  utils.each { |u|
    exec("ln #{NEST}/bin/busybox #{NEST}/bin/#{u}")
  }
  exec("cp -f #{ROOT}/sbin/switch_root #{NEST}/bin")
  #Crappy...
  exec("mkdir #{NEST}/lib")
  exec("cp #{ROOT}/lib64/ld-linux-x86-64.so.2 #{NEST}/lib")
  exec("cp #{ROOT}/lib64/libc.so.6 #{NEST}/lib")
  exec("(cd #{NEST} ; ln -s lib lib64)")
  init_str = <<EOF
#!/bin/sh
mkdir /proc
mount -t proc proc /proc
if (grep -q break=top /proc/cmdline); then
  echo "honoring break=top kernel arg"
  /bin/sh
fi
mkdir /newroot
MEMSIZE=\$(free | grep 'Mem:' | awk '{ print \$2 }')
mount -t tmpfs -o size=\${MEMSIZE}k tmpfs /newroot
if (grep -q break=preunpack /proc/cmdline); then
  echo "honoring break=preunpack kernel arg"
  /bin/sh
fi
cd /newroot
echo unpacking rootfs...
gunzip - < /rootfs.cgz | cpio -i
if (grep -q break=bottom /proc/cmdline); then
  echo "honoring break=bottom kernel arg"
  /bin/sh
fi
umount /sys /proc
echo running /sbin/init...
exec /bin/switch_root /newroot /sbin/init
EOF
  init_file = File.new("#{NEST}/init",  "w")
  init_file.write(init_str)
  init_file.close

  exec("chmod a+x #{NEST}/init")
  
  add_extra_kadeploy_stuff
  msg("creating rootfs.cgz...")
  pack_rootfs("#{NEST}/rootfs.cgz")
end

make_rootfs
make_nest
