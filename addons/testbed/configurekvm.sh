#!/bin/bash

BW_PER_WWW=120
NETWORK_CIDR=20

TMP_DIR="${HOME}/.kabootstrapfiles"

SSH_KEY=~/.ssh/id_rsa
TMP_SSH_KEY=/tmp/identity

SCRIPT_CHECK=./checkkvms
SCRIPT_BRIDGE=./setupkvmbridge
SCRIPT_LAUNCH=./launchkvms
SCRIPT_GENNODES=./genkvmnodefile

HOSTS_CONF=config.yml

SSH_CONNECTOR='ssh -A -q -o ConnectTimeout=8 -o SetupTimeOut=16 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o PreferredAuthentications=publickey'
TAKTUK_OUTPUT='"$host: $line\n"'
TAKTUK_OPTIONS="-s -n -l root -o status -R connector=2 -R error=2"

if [ $# -lt 1 ]
then
  echo "usage: $0 <hostlist> [<www_server_nb>]"
  exit 1
fi

if [ -e $1 ]
then
  hosts="`cat $1`"
else
  echo file not found $1
  exit 1
fi

nbnodes=`echo "$hosts" | wc -l`

if [ $# -ge 2 ] && [ $2 -gt 0 ]
then
  tmp=$2
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
  echo 'Failed to get network'
  exit 1
fi

hostfile=${TMP_DIR}/hostfile
echo "$hosts" | sed -e "1,${nbservers}d" > $hostfile

wwwfile=${TMP_DIR}/wwwfile
echo "$wwwservers" > $wwwfile

nbhosts=`cat $hostfile | wc -l`
if [ $nbhosts -le 0 ]
then
  echo 'No nodes left to host VMs'
  exit 1
fi


echo "Configuring `cat $hostfile | wc -l` nodes"
echo ""

echo "Configuring ssh agent"
sagentfile=`tempfile`
ssh-agent > $sagentfile
source $sagentfile 1>/dev/null
ssh-add $SSH_KEY &>/dev/null
echo ""


echo 'Copying ssh key and script files'
stime=`date +%s`
taktuk $TAKTUK_OPTIONS -o default="$TAKTUK_OUTPUT" -c "$SSH_CONNECTOR" -f $hostfile broadcast put [ $SSH_KEY ] [ $TMP_SSH_KEY ] \; broadcast put [ $SCRIPT_LAUNCH ] [ /tmp ] \; broadcast put [ $SCRIPT_BRIDGE ] [ /tmp ] \; broadcast put [ $SCRIPT_CHECK ] [ /tmp ] 2>&1 | grep -v Warning

let stime=`date +%s`-stime
echo "... done in ${stime} seconds"


echo 'Gathering nodes information'
hostyamlfile=${TMP_DIR}/$HOSTS_CONF
echo '---' > $hostyamlfile
stime=`date +%s`
taktuk $TAKTUK_OPTIONS -o default="$TAKTUK_OUTPUT" -c "$SSH_CONNECTOR" -f $hostfile broadcast exec [ /tmp/`basename $SCRIPT_CHECK` ] 2>&1 | grep -v Warning >> $hostyamlfile

let stime=`date +%s`-stime
echo "... done in ${stime} seconds"


echo 'Configuring bridges'
stime=`date +%s`
taktuk $TAKTUK_OPTIONS -o default="$TAKTUK_OUTPUT" -c "$SSH_CONNECTOR" -f $hostfile broadcast exec [ /tmp/`basename $SCRIPT_BRIDGE` ] 2>&1 | grep -v Warning

let stime=`date +%s`-stime
echo "... done in ${stime} seconds"

exclfile=`tempfile`
echo "$hosts" | sed -n "1,${nbservers}p" > $exclfile

echo 'Creating nodefile'
nodefile=${TMP_DIR}/nodefile
$SCRIPT_GENNODES ${network}/$NETWORK_CIDR -f $hostyamlfile -e $exclfile > $nodefile

rm $exclfile

if [ $? -ne 0 ]
then
  echo '  Failed!'
  exit 1
else
  echo '... done'
fi

echo 'Launching KVMS'
stime=`date +%s`
taktuk $TAKTUK_OPTIONS -o default="$TAKTUK_OUTPUT" -c "$SSH_CONNECTOR" -f $hostfile broadcast exec [ cat - \| /tmp/`basename $SCRIPT_LAUNCH` ] \; broadcast input file [ $nodefile ] 2>&1 | grep -v Warning

let stime=`date +%s`-stime
echo "... done in ${stime} seconds"

echo ""
echo "Cleaning temporary files"

#rm $nodefile
#rm $hostfile
#rm $wwwfile

ssh-agent -k 1>/dev/null
rm $sagentfile
echo ""

echo "Kadeploy node: $kadaemon"
echo "DNS node: $dnsdaemon"
echo "DHCP node: $dhcpdaemon"
echo "www nodes:"
echo "$wwwservers"

echo "kabootstrap options: -V -d $kadaemon -a $dnsdaemon -b $dhcpdaemon -w $wwwfile -f $nodefile -F $hostfile"
