#!/bin/bash
while true
  do
    tmp=$(nc -l -p 25300)
    op=$(echo $tmp | cut -f1 -d" ")
    node=$(echo $tmp | cut -f2 -d" ")
    [ $? -ne 0 ] && exit 1
    vmid=$(vboxmanage list runningvms|grep ${node}_|cut -f2 -d" "|tr -d "{}")
    if [ -n "$vmid" ]
    then
      case "$op" in
        'reset')
          echo "--- reset $node"
          vboxmanage controlvm $vmid reset
          ;;
        'off')
          echo "--- off $node"
          vboxmanage controlvm $vmid poweroff
          ;;
        *)
          echo "!!! ERROR #1 $node"
          ;;
      esac
    else  # In case the VM is not running
      vmid=$(vboxmanage list vms|grep ${node}_|cut -f2 -d" "|tr -d "{}")
      [ -z "$vmid" ] && echo "!!! ERROR #0 $node"
      case "$op" in
        'reset'|'on')
          echo "--- reset (start) $node"
          vboxmanage startvm $vmid --type headless
          ;;
        *)
          echo "!!! ERROR #2 $node"
          ;;
      esac
    fi
  done
