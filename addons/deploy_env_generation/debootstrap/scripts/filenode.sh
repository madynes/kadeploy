#!/bin/sh

FILE=$1

# delete file if necessary
if [ -f ${FILE} ]; then
        rm ${FILE}
fi

# remove first argument
first_argument=""

for argument in $@; do
        if [ "${first_argument}" = "" ]; then
                first_argument=${argument}
        else
        	echo ${argument} >> ${FILE}
	fi
done
