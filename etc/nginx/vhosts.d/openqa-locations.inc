root /usr/share/openqa/public;

client_max_body_size 0;

# The "client_body_buffer_size" value should usually be larger
# than the UPLOAD_CHUNK_SIZE used by openQA workers, so there is
# no excessive buffering to disk
client_body_buffer_size 2m;

# Default is exact which would need an exact match of Last-Modified
if_modified_since before;

## Optional faster assets downloads for large deployments
#location /assets {
#    alias /var/lib/openqa/share/factory;
#    tcp_nopush         on;
#    sendfile           on;
#    sendfile_max_chunk 1m;
#}
#
## Optional faster image downloads for large deployments
#location /image {
#    alias /var/lib/openqa/images;
#    tcp_nopush         on;
#    sendfile           on;
#    sendfile_max_chunk 1m;
#}

location /api/v1/ws/ {
    proxy_pass http://websocket;
    proxy_http_version 1.1;
    proxy_read_timeout 3600;
    proxy_send_timeout 3600;
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection "upgrade";
    proxy_set_header Host $host;
}

location /liveviewhandler/ {
    proxy_pass http://livehandler;
    proxy_http_version 1.1;
    proxy_read_timeout 3600;
    proxy_send_timeout 3600;
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection "upgrade";
    proxy_set_header Host $host;
}

location / {
    proxy_pass "http://webui";
    tcp_nodelay        on;
    proxy_read_timeout 900;
    proxy_send_timeout 900;
    proxy_set_header Host $host;
    proxy_set_header X-Forwarded-Host $host:$server_port;
    proxy_set_header X-Forwarded-Server $host;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
}
