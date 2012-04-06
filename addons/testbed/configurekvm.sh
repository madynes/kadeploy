#!/bin/bash

BW_PER_WWW=120
NETWORK_DEFAULT_CIDR=20

TMP_DIR="${HOME}/.kabootstrap"

SSH_KEY=~/.ssh/id_rsa
TMP_SSH_KEY=/tmp/identity

SCRIPT_CHECK=./checkkvms
SCRIPT_SERVICE=./setupserviceip
SCRIPT_BRIDGE=./setupkvmbridge
SCRIPT_LAUNCH=./launchkvms

SCRIPT_GETNETWORK=./getkvmnetwork
SCRIPT_GETTESTBEDIP=./gettestbedip
SCRIPT_GENNODES=./genkvmnodefile

HOSTS_CONF=config.yml

SSH_CONNECTOR='ssh -A -q -o ConnectTimeout=8 -o SetupTimeOut=16 -o ConnectionAttempts=3 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o PreferredAuthentications=publickey'
TAKTUK_OUTPUT='"$host: $line\n"'
TAKTUK_OPTIONS="-s -n -l root -o status -R connector=2 -R error=2"

if [ $# -lt 1 ]
then
  echo "usage: $0 <hostlist> [<www_server_nb>] [<network_addr>]"
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

servicefile=${TMP_DIR}/servicefile
echo "$hosts" | head -n $nbservers > $servicefile

if [ $# -ge 3 ] && [ -n "$3" ]
then
  network=$3
  newnet=1
else
  network=`dig +short $kadaemon`/$NETWORK_DEFAULT_CIDR
  if [ $? -ne 0 ]
  then
    echo 'Failed to get network'
    exit 1
  fi
fi

exclfile=`tempfile`
serviceyamlfile=${TMP_DIR}/service.yml

networkyamlfile=${TMP_DIR}/network.yml
$SCRIPT_GETNETWORK $network > $networkyamlfile

serviceips=`$SCRIPT_GETTESTBEDIP $networkyamlfile $servicefile`

tmp=`echo $network | cut -d '/' -f 1`
tmp=`ruby -e "require 'ipaddr'; puts IPAddr.new('${tmp}').succ"`

echo '---' > $serviceyamlfile
echo 'kadeploy:' >> $serviceyamlfile
tmp=`echo "$serviceips" | grep $kadaemon`
echo "  host: `echo $tmp | cut -d ':' -f 1`" >> $serviceyamlfile

if [ -n "$newnet" ]
then
  ip=`echo $tmp | cut -d ':' -f 2`
  echo "  newip: $ip" >> $serviceyamlfile
  echo $ip >> $exclfile
else
  echo $kadaemon >> $exclfile
fi

echo 'dns:' >> $serviceyamlfile
tmp=`echo "$serviceips" | grep $dnsdaemon`
echo "  host: `echo $tmp | cut -d ':' -f 1`" >> $serviceyamlfile

if [ -n "$newnet" ]
then
  ip=`echo $tmp | cut -d ':' -f 2`
  echo "  newip: $ip" >> $serviceyamlfile
  echo $ip >> $exclfile
else
  echo $dnsdaemon >> $exclfile
fi

echo 'dhcp:' >> $serviceyamlfile
tmp=`echo "$serviceips" | grep $dhcpdaemon`
echo "  host: `echo $tmp | cut -d ':' -f 1`" >> $serviceyamlfile

if [ -n "$newnet" ]
then
  ip=`echo $tmp | cut -d ':' -f 2`
  echo "  newip: $ip" >> $serviceyamlfile
  echo $ip >> $exclfile
else
  echo $dhcpdaemon >> $exclfile
fi

echo 'www:' >> $serviceyamlfile
for wwwdaemon in `echo $wwwservers`
do
  tmp=`echo "$serviceips" | grep $wwwdaemon`
  echo "  - host: `echo $tmp | cut -d ':' -f 1`" >> $serviceyamlfile

  if [ -n "$newnet" ]
  then
    ip=`echo $tmp | cut -d ':' -f 2`
    echo "    newip: $ip" >> $serviceyamlfile
    echo $ip >> $exclfile
  else
    echo $wwwdaemon >> $exclfile
  fi
done

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


if [ -n "$newnet" ]
then
  echo ""
  echo "Configuring `cat $servicefile | wc -l` service hosts"
  stime=`date +%s`
  taktuk $TAKTUK_OPTIONS -o default="$TAKTUK_OUTPUT" -c "$SSH_CONNECTOR" -f $servicefile broadcast exec [ cat - \| /tmp/`basename $SCRIPT_SERVICE` $network ] \; broadcast input file [ $serviceyamlfile ] 2>&1 | grep -v Warning

  let stime=`date +%s`-stime
  echo "... done in ${stime} seconds"
fi


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
$SCRIPT_GENNODES $networkyamlfile -f $hostyamlfile -e $exclfile > $nodefile

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

echo "kabootstrap options: -V -n $networkyamlfile -g `hostname` -s $serviceyamlfile -c dns.`hostname | cut -d '.' -f 2-` -f $nodefile -F $hostfile"
else
