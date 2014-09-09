#/bin/bash

grep -v node- /etc/hosts > /tmp/host2
mv /tmp/host2 /etc/hosts
for i in $(seq 1 254)
do
  /bin/echo "127.0.2.$i node-$i" >> /etc/hosts
done
