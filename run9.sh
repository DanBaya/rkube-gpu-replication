#!/bin/bash
set -e
CG=/sys/fs/cgroup/rkube.slice
docker rm -f target nb1 nb2 nb3 2>/dev/null || true

docker run -d --name target --cgroup-parent=rkube.slice \
  polinux/stress-ng stress-ng --cpu 24 --timeout 1800s --metrics-brief
for i in 1 2 3; do
  docker run -d --name nb$i --cgroup-parent=rkube.slice \
    polinux/stress-ng stress-ng --cpu 24 --timeout 1800s
done
sleep 5

T=$CG/docker-$(docker inspect -f '{{.Id}}' target).scope
echo 100 | sudo tee $T/cpu.weight >/dev/null
for i in 1 2 3; do
  N=$CG/docker-$(docker inspect -f '{{.Id}}' nb$i).scope
  echo 33 | sudo tee $N/cpu.weight >/dev/null
done

echo "verify: weight=$(cat $T/cpu.weight) max=$(cat $T/cpu.max)"
echo "trial,delivered_cpus,ratio,nr_throttled" > results_weight_9trials.csv

for i in $(seq 1 9); do
  u1=$(awk '/usage_usec/{print $2}' $T/cpu.stat); w1=$(date +%s%6N)
  sleep 60
  u2=$(awk '/usage_usec/{print $2}' $T/cpu.stat); w2=$(date +%s%6N)
  d=$(echo "scale=4;($u2-$u1)/($w2-$w1)"|bc)
  r=$(echo "scale=4;$d/12.06"|bc)
  t=$(awk '/nr_throttled/{print $2}' $T/cpu.stat)
  echo "$i,$d,$r,$t" | tee -a results_weight_9trials.csv
done
