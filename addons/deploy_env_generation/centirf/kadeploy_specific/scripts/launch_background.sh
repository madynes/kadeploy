#!/bin/sh

if [ "$1" = "" ]; then
	exit 0;
fi

FILE_LOCK=$1

if [ -f ${FILE_LOCK} ]; then
	rm ${FILE_LOCK}
fi

echo 1 > ${FILE_LOCK}

/sbin/start-stop-daemon -S -x /usr/local/bin/execute_background.sh -b -- "$@"
