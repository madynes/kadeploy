#!/bin/sh
DIST_DIR=$1

for f in `find . -name .svn -prune -o -name pkg -prune -o -type f -print`
do
    dir=`dirname $f|sed "s/^.\///"`
    if [ "$dir" = "." ]
    then
	cp $f $DIST_DIR
    else
	mkdir -p $DIST_DIR/$dir
	cp $f $DIST_DIR/$dir
    fi
done
