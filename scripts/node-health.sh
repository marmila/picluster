#!/bin/bash
# Usage: ./node-health.sh <node-name>
# Example: ./node-health.sh node5

NODE=${1:-node5}

echo "=============================="
echo " Node Health Report: $NODE"
echo "=============================="

echo ""
echo "--- CPU / Memory / Load ---"
kubectl top node $NODE

echo ""
echo "--- Throttling Status ---"
kubectl debug node/$NODE -it --image=busybox --profile=general -- sh -c "
  STATUS=\$(cat /host/sys/devices/platform/soc/soc:firmware/raspberrypi-hwmon/hwmon/hwmon0/in0_lcrit_alarm 2>/dev/null || echo 'N/A')
  TEMP=\$(cat /host/sys/class/thermal/thermal_zone0/temp 2>/dev/null)
  echo \"Temperature: \$(echo \$TEMP | awk '{printf \"%.1f°C\", \$1/1000}')\"
" 2>/dev/null

echo ""
echo "--- Disk I/O Stats (sda) ---"
kubectl debug node/$NODE -it --image=busybox --profile=general -- sh -c "
  STAT=\$(cat /host/sys/block/sda/stat)
  READ_IOS=\$(echo \$STAT | awk '{print \$1}')
  READ_TICKS=\$(echo \$STAT | awk '{print \$4}')
  WRITE_IOS=\$(echo \$STAT | awk '{print \$5}')
  WRITE_TICKS=\$(echo \$STAT | awk '{print \$8}')
  echo \"Read  IOs: \$READ_IOS  |  Avg latency: \$(echo \$READ_TICKS \$READ_IOS | awk '{if(\$2>0) printf \"%.1fms\", \$1/\$2; else print \"N/A\"}')\"
  echo \"Write IOs: \$WRITE_IOS  |  Avg latency: \$(echo \$WRITE_TICKS \$WRITE_IOS | awk '{if(\$2>0) printf \"%.1fms\", \$1/\$2; else print \"N/A\"}')\"
" 2>/dev/null

echo ""
echo "--- Recent Kernel Errors (rcu/thermal/oom) ---"
kubectl debug node/$NODE -it --image=busybox --profile=general -- sh -c "
  grep -E 'rcu:.*stall|thermal|oom-kill|OOM|Under-voltage' /host/var/log/syslog | tail -10
" 2>/dev/null

echo ""
echo "--- Longhorn Replicas on $NODE ---"
kubectl get replicas.longhorn.io -n longhorn-system | grep $NODE | awk '{print $1, $3, $4}' | column -t

echo ""
echo "--- Pods on $NODE ---"
kubectl get pods -A --field-selector spec.nodeName=$NODE --sort-by=.metadata.namespace | grep -v "Completed"

echo ""
echo "--- Fluent Bit Status ---"
kubectl get pods -n fluent -o wide | grep $NODE

echo ""
echo "--- Node Conditions ---"
kubectl describe node $NODE | grep -A20 "Conditions:"
