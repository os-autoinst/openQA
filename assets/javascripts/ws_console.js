// jshint esversion: 6

let wsUrl;
let wsUsingProxy;
let wsProxyConnectionConcluded;
let stashedCommands = [];
let ws;
let $logElement;
let $followLogCheckBox;

function followLog() {
  if (!$followLogCheckBox.prop('checked')) {
    return;
  }
  $logElement[0].scrollTop = $logElement[0].scrollHeight;
}

function logLine(msg) {
  $logElement.append(document.createTextNode('<== ' + msg + '\n'));
  followLog();
}

function sendAndLogCommand(wsConnection, command) {
  wsConnection.send(command);
  $logElement.append(document.createTextNode('==> ' + command + '\n'));
  followLog();
}

function logStatus(msg) {
  $logElement.append('status: ' + msg + '\n');
  followLog();
}

function replayStashedCommands(wsConnection) {
  if (stashedCommands.length < 1) {
    return;
  }

  logStatus('replaying commands stashed while offline');
  for (let i = 0, count = stashedCommands.length; i !== count; ++i) {
    sendAndLogCommand(wsConnection, stashedCommands[i]);
  }
  stashedCommands = [];
}

function establishWebSocketConnection() {
  ws = new WebSocket(wsUrl);
  logStatus('Connecting to ' + wsUrl);
  logStatus('Using proxy: ' + (wsUsingProxy ? 'yes' : 'no'));
  ws.onopen = function () {
    logStatus('Connection opened');

    if (!wsUsingProxy) {
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
    ws = undefined;
    wsProxyConnectionConcluded = false;
    setTimeout(function () {
      establishWebSocketConnection();
    }, 500);
  };
  ws.onmessage = function (msg) {
    let proxyConnectionConcluded = false;
    try {
      const msgObj = JSON.parse(msg.data);
      const what = msgObj.what;
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
      wsProxyConnectionConcluded = true;
      sendAndLogCommand(ws, '{"cmd":"status"}');
      replayStashedCommands(ws);
    }
  };
}

function submitWebSocketCommand(event) {
  if (event) {
    event.preventDefault();
  }
  const msgInput = document.getElementById('msg');
  const command = msgInput.value;
  if (!ws || (wsUsingProxy && !wsProxyConnectionConcluded)) {
    logStatus("Can't send command, no ws connection opened! Will try to send when connection has been restored.");
    stashedCommands.push(command);
  } else {
    sendAndLogCommand(ws, command);
  }
  msgInput.value = '';
}

function setupWebSocketConsole() {
  // determine ws URL
  const form = $('#ws_console_form');
  let url = form.data('url');
  if (!url || !url.length) {
    return;
  }
  url = makeWsUrlAbsolute(url, form.data('service-port-delta'));

  // establish and handle web socket connection
  wsUrl = url;
  wsUsingProxy = form.data('using-proxy');
  wsProxyConnectionConcluded = false;
  stashedCommands = [];
  $logElement = $('#log');
  $followLogCheckBox = $('#follow_log');
  establishWebSocketConnection();

  // send command when user presses return
  form.submit(submitWebSocketCommand);
  document.getElementById('msg').focus();
}

$(function () {
  if ($('#ws_console_form').length) {
    setupWebSocketConsole();
  }
});
