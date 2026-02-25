upstream webui {
    zone upstream_webui 128k;
    # max_conns should match -w (worker/prefork count) in scripts/openqa-webui-daemon
    server [::1]:9526 max_conns=30;
}

upstream websocket {
    server [::1]:9527;
}

upstream livehandler {
    server [::1]:9528;
}
