function followLog() {
    if (!document.followLogCheckBox.prop('checked')) {
        return;
    }
    document.logElement[0].scrollTop = document.logElement[0].scrollHeight;
}

function logLine(msg) {
    document.logElement.append(msg + "\n");
    followLog();
}

function establishWebSocketConnection() {
    var ws = new WebSocket(window.wsUrl);
    logLine('Connecting to ' + window.wsUrl);
    ws.onopen = function () {
        logLine('Connection opened');
        window.ws = ws;
        ws.send('{"cmd":"status"}');
    };
    ws.onerror = function(error) {
        logLine('Connection error: ' + error.type + " (check JavaScript console for details)");
    }
    ws.onclose = function() {
        logLine('Connection closed, trying to reconnect in 2 seconds');
        window.ws = undefined;
        setTimeout(function() {
            establishWebSocketConnection();
        }, 2000);
    }
    ws.onmessage = function(msg) {
        logLine(msg.data);
    };
}

function setupWebSocketConsole(url) {
    // determine ws URL
    var form = $('#ws_console_form');
    var url = form.data('url');
    if (!url.length) {
        return;
    }
    url = makeWsUrlAbsolute(url);

    // establish and handle web socket connection
    window.wsUrl = url;
    document.logElement = $('#log');
    document.followLogCheckBox = $('#follow_log');
    establishWebSocketConnection();

    // send command when user presses return
    var msg = $('#msg');
    form.submit(function(event) {
        if (!window.ws) {
            logLine("Can't send command, no ws connection opened!");
            return;
        }
        event.preventDefault();
        window.ws.send(msg.val());
        msg.val('');
    });
    msg.focus();
}
