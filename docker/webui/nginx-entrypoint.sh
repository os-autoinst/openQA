#!/bin/bash
set -e

replicas=""
for i in $(seq 2 $replicas); do
  replicas="server webui_webui_$i:9526;$replicas"
done

reg="s/REPLICAS/$replicas/"
sed "$reg" /etc/nginx/conf.d/default.conf.template > /etc/nginx/conf.d/default.conf

cat /etc/nginx/conf.d/default.conf

nginx -g "daemon off;"
