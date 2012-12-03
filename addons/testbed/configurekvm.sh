#!/bin/bash

# Users VARS
KADEPLOY_FILES=~/kadeployfiles.yml
CONFIG_MIGRATION=~/kaconfig_migration
KERNELS_DIR=~/kernels-kvm
ENVS_DIR=~/envs-kvm

TMP_DIR="${HOME}/.kabootstrap"

SSH_KEY=~/.ssh/id_rsa
TMP_SSH_KEY=/tmp/identity

SCRIPT_CHECK=./checkkvms
SCRIPT_SERVICE=./setupserviceip
SCRIPT_BRIDGE=./setupkvmbridge
SCRIPT_LAUNCH=./launchkvms

SCRIPT_GETNETWORK=./getkvmnetwork
SCRIPT_GETSERVICES=./getservices
SCRIPT_GENNODES=./genkvmnodefile

HOSTS_CONF=config.yml

SSH_CONNECTOR='ssh -A -q -o ConnectTimeout=8 -o SetupTimeOut=16 -o ConnectionAttempts=3 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o PreferredAuthentications=publickey'
TAKTUK_OUTPUT='"$host: $line\n"'
TAKTUK_OPTIONS="-s -n -l root -o status -R connector=2 -R error=2"

if [ $# -lt 1 ]
then
  echo "usage: $0 <hostlist> [<network_addr>]"
  echo "  You can set env variables NB_DNS, NB_DHCP and NB_WWW to specify the number of nodes to use for this services (default: 1)"
  exit 1
fi

if [ -e $1 ]
then
  hosts="`cat $1`"
else
  echo file not found $1
  exit 1
fi

network=`g5k-subnets -ps`
if [ $? -ne 0 ] || [ -z "$network" ]
then
  echo 'Failed to get network'
  exit 1
fi

rm -Rf $TMP_DIR
mkdir -p $TMP_DIR

allfile=${TMP_DIR}/allfile
echo "$hosts" > $allfile

networkyamlfile=${TMP_DIR}/network.yml
$SCRIPT_GETNETWORK $network > $networkyamlfile

serviceyamlfile=${TMP_DIR}/service.yml
$SCRIPT_GETSERVICES $networkyamlfile $allfile > $serviceyamlfile

exclfile=`tempfile`
grep 'newip:' $serviceyamlfile | cut -d ':' -f 2 | tr -d ' ' > $exclfile

nbservers=`grep 'host:' $serviceyamlfile | wc -l`
servicefile=${TMP_DIR}/servicefile
echo "$hosts" | head -n $nbservers > $servicefile
hostfile=${TMP_DIR}/hostfile
echo "$hosts" | sed -e "1,${nbservers}d" > $hostfile


nbhosts=`cat $hostfile | wc -l`
if [ $nbhosts -le 0 ]
then
  echo 'No nodes left to host VMs'
  exit 1
fi


echo "Configuring ssh agent"
sagentfile=`tempfile`
ssh-agent > $sagentfile
source $sagentfile 1>/dev/null
ssh-add $SSH_KEY &>/dev/null
echo ""


echo 'Copying ssh key and script files'
stime=`date +%s`
taktuk $TAKTUK_OPTIONS -o default="$TAKTUK_OUTPUT" -c "$SSH_CONNECTOR" -f $hostfile broadcast put [ $SSH_KEY ] [ $TMP_SSH_KEY ] \; broadcast put [ $SCRIPT_LAUNCH ] [ /tmp ] \; broadcast put [ $SCRIPT_BRIDGE ] [ /tmp ] \; broadcast put [ $SCRIPT_CHECK ] [ /tmp ] 2>&1 | grep -v Warning
taktuk $TAKTUK_OPTIONS -o default="$TAKTUK_OUTPUT" -c "$SSH_CONNECTOR" -f $servicefile broadcast put [ $SCRIPT_SERVICE ] [ /tmp ] 2>&1 | grep -v Warning

let stime=`date +%s`-stime
echo "... done in ${stime} seconds"


echo ""
echo "Configuring `cat $servicefile | wc -l` service hosts"
stime=`date +%s`
taktuk $TAKTUK_OPTIONS -o default="$TAKTUK_OUTPUT" -c "$SSH_CONNECTOR" -f $servicefile broadcast exec [ cat - \| /tmp/`basename $SCRIPT_SERVICE` $network ] \; broadcast input file [ $serviceyamlfile ] 2>&1 | grep -v Warning

let stime=`date +%s`-stime
echo "... done in ${stime} seconds"



echo ""
echo "Configuring `cat $hostfile | wc -l` KVM hosts"


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


echo 'Creating nodefile'
nodefile=${TMP_DIR}/nodefile
addrfile=`tempfile`
g5k-subnets -im -o $addrfile
$SCRIPT_GENNODES $networkyamlfile -f $hostyamlfile -e $exclfile -a $addrfile > $nodefile

rm $exclfile
rm $addrfile

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

echo 'Checking every nodes'
stime=`date +%s`
taktuk $TAKTUK_OPTIONS -o default="$TAKTUK_OUTPUT" -c "$SSH_CONNECTOR" -f $allfile broadcast exec [ /bin/true ] 2>&1 | grep -v Warning

let stime=`date +%s`-stime
echo "... done in ${stime} seconds"

echo ""
echo "Cleaning temporary files"

ssh-agent -k 1>/dev/null
rm $sagentfile
echo ""

echo "Services:"
cat $serviceyamlfile | grep -v '\-\-\-' | grep -v 'newip:'
echo ""

if [ -n "$KADEPLOY_FILES" ]
then
	OPT_KADEPLOY="-u $KADEPLOY_FILES"
fi

if [ -n "$CONFIG_MIGRATION" ]
then
	OPT_MIGRATION="-j $CONFIG_MIGRATION"
fi

echo "kabootstrap options: -V -n $networkyamlfile -g `hostname` -s $serviceyamlfile -c dns.`hostname | cut -d '.' -f 2-` -f $nodefile -F $hostfile $OPT_KADEPLOY $OPT_MIGRATION --no-tunnels $KERNELS_DIR $ENVS_DIR"
