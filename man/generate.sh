#!/bin/bash -e

DESTDIR=$1

BASEDIR=".."
BINDIR='bin/'
SBINDIR='sbin/'
MANKINDS="1"

VERSION=$(cat ${BASEDIR}/major_version).$(cat ${BASEDIR}/minor_version)
TEMPLATE='./TEMPLATE'


if [ $# -lt 1 ]
then
  echo "usage: $0 <dest_dir>"
  exit 1
fi


for kind in $MANKINDS
do
  dir=${DESTDIR}/man${kind}
  echo Creating the $dir directory
  mkdir -p $dir

  for file in ${BASEDIR}/$BINDIR/* ${BASEDIR}/$SBINDIR/*
  do
    echo Generate man for $(basename $file)
    KADEPLOY3_LIBS=${BASEDIR}/lib/ help2man --no-info \
      --version-string=$VERSION --include $TEMPLATE \
      $file > ${dir}/$(basename $file).$kind
  done
done
