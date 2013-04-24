#!/bin/sh
DIST_DIR=`basename $1`
BUILD_DIR=`basename $BUILD_DIR`
PKG_DIR=`basename $PKG_DIR`
AR_DIR=`basename $AR_DIR`
SELF=`basename $0`

mkdir -p $DIST_DIR

for d in `find . -name .git -prune -o -name $BUILD_DIR -prune -o -name $PKG_DIR -prune -o -name $AR_DIR -prune -o -name pkg -prune -o -name $DIST_DIR -prune -o -type d -print`
do
    dir=`echo $d|sed "s/^.\///"`
    if [ "$dir" != "." ]
    then
        mkdir -p $DIST_DIR/$dir
    fi
done

for f in `find . -name .git -prune -o -name $BUILD_DIR -prune -o -name $PKG_DIR -prune -o -name $AR_DIR -prune -o -name pkg -prune -o -name $DIST_DIR -o -type f -print`
do
    dir=`dirname $f|sed "s/^.\///"`
    if [ "$dir" = "." ]
    then
        cp $f $DIST_DIR
    else
        cp $f $DIST_DIR/$dir
    fi
done
