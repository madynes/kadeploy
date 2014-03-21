#!/bin/bash
while true
  do
    node=$(nc -l -p 25300)
    vmid=$(vboxmanage list runningvms|grep ${node}_|cut -f2 -d" "|tr -d "{}")
    vboxmanage controlvm $vmid reset
  done
