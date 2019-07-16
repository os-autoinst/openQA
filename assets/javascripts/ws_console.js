function followLog() {
    if (!document.followLogCheckBox.prop('checked')) {
        return;
    }
    document.logElement[0].scrollTop = document.logElement[0].scrollHeight;
}

function logLine(msg) {
    document.logElement.append("<== " + msg + "\n");
    followLog();
}

function logEnteredCommand(command) {
    document.logElement.append("==> " + command + "\n");
    followLog();
}

function establishWebSocketConnection() {
    var ws = new WebSocket(window.wsUrl);
    logLine('Connecting to ' + window.wsUrl);
    ws.onopen = function () {
        logLine('Connection opened');
        window.ws = ws;

        // request current status like the developer mode would do
        ws.send('{"cmd":"status"}');

        // replay commands stashed while offline
        var stashedCommands = window.stashedCommands;
        for (var i = 0, count = stashedCommands.length; i != count; ++i) {
            var command = stashedCommands[i];
            ws.send(command);
            logEnteredCommand(command);
        }
        window.stashedCommands = [];
    };
    ws.onerror = function(error) {
        logLine('Connection error: ' + error.type + " (check JavaScript console for details)");
    };
    ws.onclose = function() {
        logLine('Connection closed, trying to reconnect in 2 seconds');
        window.ws = undefined;
        setTimeout(function() {
            establishWebSocketConnection();
        }, 2000);
    };
    ws.onmessage = function(msg) {
        logLine(msg.data);
    };
}

function setupWebSocketConsole(url) {
    // determine ws URL
    var form = $('#ws_console_form');
    url = form.data('url');
    if (!url.length) {
        return;
    }
    url = makeWsUrlAbsolute(url);

    // establish and handle web socket connection
    window.wsUrl = url;
    window.stashedCommands = [];
    document.logElement = $('#log');
    document.followLogCheckBox = $('#follow_log');
    establishWebSocketConnection();

    // send command when user presses return
    var msg = $('#msg');
    form.submit(function(event) {
        event.preventDefault();

        var command = msg.val();
        if (!window.ws) {
            logLine("Can't send command, no ws connection opened! Will try to send when connection has been restored.");
            window.stashedCommands.push(command);
        } else {
            window.ws.send(command);
            logEnteredCommand(command);
        }

        msg.val('');
    });
    msg.focus();
}
