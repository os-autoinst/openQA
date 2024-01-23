function followLog() {
  if (!document.followLogCheckBox.prop('checked')) {
    return;
  }
  document.logElement[0].scrollTop = document.logElement[0].scrollHeight;
}

function logLine(msg) {
  document.logElement.append('<== ' + msg + '\n');
  followLog();
}

function sendAndLogCommand(ws, command) {
  ws.send(command);
  document.logElement.append('==> ' + command + '\n');
  followLog();
}

function logStatus(msg) {
  document.logElement.append('status: ' + msg + '\n');
  followLog();
}

function replayStashedCommands(ws) {
  var stashedCommands = window.stashedCommands;
  if (stashedCommands.length < 1) {
    return;
  }

  logStatus('replaying commands stashed while offline');
  for (var i = 0, count = stashedCommands.length; i != count; ++i) {
    sendAndLogCommand(ws, stashedCommands[i]);
  }
  window.stashedCommands = [];
}

function establishWebSocketConnection() {
  var ws = new WebSocket(window.wsUrl);
  logStatus('Connecting to ' + window.wsUrl);
  logStatus('Using proxy: ' + (window.wsUsingProxy ? 'yes' : 'no'));
  ws.onopen = function () {
    logStatus('Connection opened');
    window.ws = ws;

    if (!window.wsUsingProxy) {
      // request current status like the developer mode would do
      sendAndLogCommand(ws, '{"cmd":"status"}');
      // replay commands stashed while offline if connecting directly to isotovideo
      replayStashedCommands(ws);
    }
  };
  ws.onerror = function (error) {
    logStatus('Connection error: ' + error.type + ' (check JavaScript console for details)');
  };
  ws.onclose = function () {
    logStatus('Connection closed, trying to reconnect in 500 ms');
    window.ws = undefined;
    window.wsProxyConnectionConcluded = false;
    setTimeout(function () {
      establishWebSocketConnection();
    }, 500);
  };
  ws.onmessage = function (msg) {
    var proxyConnectionConcluded = false;
    try {
      var msgObj = JSON.parse(msg.data);
      var what = msgObj.what;
      proxyConnectionConcluded =
        typeof what === 'string' &&
        (what.indexOf('connected to os-autoinst command server') >= 0 ||
          what.indexOf('reusing previous connection to os-autoinst command server') >= 0);
    } catch (e) {
      logStatus('Unable to process received message: ' + e);
    }
    logLine(msg.data);

    if (proxyConnectionConcluded) {
      logStatus('tunnelled connection to os-autoinst concluded');
      window.wsProxyConnectionConcluded = true;
      sendAndLogCommand(ws, '{"cmd":"status"}');
      replayStashedCommands(ws);
    }
  };
}

function submitWebSocketCommand(event) {
  if (event) {
    event.preventDefault();
  }
  var msg = document.getElementById('msg');
  var command = msg.value;
  if (!window.ws || (window.wsUsingProxy && !window.wsProxyConnectionConcluded)) {
    logStatus("Can't send command, no ws connection opened! Will try to send when connection has been restored.");
    window.stashedCommands.push(command);
  } else {
    sendAndLogCommand(window.ws, command);
  }
  msg.value = '';
}

function setupWebSocketConsole() {
  // determine ws URL
  var form = $('#ws_console_form');
  var url = form.data('url');
  if (!url.length) {
    return;
  }
  url = makeWsUrlAbsolute(url, form.data('service-port-delta'));

  // establish and handle web socket connection
  window.wsUrl = url;
  window.wsUsingProxy = form.data('using-proxy');
  window.wsProxyConnectionConcluded = false;
  window.stashedCommands = [];
  document.logElement = $('#log');
  document.followLogCheckBox = $('#follow_log');
  establishWebSocketConnection();

  // send command when user presses return
  form.submit(submitWebSocketCommand);
  document.getElementById('msg').focus();
}
