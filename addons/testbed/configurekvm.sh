#!/bin/bash

BW_PER_WWW=120
NETWORK_CIDR=20

TMP_DIR="${HOME}/.kabootstrapfiles"

SSH_KEY=~/.ssh/id_rsa
TMP_SSH_KEY=/tmp/identity

SCRIPT_BRIDGE=./setupkvmbridge
SCRIPT_LAUNCH=./launchkvms
SCRIPT_GENNODES=./genkvmnodefile

SSH_CONNECTOR='ssh -A -q -o ConnectTimeout=8 -o SetupTimeOut=16 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o PreferredAuthentications=publickey'
TAKTUK_OUTPUT='"$host: $line\n"'
TAKTUK_OPTIONS="-s -n -l root -o status -R connector=2 -R error=2"

if [ $# -lt 2 ]
then
  echo "usage: $0 <nb_kvm_per_host> <hostlist> [<www_server_nb>]" >&2
  exit 1
fi

nbkvms=$1

if [ -e $2 ]
then
  hosts="`cat $2`"
else
  echo file not found $2 >&2
  exit 1
fi

nbnodes=`echo "$hosts" | wc -l`

if [ $# -ge 3 ] && [ $3 -gt 0 ]
then
  tmp=$3
  let nbservers=tmp+3
else
  let nbservers=nbnodes/BW_PER_WWW+4
fi

rm -Rf $TMP_DIR
mkdir -p $TMP_DIR

kadaemon=`echo "$hosts" | sed -n '1p'`
dnsdaemon=`echo "$hosts" | sed -n '2p'`
dhcpdaemon=`echo "$hosts" | sed -n '3p'`
wwwservers=`echo "$hosts" | head -n $nbservers | sed -e '1,3d'`

network=`dig +short $kadaemon`
if [ $? -ne 0 ]
then
  echo 'Failed to get network' >&2
  exit 1
fi

hostfile=${TMP_DIR}/hostfile
echo "$hosts" | sed -e "1,${nbservers}d" > $hostfile

wwwfile=${TMP_DIR}/wwwfile
echo "$wwwservers" > $wwwfile

nbhosts=`cat $hostfile | wc -l`
if [ $nbhosts -le 0 ]
then
  echo 'No nodes left to host VMs' >&2
  exit 1
fi


echo "Configuring `cat $hostfile | wc -l` nodes" >&2
echo "" >&2

echo "Configuring ssh agent" >&2
sagentfile=`tempfile`
ssh-agent > $sagentfile
source $sagentfile 1>/dev/null
ssh-add $SSH_KEY &>/dev/null
echo "" >&2

echo 'Copying ssh key and script files' >&2
stime=`date +%s`
taktuk $TAKTUK_OPTIONS -o default="$TAKTUK_OUTPUT" -c "$SSH_CONNECTOR" -f $hostfile broadcast put [ $SSH_KEY ] [ $TMP_SSH_KEY ] \; broadcast put [ $SCRIPT_LAUNCH ] [ /tmp ] \; broadcast put [ $SCRIPT_BRIDGE ] [ /tmp ] 2>&1 | grep -v Warning >&2

let stime=`date +%s`-stime
echo "... done in ${stime} seconds" >&2


echo 'Configuring bridges' >&2
stime=`date +%s`
taktuk $TAKTUK_OPTIONS -o default="$TAKTUK_OUTPUT" -c "$SSH_CONNECTOR" -f $hostfile broadcast exec [ /tmp/`basename $SCRIPT_BRIDGE` ] 2>&1 | grep -v Warning >&2

let stime=`date +%s`-stime
echo "... done in ${stime} seconds" >&2

exclfile=`tempfile`
echo "$hosts" | sed -n "1,${nbservers}p" > $exclfile

echo 'Creating nodefile' >&2
nodefile=${TMP_DIR}/nodefile
$SCRIPT_GENNODES ${network}/$NETWORK_CIDR -f $hostfile -e $exclfile -n $nbkvms > $nodefile

rm $exclfile

if [ $? -ne 0 ]
then
  echo '  Failed!' >&2
  exit 1
else
  echo '... done' >&2
fi

echo 'Launching KVMS' >&2
stime=`date +%s`
taktuk $TAKTUK_OPTIONS -o default="$TAKTUK_OUTPUT" -c "$SSH_CONNECTOR" -f $hostfile broadcast exec [ cat - \| /tmp/`basename $SCRIPT_LAUNCH` ] \; broadcast input file [ $nodefile ] 2>&1 | grep -v Warning >&2

let stime=`date +%s`-stime
echo "... done in ${stime} seconds" >&2

cat $nodefile

echo "" >&2
echo "Cleaning temporary files" >&2

#rm $nodefile
#rm $hostfile
#rm $wwwfile

ssh-agent -k 1>/dev/null
rm $sagentfile
echo "" >&2

echo "Kadeploy node: $kadaemon" >&2
echo "DNS node: $dnsdaemon" >&2
echo "DHCP node: $dhcpdaemon" >&2
echo "www nodes:" >&2
echo "$wwwservers" >&2

echo "kabootstrap options: -V -d $kadaemon -a $dnsdaemon -b $dhcpdaemon -w $wwwfile -f $nodefile -F $hostfile" >&2
