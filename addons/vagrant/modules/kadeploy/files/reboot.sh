#!/bin/bash
node=$1
gw=$(ip r list 0/0 | cut -d ' ' -f 3)
echo $node | nc $gw 25300
