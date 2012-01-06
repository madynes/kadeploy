#!/bin/sh

FILE_LOCK=$1

# remove first argument
first_argument=""

for argument in $@; do
        if [ "${first_argument}" = "" ]; then
                first_argument=${argument}
        else
                remaining_arguments="${remaining_arguments} ${argument}"
        fi
done

${remaining_arguments}

rm ${FILE_LOCK}
