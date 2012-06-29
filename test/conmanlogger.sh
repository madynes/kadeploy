#!/bin/bash

#CONMAN_DETACH_STR="&."
CONMAN_BIN=/usr/local/conman/bin/conman
CONMAN_SERVER=conman


function get_nodename()
{
	echo ${1%%.*}
}

function get_screen_prefix()
{
	echo `basename $1 .sh`-$2
}

function get_screen_name()
{
	echo ${1}-$2
}

function get_logdir()
{
	echo `basename $1 .sh`.$2
}

function get_logfile()
{
	echo ${1}/${2}.conlog
}

function check_args()
{
	if [ $# -lt 3 ]
	then
		echo "usage: $0 <start/stop> <nodefile> <run_id> [<logsdir>]"
		exit 1
	fi

	if [ -e $3 ]
	then
		nodes=`uniq $3`
	else
		echo "file not found '$3'"
		exit 1
	fi

	if [ $# -ge 4 ]
	then
		logdir=$4
	else
		logdir=$(get_logdir $0 $run_id)
	fi
}

function init_logs()
{
	echo "Creating logs directory '$1'"
	if [ -e "$1" ]
	then
		if [ -n "$(ls -A $1)" ]
		then
			echo "Backup logs directory"
			mkdir -p ${1}/bak
			mv $1/* ${1}/bak &>/dev/null
		fi
	else
		mkdir -p $1
	fi
}

function gz_log()
{
	local file=$(get_logfile $1 $2)
	if [ -e $file ]
	then
		gzip $file
	fi
}

function init_screen()
{
	echo -e "\t init $1"
	screen -d -m -S $1
	#screen -S $screen_name -X logfile ${logdir}/$screen_name
	#screen -S $screen_name -X logfile flush 1
	#screen -S $screen_name -X logtstamp on
	#screen -S $screen_name -X logtstamp after 10
	#screen -S $screen_name -X deflog on
	screen -S $1 -X screen $CONMAN_BIN -d $CONMAN_SERVER \
		-l $(get_logfile $3 $2) $2
}

function kill_screen()
{
		echo -e "\t kill $1"
		#screen -S $screen_name -X stuff "&."
		screen -S $1 -X quit
}


### Start

check_args $@
run_id=$2

case "$1" in
start)

	init_logs $logdir
	echo "Initialize screens"
	for n in $nodes
	do
		node_name=$(get_nodename $n)
		screen_prefix=$(get_screen_prefix $0 $n)
		screen_name=$(get_screen_name $screen_prefix $run_id)

		if screen -list | grep $screen_prefix &>/dev/null
		then
			kill_screen $screen_prefix
		fi
		init_screen $screen_name $node_name $logdir
	done

	echo "Start monitoring"
	;;
stop)
	echo "Kill screens"
	for n in $nodes
	do
		node_name=$(get_nodename $n)
		screen_prefix=$(get_screen_prefix $0 $n)
		screen_name=$(get_screen_name $screen_prefix $run_id)
		kill_screen $screen_prefix
		gz_log $logdir $node_name
	done

	echo "Stop monitoring"
	;;
*)
	echo "unknown command '$1'"
	;;
esac
