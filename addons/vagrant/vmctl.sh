#!/bin/bash
# usage: vmctl.sh <reboot|on|off> <vm_name>
[ $# -eq 3 ] && exit 1
gw=$(ip r list 0/0 | cut -d ' ' -f 3)
echo $1 $2 | nc -q0 $gw 25300
