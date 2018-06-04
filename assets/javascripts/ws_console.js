function setupWebSocketContosle(url) {
    var form = $('#ws_console_form');
    var url = form.data('url');
    if (!url.length) {
        return;
    }

    // handle relative URL
    if (url.indexOf('ws:') !== 0) {
        var port = Number.parseInt(window.location.port);
        if (port !== 80 || port !== 443) {
            port += 2;
        }
        url = 'ws://' + window.location.hostname + ':' + port + (url.indexOf('/') !== 0 ? '/' : '') + url;
    }

    var msg = $('#msg');
    var log = $('#log');
    var followLogCheckBox = $('#follow_log');

    // setup logging
    var followLog = function() {
        if (!followLogCheckBox.prop('checked')) {
            return;
        }
        log[0].scrollTop = log[0].scrollHeight;
    };
    followLogCheckBox.change(followLog);
    var logLine = function(msg) {
        log.append(msg + "\n");
        followLog();
    };

    // establish and handle web socket connection
    var ws = new WebSocket(url);
    logLine('Connecting to ' + url);
    ws.onopen = function () {
        logLine('Connection opened');
    };
    ws.onerror = function(error) {
        logLine('Connection error: ' + error.type + " (check JavaScript console for details)");
    }
    ws.onclose = function() {
        logLine('Connection closed');
    }
    ws.onmessage = function(msg) {
        logLine(msg.data);
    };

    // send command when user presses return
    form.submit(function(event) {
        event.preventDefault();
        ws.send(msg.val());
        msg.val('');
    });
    msg.focus();
}
