#!/bin/sh

# file node
nodesfile="/nodes.txt"

# connector
connector="ssh -i /root/.ssh/id_deploy -o StrictHostKeyChecking=no -q""

# named pipes
entry_pipe="/entry_pipe"
dest_pipe=$1


# me
# /!\ hostname -i adds spaces.... 
#myIP="$(hostname -i | sed "s/\ //g")"
myIP=`cat /etc/DukeLinux.ip`

# get the next node's IP
# /!\ BUG grep should add a $ to prevent mismatches (172.24.1.1 and 172.24.1.10)
nextIP=$(cat ${nodesfile} | grep -A1 ^${myIP}$ |grep -v ^${myIP}$)

if [ "$nextIP" = "" ]; then 
	echo "I am the last node" > /chain.log
	cat ${entry_pipe} >  ${dest_pipe} 
else 
	echo "passing everything to ${nextIP}" > /chain.log
	cat ${entry_pipe} | tee ${dest_pipe} | ${connector} -l root ${nextIP} "cat > ${entry_pipe}"
fi
