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
    hosts=`cat $2 | sort -n`
  else
    echo file not found $2
    exit 1
  fi
else
  hosts=`kavlan -l | sort -n`
fi

kadaemon=`echo "$hosts" | head -n 1`
network=`dig +short $kadaemon`

hostfile=`tempfile`
echo "$hosts" | sed -e '1d' > $hostfile


echo "Configuring `cat $hostfile | wc -l` nodes" >&2
echo "" >&2

echo 'Copying ssh key and script files' >&2
stime=`date +%s`
taktuk -s -n -l root -f $hostfile broadcast put [ $SSH_KEY ] [ $TMP_SSH_KEY ] \; broadcast put [ $SCRIPT_LAUNCH ] [ /tmp ] \; broadcast put [ $SCRIPT_BRIDGE ] [ /tmp ] 1>/dev/null
let stime=`date +%s`-stime

if [ $? -ne 0 ]
then
  echo '  Failed!' >&2
  exit 1
else
  echo "... done in ${stime} seconds" >&2
fi

echo 'Configuring bridges' >&2
stime=`date +%s`
taktuk -s -n -l root -f $hostfile broadcast exec [ /tmp/`basename $SCRIPT_BRIDGE` $USER kavlan-`kavlan -V` ] 1>/dev/null && \
let stime=`date +%s`-stime

if [ $? -ne 0 ]
then
  echo '  Failed!' >&2
  exit 1
else
  echo "... done in ${stime} seconds" >&2
fi

echo 'Creating nodefile' >&2
nodefile=`tempfile`
$SCRIPT_GENNODES ${network}/$NETWORK_CIDR -f $hostfile -n $nbkvms > $nodefile

if [ $? -ne 0 ]
then
  echo '  Failed!' >&2
  exit 1
else
  echo '... done' >&2
fi

echo 'Launching KVMS' >&2
stime=`date +%s`
taktuk -s -n -l root -f $hostfile broadcast exec [ cat - \| /tmp/`basename $SCRIPT_LAUNCH` ] \; broadcast input file [ $nodefile ] 1>/dev/null && \
let stime=`date +%s`-stime

if [ $? -ne 0 ]
then
  echo '  Failed!' >&2
  exit 1
else
  echo "... done in ${stime} seconds" >&2
fi
#taktuk -s -n -l root -f $hostfile broadcast exec [ 'test $(ps aux | grep kvm | grep -v grep | grep SCREEN | wc -l) -eq $nbkvms || cat - \| i'"/tmp/`basename $SCRIPT_LAUNCH`" ] \; broadcast input file [ $nodefile ] 1>/dev/null

cat $nodefile
rm $nodefile

rm $hostfile

echo "" >&2
echo "Kadeploy daemon: $kadaemon (dont forget to use -d option with the bootstrap script)" >&2

