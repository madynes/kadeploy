#!/bin/bash

SITES="rennes nantes lille nancy luxembourg lyon grenoble sophia"

if [ ! $# -eq 1 2; then
  echo "USAGE: $0 [debirf dir] [version]"
  exit 1
fi

DEBIRF_DIR=$1
DEBIAN_VERSION=${DEBIRF_DIR#debirf-}
VERSION=$2


kernel_parts="deploy-$DEBIAN_VERSION-initrd deploy-$DEBIAN_VERSION-vmlinuz"
for kernel_part in $kernel_parts; do
  file=$DEBIRF_DIR/kernel/$kernel_part-$VERSION-g5k
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
    scp $DEBIRF_DIR/kernel/$file $server:/tmp
    echo "    * move $file into /var/lib/tftpboot/kernels"
    ssh $server sudo mv /tmp/$file /var/lib/tftpboot/kernels
    echo "    * change owner on $file"
    ssh $server sudo chown root.deploy /var/lib/tftpboot/kernels/$file
    echo "    * change mode to 755 on $file"
    ssh $server sudo chmod 755 /var/lib/tftpboot/kernels/$file
  done
done


