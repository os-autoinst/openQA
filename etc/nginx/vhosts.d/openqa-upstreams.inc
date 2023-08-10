upstream webui {
    zone upstream_webui 64k;
    server [::1]:9526;
}

upstream websocket {
    server [::1]:9527;
}

upstream livehandler {
    server [::1]:9528;
}
