#/bin/bash
for i in `seq 1 100`
  do
    /bin/echo "10.0.10.$((10+$i)) node-$i" >> /etc/hosts
  done
