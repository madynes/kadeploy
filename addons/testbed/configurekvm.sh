#!/bin/bash

SSH_KEY=~/.ssh/id_rsa
TMP_SSH_KEY=/tmp/identity

SCRIPT_BRIDGE=./setupkvmbridge
SCRIPT_LAUNCH=./launchkvms
SCRIPT_GENNODES=./genkvmnodefile
SSH_OPTIONS='-q -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o PreferredAuthentications=publickey'

NETWORK_CIDR=20

if [ $# -lt 3 ]
then
  echo "usage: $0 <nb_kvm_per_host> <network_address> <hostlist>"
  exit 1
fi

nbkvms=$1
network=$2

if [ -e $3 ]
then
  hosts=`cat $3 | sort -n`
else
  echo file not found $3
  exit 1
fi

kadaemon=`echo "$hosts" | head -n 1`

#gwuser=$USER
#gwhost="kavlan-`kavlan -V`"

hostfile=`tempfile`
echo "$hosts" | sed -e '1d' > $hostfile


echo "Configuring `cat $hostfile | wc -l` nodes" >&2
echo "" >&2

echo "Configuring ssh agent" >&2
sagentfile=`tempfile`
ssh-agent > $sagentfile
source $sagentfile 1>/dev/null
ssh-add $SSH_KEY &>/dev/null
echo "" >&2

#gwhostfile=`ssh -A $SSH_OPTIONS ${gwuser}@$gwhost 'tempfile'`
#scp $hostfile ${gwuser}@${gwhost}:$gwhostfile

echo 'Copying ssh key and script files' >&2
stime=`date +%s`
taktuk -s -n -l root -c "ssh -A $SSH_OPTIONS" -f $hostfile broadcast put [ $SSH_KEY ] [ $TMP_SSH_KEY ] \; broadcast put [ $SCRIPT_LAUNCH ] [ /tmp ] \; broadcast put [ $SCRIPT_BRIDGE ] [ /tmp ] 1>/dev/null
#ssh -A $SSH_OPTIONS ${gwuser}@$gwhost "taktuk -s -n -l root -c 'ssh -A $SSH_OPTIONS' -f $gwhostfile broadcast put [ $SSH_KEY ] [ $TMP_SSH_KEY ] \; broadcast put [ $SCRIPT_LAUNCH ] [ /tmp ] \; broadcast put [ $SCRIPT_BRIDGE ] [ /tmp ] 1>/dev/null"
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
taktuk -s -n -l root -c "ssh -A $SSH_OPTIONS" -f $hostfile broadcast exec [ /tmp/`basename $SCRIPT_BRIDGE` ] 1>/dev/null
#ssh -A $SSH_OPTIONS ${gwuser}@$gwhost "taktuk -s -n -l root -c 'ssh -A $SSH_OPTIONS' -f $gwhostfile broadcast exec [ /tmp/`basename $SCRIPT_BRIDGE` ] 1>/dev/null"
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
#gwnodefile=`ssh -A $SSH_OPTIONS ${gwuser}@$gwhost 'tempfile'`
#scp $nodefile ${gwuser}@${gwhost}:$gwnodefile

if [ $? -ne 0 ]
then
  echo '  Failed!' >&2
  exit 1
else
  echo '... done' >&2
fi

echo 'Launching KVMS' >&2
stime=`date +%s`
taktuk -s -n -l root -c "ssh -A $SSH_OPTIONS" -f $hostfile broadcast exec [ cat - \| /tmp/`basename $SCRIPT_LAUNCH` ] \; broadcast input file [ $nodefile ] 1>/dev/null
#ssh -A $SSH_OPTIONS ${gwuser}@$gwhost "taktuk -s -n -l root -c 'ssh -A $SSH_OPTIONS' -f $gwhostfil broadcast exec [ cat - \| /tmp/`basename $SCRIPT_LAUNCH` ] \; broadcast input file [ $nodefile ] 1>/dev/null"
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

echo "" >&2
echo "Cleaning temporary files" >&2
rm $nodefile
#ssh -A $SSH_OPTIONS ${gwuser}@$gwhost "rm $gwnodefile"

rm $hostfile
#ssh -A $SSH_OPTIONS ${gwuser}@$gwhost "rm $gwhostfile"

ssh-agent -k 1>/dev/null
rm $sagentfile
echo "" >&2

echo "Kadeploy daemon: $kadaemon (dont forget to use -d option with the bootstrap script)" >&2

