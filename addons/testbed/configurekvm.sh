#!/bin/bash

SSH_KEY=.ssh/id_rsa
TMP_SSH_KEY=/tmp/identity

SCRIPT_BRIDGE=./setupkvmbridge
SCRIPT_LAUNCH=./launchkvms
SCRIPT_GENNODES=./genkvmnodefile

NETWORK_CIDR=20


if [ -n "$1" ]
then
  nbkvms=$1
else
  echo "usage: $0 <nb_kvm_per_host> [<hostlist>]"
  echo "When no hostlist specified, using 'kavlan -l' and removing a node from the list to be the kadeploy daemon"
  exit 1
fi

if [ -n "$2" ]
then
  if [ -e $2 ]
  then
    hostfile=$2
  else
    echo file not found $2
    exit 1
  fi
else
  tmphostfile=1
  hostfile=`tempfile`
  kavlan -l | sort -n | sed -e '1d' > $hostfile
fi

network=`dig +short $(head -n 1 $hostfile)`

taktuk -s -n -l root -f $hostfile broadcast exec [ rm -f $TMP_SSH_KEY ] 1>/dev/null && \
taktuk -s -n -l root -f $hostfile broadcast put [ $SSH_KEY ] [ $TMP_SSH_KEY ] 1>/dev/null && \
taktuk -s -n -l root -f $hostfile broadcast exec [ rm -f /tmp/`basename $SCRIPT_BRIDGE` ] 1>/dev/null && \
taktuk -s -n -l root -f $hostfile broadcast put [ $SCRIPT_BRIDGE ] [ /tmp ] 1>/dev/null && \
taktuk -s -n -l root -f $hostfile broadcast exec [ /tmp/`basename $SCRIPT_BRIDGE` $USER kavlan-`kavlan -V` ] 1>/dev/null && \
taktuk -s -n -l root -f $hostfile broadcast exec [ rm -f $TMP_SSH_KEY ] 1>/dev/null

nodefile=`tempfile`
$SCRIPT_GENNODES ${network}/$NETWORK_CIDR -f $hostfile -n $nbkvms > $nodefile
taktuk -s -n -l root -f $hostfile broadcast exec [ rm -f /tmp/`basename $SCRIPT_LAUNCH` ] 1>/dev/null && \
taktuk -s -n -l root -f $hostfile broadcast put [ $SCRIPT_LAUNCH ] [ /tmp ] 1>/dev/null && \
taktuk -s -n -l root -f $hostfile broadcast exec [ cat - \| /tmp/`basename $SCRIPT_LAUNCH` ] \; broadcast input file [ $nodefile ] 1>/dev/null && \
taktuk -s -n -l root -f $hostfile broadcast exec [ 'test $(ps aux | grep kvm | grep -v grep | grep SCREEN | wc -l) -eq $nbkvms || cat - \| i'"/tmp/`basename $SCRIPT_LAUNCH`" ] \; broadcast input file [ $nodefile ] 1>/dev/null

cat $nodefile
rm $nodefile

if [ -n "$tmphostfile" ]
then
  rm $hostfile
fi

echo "Kadeploy daemon: `kavlan -l | sort -n | head -n 1` (dont forget to use -d option with the bootstrap script)" >&2
