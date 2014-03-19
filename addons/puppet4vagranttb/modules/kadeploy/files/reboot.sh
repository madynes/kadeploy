#!/bin/bash
set -x
op=$1
node=$2
user=$3
gw=$(ip r list 0/0 | cut -d ' ' -f 3)
vmid=$(ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o PreferredAuthentications=publickey -i /etc/kadeploy3/keys/id_deploy $user@$gw "vboxmanage list runningvms|grep $node|cut -f2 -d\" \"|tr -d \"{}\"")
ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o PreferredAuthentications=publickey -i /etc/kadeploy3/keys/id_deploy $user@$gw "vboxmanage controlvm $vmid $op"
