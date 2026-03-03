upstream webui {
    zone upstream_webui 128k;
    # never mark upstream as broken, just pass what it gives us to the client and let it decide
    server [::1]:9526 max_fails=0;
}

upstream websocket {
    server [::1]:9527;
}

upstream livehandler {
    server [::1]:9528;
}
