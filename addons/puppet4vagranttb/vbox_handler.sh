#!/bin/bash
while true
  do
    node=$(nc -l -p 25300)
    [ $? -ne 0 ] && exit 1
    vmid=$(vboxmanage list runningvms|grep ${node}_|cut -f2 -d" "|tr -d "{}")
    if [ -n "$vmid" ]
    then
      echo "--- reset $node"
      vboxmanage controlvm $vmid reset
    else # In case the VM is not running
      echo "--- start $node"
      vmid=$(vboxmanage list vms|grep ${node}_|cut -f2 -d" "|tr -d "{}")
      [ -z "$vmid" ] && echo "$node not found" && exit 1
      vboxmanage startvm $vmid --type headless
    fi
  done
