#!/bin/bash
set -e

cp /usr/local/etc/haproxy/haproxy.cfg.template /usr/local/etc/haproxy/haproxy.cfg
for i in $(seq 2 $replicas); do
  echo "  server webui$i webui_webui_$i:9526" >>/usr/local/etc/haproxy/haproxy.cfg
done

/usr/local/sbin/haproxy -f /usr/local/etc/haproxy/haproxy.cfg

# Infinite wait to prevent early exit
sleep infinity
