#!/bin/bash
set -e

replicas_cfg=""
for i in $(seq "${OPENQA_WEBUI_REPLICAS:-2}"); do
  replicas_cfg="server webui_webui_$i:9526;$replicas_cfg"
done

reg="s/REPLICAS/$replicas_cfg/"
sed "$reg" /etc/nginx/nginx.conf.template > /etc/nginx/nginx.conf
echo 'NGINX configuration:'
cat /etc/nginx/nginx.conf

nginx -g "daemon off;"
