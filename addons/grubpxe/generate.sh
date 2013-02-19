#!/bin/bash -e

source generate.conf

FORMAT=i386-pc-pxe

if [ $# -lt 3 ]
then
  echo "usage: $0 <dest_file> <config_file> <modules_file>"
  exit 0
fi

if [ -z `which ${BINARY}` ]
then
  echo "grub-mkimage not found (${BINARY})" 1>&2
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

if [ -e "${MODULES_DIR}" ]
then
  OPTS="${OPTS} --directory=${MODULES_DIR}"
fi

OPTS="${OPTS} $(cat $3)"

echo ${BINARY} --format=${FORMAT} --output=$1 --prefix='(pxe)' --config=$2 $OPTS
${BINARY} --format=${FORMAT} --output=$1 --prefix='(pxe)' --config=$2 $OPTS
