#!/bin/sh

# build chain as root using a detached program
# can be run as many times as there are transfers because the chain can be rebuilt

/sbin/start-stop-daemon -S -x /usr/local/bin/build_chain.sh -b -- $1
