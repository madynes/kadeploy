#!/bin/bash -e

FORMAT=i386-pc-pxe


if [ $# -lt 3 ]
then
  echo "usage: $0 <dest_file> <config_file> <modules_file>"
  exit 0
fi

if [ -z `which grub-mkimage` ]
then
  echo "grub-mkimage is not installed" 1>&2
  exit 1
fi

if [ -z "$2" ]
then
  echo "file not found '$2'" 1>&2
  exit 1
fi

if [ -z "$3" ]
then
  echo "file not found '$3'" 1>&2
  exit 1
fi

MODULES=$(cat $3)
grub-mkimage --format=${FORMAT} --output=$1 --prefix='(pxe)/boot/grub' \
  --config=$2 ${MODULES}
