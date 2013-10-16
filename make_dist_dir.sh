#!/bin/sh
DIST_DIR=`basename $1`
BUILD_DIR=`basename $BUILD_DIR`
PKG_DIR=`basename $PKG_DIR`
AR_DIR=`basename $AR_DIR`
SELF=`basename $0`
KADEPLOY_FILES=`git ls-tree --name-only -r -t HEAD`
shift
KADEPLOY_FILES="$KADEPLOY_FILES $@"

mkdir -p $DIST_DIR
for file in $KADEPLOY_FILES
do
  if [ -d "$file" ]
  then
    mkdir -p $DIST_DIR/$file
  else
    cp $file $DIST_DIR/$(dirname $file)/
  fi
done
