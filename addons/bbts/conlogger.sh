#!/bin/bash

#CONMAN_DETACH_STR="&."
CONSOLE_BIN=/usr/local/conman/bin/conman
CONSOLE_CMD="$CONSOLE_BIN -f -d conman"
SCRIPT_BIN=/usr/bin/script


function get_nodename()
{
  echo ${1%%.*}
}

function get_session_name()
{
  echo `basename $1 .sh`-$2
}

function get_session_file()
{
  echo ${1}/.SESSION
}

function get_logdir()
{
  echo `basename $1 .sh`.$2
}

function get_typefile()
{
  echo ${1}/${2}.typescript
}

function get_timefile()
{
  echo ${1}/${2}.timing
}

function check_args()
{
  if [ $# -lt 3 ]
  then
    echo "usage: $0 <start/stop> <run_id> <nodefile> [<logsdir>]"
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
  local file=$(get_typefile $1 $2)
  if [ -e $file ]
  then
    gzip $file
  fi
}

function gz_time()
{
  local file=$(get_timefile $1 $2)
  if [ -e $file ]
  then
    gzip $file
  fi
}

function init_monitor()
{
  echo -e "\t init $1"
  $SCRIPT_BIN -f -c "$CONSOLE_CMD $1" \
    -t 2>$(get_timefile $2 $1) -a $(get_typefile $2 $1) 1>/dev/null &
  echo "$1 $!" >> $3
}

function kill_monitor()
{
  #ppid=$(sed -n "s/^$1 \([0-9]\+\)$/\1/p" $2)
  ppid=$(ps -u $USER -o pid= -o command= | grep "^[[:space:]]*[0-9]\+[[:space:]]\+$SCRIPT_BIN" | grep $CONSOLE_BIN | grep $(get_typefile $2 $1) | awk '{print $1}')
  if [ -n "$ppid" ]
  then
    pids=()
    for pid in `ps --ppid $ppid -o pid=`
    do
      pids+=($pid)
    done
    echo -e "\t kill $1 ($ppid $pids)"
    kill $pids $ppid
  fi
}


### Start

run_id=$2
check_args $@
session_name=$(get_session_name $run_id)
session_file=$(get_session_file $logdir)

case "$1" in
start)
  init_logs $logdir
  echo "Initialize monitors"
  for n in $nodes
  do
    node_name=$(get_nodename $n)
    init_monitor $node_name $logdir $session_file
  done

  echo "Start monitoring"
  ;;
stop)
  if [ -e $session_file ]
  then
    echo "Kill monitors"
    for n in $nodes
    do
      node_name=$(get_nodename $n)
      kill_monitor $node_name $logdir
      gz_log $logdir $node_name
      gz_time $logdir $node_name
    done
    rm -f $session_file

    echo "Stop monitoring"
  else
    echo "Session is already stopped"
  fi
  ;;
*)
  echo "unknown command '$1'"
  ;;
esac
