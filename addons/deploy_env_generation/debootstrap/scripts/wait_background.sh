#!/bin/sh

FILE_LOCK=$1

while [ -f ${FILE_LOCK} ]; do
	/bin/sleep 1
done
