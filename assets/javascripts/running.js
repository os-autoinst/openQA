var testStatus = {
    modlist_initialized: 0,
    jobid: null,
    running: null,
    workerid: null,
    status_url: null,
    details_url: null,
    img_reload_time: 0
};

// holds elements relevant for live stream, live log and serial output
// (populated in initLivelogAndTerminal() and initLivestream())
var liveViewElements = [];

// holds elements relevant for live log and serial output
// (initialized in initLivelogAndTerminal())
var logElements;

// Update global variable testStatus
function updateTestStatus(newStatus) {
    if (newStatus.state != 'running') {
        setTimeout(function() {location.reload();}, 2000);
        return;
    }
    testStatus.workerid = newStatus.workerid;

    // Reload broken thumbnails (that didn't exist yet when being requested) every 7 sec
    if (testStatus.img_reload_time++ % 7 == 0) {
        $(".links img").each(function() {
            if (this.naturalWidth < 1) {
                if (!this.retries) {
                    this.retries = 0;
                }
                if (this.retries <= 3) {
                    this.retries++;
                    this.src = this.src.split("?")[0]+"?"+Date.now();
                }
            }
        });
    }

    // If a new module have been started, redraw module list
    if (testStatus.running != newStatus.running) {
        $.ajax(testStatus.details_url).
            done(function(data) {
                if (data.length > 0) {
                    // the result table must have a running row
                    if ($(data).find('.resultrunning').length > 0) {
                        // results table doesn't exist yet
                        if ($("#results").length == 0) {
                            $("#details").html(data);
                            console.log("Missing results table created");
                            testStatus.running = newStatus.running;
                        }
                        else {
                            var running_tr = $('td.result.resultrunning').parent();
                            var result_tbody = running_tr.parent();
                            var first_tr_to_update = running_tr.index();
                            var new_trs = $(data).find("tbody > tr");
                            var printed_running = false;
                            var missing_results = false;
                            result_tbody.children().slice(first_tr_to_update).each(function() {
                                var tr = $(this);
                                var new_tr = new_trs.eq(tr.index());
                                if (new_tr.find('.resultrunning').length == 1) {
                                    printed_running = true;
                                }
                                // every row above running must have results
                                if (!printed_running && new_tr.find('.links').length > 0 && new_tr.find('.links').children().length == 0) {
                                    missing_results = true;
                                    console.log("Missing results in row - trying again");
                                }
                            });
                            if (!missing_results) {
                                result_tbody.children().slice(first_tr_to_update).each(function() {
                                    var tr = $(this);
                                    tr.replaceWith(new_trs.eq(tr.index()));
                                });
                                testStatus.running = newStatus.running;
                            }
                        }
                    }
                } else {
                    console.log("ERROR: modlist empty");
                }
            }).fail(function() {
                console.log("ERROR: modlist fail");
            });
    }
}

function sendCommand(command) {
    var wid = testStatus.workerid;
    if (wid == null) return false;
    var url = $('#canholder').data('url').replace('WORKERID', wid);
    $.ajax({url: url,
            type: 'POST',
            data: { command: command },
            success: function(resp) {
                setTimeout("updateStatus()", 0);
            }});
}

function updateStatus() {
    $.ajax(testStatus.status_url).
        done(function(status) {
            updateTestStatus(status);
            setTimeout("updateStatus()", 5000);
        }).fail(function() {
            setTimeout(function() {location.reload();}, 5000);
        });
}

function initStatus(jobid, status_url, details_url) {
    testStatus.jobid = jobid;
    testStatus.status_url = status_url;
    testStatus.details_url = details_url;
    updateStatus();
}

/********* LIVE LOG *********/

// global vars for livelog
var scrolldown;

// checkbox callback
function setScrolldown() {
    scrolldown = $(this).prop('checked');
    scrollToBottomOfLiveLog();
}

// scrolls to bottom of live log (if enabled)
function scrollToBottomOfLiveLog() {
    var livelog = $('#livelog')[0];
    if (scrolldown) {
        livelog.scrollTop = livelog.scrollHeight;
    }
}

function removeDataListener(elem) {
    if (elem.eventSource) {
        elem.eventSource.removeEventListener('message', elem.eventCallback);
        elem.eventSource.close();
        elem.eventSource = undefined;
    }
}

function addDataListener(elem, callback) {
    // ensure any previously added event source is removed
    removeDataListener(elem);

    // define callback function
    if (!elem.eventCallback) {
        elem.eventCallback = function(event) {
            elem[0].innerHTML += JSON.parse(event.data)[0];
            if (callback) {
                callback();
            }
        };
    }

    // add new event source and add listener
    elem.eventSource = new EventSource(elem.data('url'));
    elem.eventSource.addEventListener('message', elem.eventCallback, false);
}

function initLivelogAndTerminal() {
    // init scrolldown for live log
    scrolldown = true;
    $('#scrolldown').attr('checked', true);

    // find log elements
    logElements = [{
        panel: $('#live-log-panel'),
        log: $('#livelog'),
        callback: scrollToBottomOfLiveLog
    }, {
        panel: $('#live-terminal-panel'),
        log: $('#liveterminal')
    }];

    // enable expanding/collapsing live log/terminal
    $.each(logElements, function(index, value) {
            liveViewElements.push(value);
            value.panel.bodyVisible = false;
            value.panel.find('.card-header').on('click', function() {
                    // toggle visiblity
                    var body = value.panel.find('.card-body');
                    body.toggle(200);
                    value.panel.bodyVisible = !value.panel.bodyVisible;

                    // toggle receiving updates
                    if (value.panel.bodyVisible) {
                        addDataListener(value.log, value.callback);

                        // scroll to bottom of panel when expanding
                        $('html,body').animate({
                            scrollTop: value.panel.offset().top + value.panel.height()
                        });
                    } else {
                        removeDataListener(value.log);
                    }
                });
    });
}


/********* LIVE LOG END *********/

/********* LIVE STREAM *********/

// global vars for livestream
var last_event;

// loads a data-url img into a canvas
function loadCanvas(canvas, dataURL) {
    var context = canvas[0].getContext('2d');

    // load image from data url
    var scrn = new Image();
    scrn.onload = function() {
        context.clearRect(0, 0, canvas.width(), canvas.height());
        context.drawImage(this, 0, 0);
    };
    scrn.src = dataURL;
}

function initLivestream() {
    // setup callback for livestream
    var livestream = $('#livestream');
    livestream.eventCallback = function(event) {
        loadCanvas(livestream, event.data);
        last_event = event;
    };
    liveViewElements.push({log: livestream});
}

/********* LIVE STREAM END *********/

// initialize elements for live stream, live log and serial output but does not
// start to consume any streams (called in setupResult() if state is running)
function setupRunning(jobid, status_url, details_url) {
  initLivelogAndTerminal();
  initLivestream();
  initStatus(jobid, status_url, details_url);
  $('#scrolldown').change(setScrolldown);
}

// starts consuming streams for live stream, live log and serial output
// (called when live view tab is shown)
function resumeLiveView() {
  $.each(liveViewElements, function(index, value) {
    // skip streams which are shown in an expandible pannel which is currently collapsed
    if(value.panel && !value.panel.bodyVisible) {
      return;
    }
    addDataListener(value.log, value.callback);
  });
}

// stops consuming streams for live stream, live log and serial output
// (called when any tab except the live view tab is shown)
function pauseLiveView() {
  $.each(liveViewElements, function(index, value) {
    removeDataListener(value.log);
  });
}

//
// developer mode
//

// define state for developer mode
var developerMode = {
    // variables this JavaScript keeps track on its own
    develWsUrl: undefined,
    statusOnlyWsUrl: undefined,
    wsConnection: false,
    hasWsError: false,
    useDeveloperWsRoute: undefined,
    isConnected: false,
    ownSession: false,
    panelExpanded: false,
    panelActuallyExpanded: false,
    reconnectAttempts: 0,

    // variables which come from os-autoinst cmd srv through the openQA ws proxy
    currentModule: undefined,
    moduleToPauseAt: undefined,
    isPaused: undefined,

    // variables added by the openQA ws proxy
    develSessionDeveloper: undefined,
    develSessionStartedAt: undefined,
    develSessionTabCount: undefined,
};

// initializes the developer panel
function setupDeveloperPanel() {
    var panel = $('#developer-panel');

    // setup toggle for body
    var panelHeader = panel.find('.card-header');
    if (window.isAdmin) {
        panelHeader.on('click', function() {
            var panelBody = panel.find('.card-body');
            developerMode.panelExpanded = !developerMode.panelExpanded;
            developerMode.panelActuallyExpanded = developerMode.panelExpanded;
            panelBody.toggle(200);

            // ensure the developer ws route is used
            if (developerMode.panelExpanded && !developerMode.useDeveloperWsRoute) {
                setupWebsocketConnection();
            }
        });
    } else {
        panelHeader.css('cursor', 'default');
    }


    // ensure help popover doesn't toggle
    panel.find('.help_popover').on('click', function(event) {
        event.stopPropagation();
    });

    // register handlers for controls
    var moduleToPauseAtSelect = $('#developer-pause-at-module');
    moduleToPauseAtSelect.on('change', function(event) {
        var selectedModuleOption = moduleToPauseAtSelect.find('option:selected');
        var category = selectedModuleOption.parent('optgroup').attr('label');
        var selectedModuleName = undefined;
        if (category) {
            selectedModuleName = category + '-' + selectedModuleOption.text();
        }
        if (selectedModuleName !== developerMode.moduleToPauseAt) {
            sendWsCommand({
                cmd: 'set_pause_at_test',
                name: selectedModuleName,
            });
        }
    });

    // find URLs for web socket connections
    developerMode.develWsUrl = panel.data('developer-url');
    developerMode.statusOnlyWsUrl = panel.data('status-only-url');

    updateDeveloperPanel();
    setupWebsocketConnection();
}

// updates the developer panel, must be called after modifying developerMode
function updateDeveloperPanel() {
    // set panel body visibility
    var panel = $('#developer-panel');
    var panelBody = panel.find('.card-body');
    if (developerMode.panelExpanded !== developerMode.panelActuallyExpanded) {
        developerMode.panelActuallyExpanded = developerMode.panelExpanded;
        panelBody.toggle(200);
    }

    // find modules
    var moduleToPauseAtSelect = $('#developer-pause-at-module');
    var moduleToPauseAtOptions = moduleToPauseAtSelect.find('option');
    var modules = moduleToPauseAtOptions.map(function() {
        var option = $(this);
        var category = option.parent('optgroup').attr('label');
        return category ? (category + '-' + option.val()) : option.val();
    }).get();
    var currentModuleIndex = modules.indexOf(developerMode.currentModule);
    var toPauseAtIndex = modules.indexOf(developerMode.moduleToPauseAt);
    if (toPauseAtIndex < 0) {
        toPauseAtIndex = 0;
    }
    var moduleToPauseAtStillAhead = developerMode.moduleToPauseAt
        && toPauseAtIndex > currentModuleIndex;

    // update status info
    var statusInfo = 'unknown';
    if (developerMode.isPaused) {
        statusInfo = 'paused';
    } else if (moduleToPauseAtStillAhead) {
        statusInfo = 'will pause at module ' + developerMode.moduleToPauseAt;
    } else {
        statusInfo = 'usual test execution';
    }
    if (developerMode.currentModule && !moduleToPauseAtStillAhead) {
         statusInfo += ', at ' + developerMode.currentModule;
    }
    $('#developer-status-info').text(statusInfo);

    // update session info
    var sessionInfoElement = $('#developer-session-info');
    if (developerMode.develSessionDeveloper) {
        var sessionInfo = 'opened by ' + developerMode.develSessionDeveloper + ' (';
        sessionInfoElement.text(sessionInfo);

        var timeagoElement = $('<abbr class="timeago" title="' + developerMode.develSessionStartedAt + ' Z">' + developerMode.develSessionStartedAt + '</abbr>');
        sessionInfoElement.append(timeagoElement);
        timeagoElement.timeago();

        var tabsOpenInfo = ', developer has ' + developerMode.develSessionTabCount + (developerMode.develSessionTabCount == 1 ? ' tab' : ' tabs') + ' open)';
        sessionInfoElement.append(document.createTextNode(tabsOpenInfo));
    } else {
        var sessionInfo = 'no developer session opened';
        if (window.isAdmin && !developerMode.panelExpanded) {
            sessionInfo += ' - click to open';
        }
        sessionInfoElement.text(sessionInfo);
    }

    // update module to pause at
    moduleToPauseAtOptions[toPauseAtIndex].setAttribute('selected', true);

    // hide/show elements according to data-hidden and data-visible attributes
    var developerModeElements = $('.developer-mode-element');
    developerModeElements.each(function(index) {
        var element = $(this);
        var visibleOn = element.data('visible-on');
        var hiddenOn = element.data('hidden-on');
        var hide = (hiddenOn && developerMode[hiddenOn]) || (visibleOn && !developerMode[visibleOn]);
        if (hide) {
            element.hide();
        } else if (element.hasClass('btn')) {
            element.css('display', 'inline-block');
        } else {
            element.show();
        }
    });
}

function closeWebsocketConnection() {
    if (developerMode.wsConnection) {
        developerMode.wsConnection.close();
        developerMode.wsConnection = undefined;
    }
    developerMode.isConnected = false;
}

function setupWebsocketConnection() {
    // ensure previously opened connections are closed
    closeWebsocketConnection();

    // determine ws URL
    if ((window.isAdmin && (developerMode.panelExpanded || developerMode.useDeveloperWsRoute))) {
        // use route for developer (establishing a developer session)
        developerMode.useDeveloperWsRoute = true;
        var url = developerMode.develWsUrl;
    } else {
        // use route for regular user (receiving only status information)
        developerMode.useDeveloperWsRoute = false;
        var url = developerMode.statusOnlyWsUrl;
    }
    url = makeWsUrlAbsolute(url);

    // establish ws connection
    console.log("Establishing ws connection to " + url);
    developerMode.reconnectAttempts = 1;
    var wsConnection = new WebSocket(url);
    wsConnection.onopen = function() {
        if (wsConnection !== developerMode.wsConnection) {
            return;
        }
        developerMode.reconnectAttempts = 0;
        developerMode.isConnected = true;
        developerMode.hasWsError = false;
        developerMode.ownSession = developerMode.useDeveloperWsRoute;
        updateDeveloperPanel();
    };
    wsConnection.onerror = function(error) {
        if (wsConnection !== developerMode.wsConnection) {
            return;
        }
        developerMode.hasWsError = true;
        // note: error doesn't contain very useful information, just set the error flag here
    };
    wsConnection.onclose = function() {
        if (wsConnection !== developerMode.wsConnection) {
            return;
        }
        console.log("Connection to livehandler lost");
        developerMode.wsConnection = undefined;
        developerMode.isConnected = false;
        developerMode.ownSession = false;
        updateDeveloperPanel();

        // reconnect instantly in first connection error
        if (developerMode.reconnectAttempts === 0) {
            setupWebsocketConnection();
        } else {
            // otherwise try to reconnect every 2 seconds
            setTimeout(function() {
                setupWebsocketConnection();
            }, 2000);
        }
    };
    wsConnection.onmessage = function(msg) {
        if (wsConnection !== developerMode.wsConnection) {
            return;
        }

        // parse the message JSON
        if (!msg.data) {
            return;
        }
        console.log("Received message via ws proxy: " + msg.data);
        try {
            var dataObj = JSON.parse(msg.data);
        } catch {
            console.log("Unable to parse JSON from ws proxy: " + msg.data);
            // TODO: log errors visible on the page
            return;
        }

        processWsCommand(dataObj);
    };

    developerMode.wsConnection = wsConnection;
}

// define mapping of backend messages to status variables
var messageToStatusVariable = [
    {
        msg: 'test_execution_paused',
        statusVar: 'isPaused',
    },
    {
        msg: 'paused',
        statusVar: 'isPaused',
    },
    {
        msg: 'pause_test_name',
        statusVar: 'moduleToPauseAt',
    },
    {
        msg: 'set_pause_at_test',
        statusVar: 'moduleToPauseAt',
    },
    {
        msg: 'current_test_full_name',
        statusVar: 'currentModule',
    },
    {
        msg: 'developer_name',
        statusVar: 'develSessionDeveloper',
    },
    {
        msg: 'developer_session_started_at',
        statusVar: 'develSessionStartedAt',
    },
    {
        msg: 'developer_session_tab_count',
        statusVar: 'develSessionTabCount',
    },
    {
        msg: 'resume_test_execution',
        action: function() { developerMode.isPaused = false; },
    }
];

// handles messages received via web socket connection
function processWsCommand(obj) {
    var somethingChanged = false;
    var what = obj.what;
    var data = obj.data;

    switch(obj.type) {
    case "error":
        // handle errors
        console.log("Error from ws proxy: " + what);
        // TODO: log errors visible on the page
        break;
    case "info":
        switch(what) {
        case "cmdsrvmsg":
            // handle messages from os-autoinst command server
            $.each(messageToStatusVariable, function(index, msgToStatusValue) {
                var msg = msgToStatusValue.msg;
                if (!(msg in data)) {
                    return;
                }
                var statusVar = msgToStatusValue.statusVar;
                if (statusVar) {
                    developerMode[statusVar] = data[msg];
                }
                var action = msgToStatusValue.action;
                if (action) {
                    action(data[msg]);
                }
                somethingChanged = true;
            });
            break;
        }
        break;
    }

    if (somethingChanged) {
        updateDeveloperPanel();
    }
}

// sends a command via web sockets to the web UI which will pass it to os-autoinst
function sendWsCommand(obj) {
    if (!developerMode.wsConnection) {
        console.log("Attempt to send something via ws proxy but not connected.");
        // TODO: log errors visible on the page
        return;
    }
    developerMode.wsConnection.send(JSON.stringify(obj));
}

// resumes the test execution (if currently paused)
function resumeTestExecution() {
    sendWsCommand({ cmd: "resume_test_execution" });
}

// quits the developer session
function quitDeveloperSession() {
    if (!developerMode.useDeveloperWsRoute) {
        return;
    }
    developerMode.useDeveloperWsRoute = undefined;
    developerMode.panelExpanded = false;
    updateDeveloperPanel();
    sendWsCommand({ cmd: "quit_development_session" });
}

// vim: set sw=4 et:
