#!/bin/bash

SITES="rennes nantes lille reims nancy luxembourg lyon grenoble sophia"

if [ ! $# -eq 1 ]; then
  echo "USAGE: $0 version"
  exit 1
fi

kernel_parts="deploy-wheezy-initrd deploy-wheezy-vmlinuz"
for kernel_part in $kernel_parts; do
  file=../kernel/$kernel_part-$1-g5k
  if [ ! -f $file ]; then
    echo "$file does not exists !"
    exit 1
  fi
done

for site in $SITES; do
  echo "--> deploying on site $site..."
  server=kadeploy.$site.grid5000.fr
  for kernel_part in $kernel_parts; do
    file=$kernel_part-$1-g5k
    scp ../kernel/$file $server:/tmp
    echo "    * move $file into /var/lib/tftpboot/kernels"
    ssh $server sudo mv /tmp/$file /var/lib/tftpboot/kernels
    echo "    * change owner on $file"
    ssh $server sudo chown root.deploy /var/lib/tftpboot/kernels/$file
    echo "    * change mode to 755 on $file"
    ssh $server sudo chmod 755 /var/lib/tftpboot/kernels/$file
  done
done


