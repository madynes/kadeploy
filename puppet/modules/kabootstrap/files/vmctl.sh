#!/bin/bash
# usage: vmctl.sh <reboot|on|off> <vm_name>
[ $# -eq 3 ] && exit 1
gw=$(ip r list 0/0 | cut -d ' ' -f 3)
# Test if the -q option is available (ugly)
if nc -q0 -z localhost 22 1>/dev/null 2>/dev/null
then
  echo $1 $2 | nc -q0 $gw 25300
else
  echo $1 $2 | nc $gw 25300
fi
