#!/usr/bin/env bash
cd /root/memlab
for kind in fc ch qmicro q35; do
  for n in 1 5; do
    echo "=== $kind N=$n"; timeout 240 ./measure.sh $kind $n < /dev/null 2>&1
    sleep 5
  done
done
echo "=== ALL DONE"
