#!/bin/sh

SCRIPT_BRIDGE=./setupkvmbridge
SCRIPT_LAUNCH=./launchkvms
SCRIPT_GENNODES=./genkvmnodefile

NETWORK=172.16.65.86/20

hostfile=`tempfile`
#kavlan -l > $hostfile
uniq $OAR_NODEFILE > $hostfile
taktuk -s -l root -f $hostfile broadcast exec [ rm -f /tmp/`basename $SCRIPT_BRIDGE` ] && \
taktuk -s -l root -f $hostfile broadcast put [ $SCRIPT_BRIDGE ] [ /tmp ] && \
taktuk -s -l root -f $hostfile broadcast exec [ /tmp/`basename $SCRIPT_BRIDGE` ]
nodefile=`tempfile`
$SCRIPT_GENNODES $NETWORK > $nodefile
taktuk -s -l root -f $hostfile broadcast exec [ rm -f /tmp/`basename $SCRIPT_LAUNCH` ] && \
taktuk -s -l root -f $hostfile broadcast put [ $SCRIPT_LAUNCH ] [ /tmp ] && \
taktuk -s -l root -f $hostfile broadcast exec [ cat - \| /tmp/`basename $SCRIPT_LAUNCH` ] \; broadcast input file [ $nodefile ]
rm $hostfile
rm $nodefile
