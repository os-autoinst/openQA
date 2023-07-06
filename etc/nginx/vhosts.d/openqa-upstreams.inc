# The "max_conns" value should be identical to the maximum number of
# connections the webui is configured to handle concurrently
upstream webui {
    zone upstream_webui 64k;
    server [::1]:9526 max_conns=30;
}

upstream websocket {
    server [::1]:9527;
}

upstream livehandler {
    server [::1]:9528;
}
