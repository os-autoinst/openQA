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
        setTimeout(reloadPage, 2000);
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

    // skip further updating if the currently running module didn't change and there
    // are no details for the currently running module are available
    // note: use of '==' (rather than '===') makes a difference here to consider null and undefined as equal
    if (testStatus.running == newStatus.running &&
        !developerMode.detailsForCurrentModuleUploaded) {
        return;
    }

    // redraw module list if a new module have been started
    $.ajax(testStatus.details_url).done(function(data) {
        if (data.length <= 0) {
            console.log("ERROR: modlist empty");
            return;
        }

        // create DOM elements from the HTML data
        var dataDom = $(data);

        // update module selection for developer mode
        var moduleSelectOnPage = $('#developer-pause-at-module');
        var newModuleSelect = dataDom.filter('#developer-pause-at-module');
        if (moduleSelectOnPage.length && newModuleSelect.length) {
            moduleSelectOnPage.replaceWith(newModuleSelect);
            updateModuleSelection(newModuleSelect.find('option'), developerMode.currentModuleIndex);
        }

        // skip if the row of the running module is not present in the result table
        var runningRow = dataDom.find('.resultrunning');
        if (!runningRow.length) {
            return;
        }

        // handle case when the results table doesn't exist yet
        var newResults = dataDom.filter('#results');
        if (!$("#results").length) {
            $("#details").append(newResults);
            console.log("Missing results table created");
            testStatus.running = newStatus.running;
            updateDeveloperMode();
            return;
        }

        // update existing results table
        var running_tr = $('td.result.resultrunning').parent();
        var result_tbody = running_tr.parent();
        var first_tr_to_update = running_tr.index();
        var new_trs = newResults.find('tbody > tr');
        var printed_running = false;
        var missing_results = false;
        result_tbody.children().slice(first_tr_to_update).each(function() {
            var tr = $(this);
            var new_tr = new_trs.eq(tr.index());
            if (new_tr.find('.resultrunning').length == 1) {
                printed_running = true;
            }
            // every row above the currently running module must have results
            if (!printed_running && new_tr.find('.links').length > 0 && new_tr.find('.links').children().length == 0) {
                missing_results = true;
                console.log("Missing results in row - trying again");
            }
        });

        if (!missing_results) {
            var previewContainer = $('#preview_container_out');

            result_tbody.children().slice(first_tr_to_update).each(function() {
                var tr = $(this);

                // detatch the preview container if it is contained by the row to be relaced
                var previewLinkIndex = -1;
                if ($.contains(this, previewContainer[0])) {
                    previewLinkIndex = $('.current_preview').index();
                    previewContainer.detach();
                }

                // replace the old tr element with the new one
                tr.replaceWith(new_trs.eq(tr.index()));

                // re-attach the preview container if possible
                if (previewLinkIndex < 0) {
                    return;
                }
                var newPreviewLinks = new_trs.find('.links_a');
                if (previewLinkIndex < newPreviewLinks.length) {
                    var newPreviewLink = newPreviewLinks.eq(previewLinkIndex);
                    newPreviewLink.addClass('current_preview');
                    previewContainer.insertAfter(newPreviewLink);
                } else {
                    previewContainer.hide().appendTo('body');
                }
            });
            testStatus.running = newStatus.running;
            developerMode.detailsForCurrentModuleUploaded = false;
            updateDeveloperMode();
        }

    }).fail(function() {
        console.log("ERROR: modlist fail");
    });
}

function sendCommand(command) {
    var wid = testStatus.workerid;
    if (wid == null) return false;
    var url = $('#canholder').data('url').replace('WORKERID', wid);
    $.ajax({url: url,
            type: 'POST',
            data: { command: command },
            success: function(resp) {
                setTimeout(function() { updateStatus(); }, 0);
            }});
}

function updateStatus() {
    $.ajax(testStatus.status_url).
        done(function(status) {
            updateTestStatus(status);
            setTimeout(function() { updateStatus(); }, 5000);
        }).fail(function() {
            setTimeout(reloadPage, 5000);
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

    // define callback function for response of OpenQA::WebAPI::Controller::Running::streamtext
    if (!elem.eventCallback) {
        elem.eventCallback = function(event) {
            // define max size of the live log
            // note: If not preventing the livelog from becoming too long the page would become unresponsive at a
            //       certain length.
            var maxLiveLogLength = 50 * 1024;

            var firstElement = elem[0];
            var currentData = firstElement.innerHTML;
            var newData = JSON.parse(event.data)[0];
            var newLength = currentData.length + newData.length;

            // append if not exceeding the limit; otherwise cut the front
            if (newLength < maxLiveLogLength) {
                firstElement.innerHTML += newData;
            } else {
                var catData = currentData + newData;
                var newStartIndex = newLength - maxLiveLogLength;

                // discard one (probably) partial line (in accordance with OpenQA::WebAPI::Controller::Running::streamtext)
                for (; catData[newStartIndex] !== "\n"; ++newStartIndex);

                firstElement.innerHTML = catData.substr(newStartIndex);
            }
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
    // state of the page elements and the web socket connection to web UI
    develWsUrl: undefined,                  // URL for developer session web socket connection
    statusOnlyWsUrl: undefined,             // URL for status-only web socket connection
    wsConnection: undefined,                // current WebSocket object
    hasWsError: false,                      // whether an web socket error occurred (cleared when we finally receive a message from os-autoinst)
    useDeveloperWsRoute: undefined,         // whether the developer web socket route is used
    isConnected: false,                     // whether connected to any web socket route
    badConfiguration: false,                // whether there's a bad/unrecoverable configuration issue so it makes no sense to continue re-connecting
    ownSession: false,                      // whether the development session belongs to us
    panelExpanded: false,                   // whether the panel is supposed to be expanded
    panelActuallyExpanded: false,           // whether the panel is currently expanded
    panelExplicitelyCollapsed: false,          // whether the panel has been explicitely collapsed since the page has been opened
    reconnectAttempts: 0,                   // number of (re)connect attempts (reset to 0 when we finally receive a message from os-autoinst)
    currentModuleIndex: undefined,          // the index of the current module

    // state of the test execution (comes from os-autoinst cmd srv through the openQA ws proxy)
    currentModule: undefined,               // name of the current module, eg. "installation-welcome"
    moduleToPauseAt: undefined,             // name of the module to pause at, eg. "installation-welcome"
    pauseOnScreenMismatch: undefined,       // 'assert_screen' (to pause on assert_screen timeout) or 'check_screen' (to pause on assert/check_screen timeout)
    pauseOnNextCommand: undefined,          // whether to pause on the next command (current command *not* affected, eg. *no* timeouts skipped or failures suppressed)
    isPaused: undefined,                    // if paused the reason why as a string; otherwise something which evaluates to false
    currentApiFunction: undefined,          // the currently executed API function (eg. assert_screen)
    outstandingImagesToUpload: undefined,   // number of images which still need to be uploaded by the worker
    outstandingFilesToUpload: undefined,    // number of other files which still need to be uploaded by the worker
    uploadingUpToCurrentModule: undefined,  // whether the worker will upload up to the current module (happens when paused in the middle of a module)
    detailsForCurrentModuleUploaded: false, // whether new test details for the currently running module have been uploaded
    stoppingTestExecution: undefined,       // if the test execution is being stopped the reason for that; otherwise undefined

    // state of development session (comes from the openQA ws proxy)
    develSessionDeveloper: undefined,       // name of the user in possession the development session
    develSessionStartedAt: undefined,       // time stamp when the development session was created
    develSessionTabCount: undefined,        // number of open web socket connections by the developer

    // returns whether we're currently connecting
    isConnecting: function() {
        return !this.badConfiguration && !this.isConnected && !this.stoppingTestExecution;
    },

    // returns whether there's a development session but it doesn't belong to us
    lockedByOtherDeveloper: function() {
        return this.develSessionDeveloper && !this.ownSession && !this.stoppingTestExecution;
    },

    // returns whether the needle editor is ready
    // (results for the current module must have been uploaded yet)
    needleEditorReady: function() {
        return this.isPaused &&
            this.uploadingUpToCurrentModule &&
            this.outstandingImagesToUpload === 0 &&
            this.outstandingFilesToUpload === 0;
    },

    // returns whether it is possible to skip the timeout
    canSkipTimeout: function() {
        return this.ownSession && !this.isPaused && (this.currentApiFunction === 'assert_screen' || this.currentApiFunction === 'check_screen');
    },

    // returns the specified property evaluating possibly assigned functions
    prop: function(propertyName) {
        var prop = this[propertyName];
        return typeof prop === 'function' ? prop.apply(this) : prop;
    },
};

// updates the developer mode if initialized (update panel, ensure connected)
function updateDeveloperMode() {
    if (!window.developerPanelInitialized) {
        return;
    }
    updateDeveloperPanel();
    if (!developerMode.wsConnection) {
        setupWebsocketConnection();
    }
}

// initializes the developer panel
function setupDeveloperPanel() {
    // skip if already initialized
    if (window.developerPanelInitialized) {
        return;
    }
    window.developerPanelInitialized = true;

    var panel = $('#developer-panel');
    var flashMessages = document.getElementById('developer-flash-messages');

    // set overall status variables
    developerMode.ownUserId = panel.data('own-user-id');
    developerMode.isAccessible = panel.data('is-accessible'); // actually assigns a boolean (and not eg. the string 'false')

    // find URLs for web socket connections
    developerMode.develWsUrl = panel.data('developer-url');
    developerMode.statusOnlyWsUrl = panel.data('status-only-url');

    // setup toggle for body
    var panelHeader = panel.find('.card-header');
    if (developerMode.isAccessible) {
        panelHeader.on('click', function(event) {
            // skip if flash message clicked
            if ($.contains(flashMessages, event.target)) {
                return;
            }

            // toggle visibility of body
            var panelBody = panel.find('.card-body');
            developerMode.panelExpanded = !developerMode.panelExpanded;
            developerMode.panelActuallyExpanded = developerMode.panelExpanded;
            if (!developerMode.panelExpanded) {
                developerMode.panelExplicitelyCollapsed = true;
            }
            panelBody.toggle(200);
        });
    } else {
        panelHeader.css('cursor', 'default');
    }

    // ensure help popover doesn't toggle
    panel.find('.help_popover').on('click', function(event) {
        event.stopPropagation();
    });

    // add handler for static form elements
    document.getElementById('developer-pause-on-mismatch').onchange = handlePauseOnMismatchSelected;
    document.getElementById('developer-pause-on-next-command').onchange = handlePauseOnNextCommandToggled;

    updateDeveloperPanel();
    setupWebsocketConnection();
}

// hides the specified options up to the specified index
function updateModuleSelection(moduleToPauseAtOptions, moduleIndex) {
    for (var i = 0; i <= moduleIndex; ++i) {
        var optionElement = moduleToPauseAtOptions[i];
        var optgroupElement = optionElement.parentNode;
        if (!optgroupElement || optgroupElement.nodeName !== 'OPTGROUP') {
            continue;
        }
        optionElement.style.display = 'none';
        if (optgroupElement.lastElementChild.isEqualNode(optionElement)) {
            optgroupElement.style.display = 'none';
        }
    }
}

// updates the developer panel, must be called after modifying developerMode
function updateDeveloperPanel() {
    // hide/show elements according to data-hidden and data-visible attributes
    var developerModeElements = $('.developer-mode-element');
    developerModeElements.each(function(index) {
        var element = $(this);
        var visibleOn = element.data('visible-on');
        var hiddenOn = element.data('hidden-on');
        var hide = ((hiddenOn && developerMode.prop(hiddenOn)) ||
                    (visibleOn && !developerMode.prop(visibleOn)));
        if (hide) {
            element.hide();
            element.tooltip('hide');
        } else if (element.hasClass('btn')) {
            element.css('display', 'inline-block');
        } else {
            element.show();
        }
    });

    // set panel visibility
    var panel = $('#developer-panel');
    if (!testStatus.running) {
        // hide entire panel if test is not running anymore
        panel.hide();
        return;
    }
    panel.show();

    // expand the controls if the test is paused (unless previously manually collapsed)
    if (developerMode.ownSession && developerMode.isPaused && !developerMode.panelExplicitelyCollapsed) {
        developerMode.panelExpanded = true;
    }

    // toggle panel body if its current state doesn't match developerMode.panelExpanded
    var panelBody = panel.find('.card-body');
    if (developerMode.panelExpanded !== developerMode.panelActuallyExpanded) {
        developerMode.panelActuallyExpanded = developerMode.panelExpanded;
        panelBody.toggle(200);
    }

    // find modules and determine the index of the current module
    var moduleToPauseAtSelect = $('#developer-pause-at-module');
    var moduleToPauseAtOptions = moduleToPauseAtSelect.find('option');
    var modules = moduleToPauseAtOptions.map(function() {
        var option = $(this);
        var category = option.parent('optgroup').attr('label');
        return category ? (category + '-' + option.val()) : option.val();
    }).get();
    var currentModuleIndex = modules.indexOf(developerMode.currentModule);

    // hide modules which have already been executed when the current module index has changed
    if (developerMode.currentModuleIndex !== currentModuleIndex) {
        updateModuleSelection(moduleToPauseAtOptions, developerMode.currentModuleIndex = currentModuleIndex);
    }

    // determine whether the module to pause at is still ahead
    var toPauseAtIndex = modules.indexOf(developerMode.moduleToPauseAt);
    if (toPauseAtIndex < 0) {
        toPauseAtIndex = 0;
    }
    var moduleToPauseAtStillAhead = (developerMode.moduleToPauseAt &&
          toPauseAtIndex > currentModuleIndex);

    // update status info
    var statusInfo = 'running';
    var statusAppendix = '';
    if (developerMode.stoppingTestExecution) {
        statusInfo = 'stopping';
    } else if (developerMode.badConfiguration) {
        statusInfo = 'configuration issue';
    } else if (developerMode.isPaused) {
        statusInfo = 'paused';
        if (developerMode.currentModule) {
            statusInfo += ' at module: ' + developerMode.currentModule;
        }
        if (developerMode.outstandingImagesToUpload || developerMode.outstandingFilesToUpload) {
            statusInfo += ', uploading results';
        }
        statusAppendix = 'reason: ' + developerMode.isPaused;
    } else if (moduleToPauseAtStillAhead) {
        statusInfo = 'will pause at module: ' + developerMode.moduleToPauseAt;
        if (developerMode.currentModule) {
            statusAppendix = 'currently at: ' + developerMode.currentModule;
            if (developerMode.currentApiFunction) {
                statusAppendix += ', ' + developerMode.currentApiFunction;
            }
        }
    } else if (developerMode.currentModule) {
        statusInfo = 'current module: ' + developerMode.currentModule;
        if (developerMode.currentApiFunction) {
            statusAppendix += 'at ' + developerMode.currentApiFunction;
        }
    }
    if (!developerMode.badConfiguration && developerMode.currentApiFunction) {
        $('#developer-current-api-function').text('(' + developerMode.isPaused + ')');
    }
    $('#developer-status-info').text(statusInfo);
    $('#developer-status-appendix').text(statusAppendix);

    // update session info
    var sessionInfoElement = $('#developer-session-info');
    var sessionInfo;
    if (developerMode.develSessionDeveloper) {
        sessionInfo = 'owned by ' + developerMode.develSessionDeveloper + ' (';
        sessionInfoElement.text(sessionInfo);

        var timeagoElement = $('<abbr class="timeago" title="' + developerMode.develSessionStartedAt + ' Z">' + developerMode.develSessionStartedAt + '</abbr>');
        sessionInfoElement.append(timeagoElement);
        timeagoElement.timeago();

        var tabsOpenInfo = ', developer has ' + developerMode.develSessionTabCount + (developerMode.develSessionTabCount == 1 ? ' tab' : ' tabs') + ' open)';
        sessionInfoElement.append(document.createTextNode(tabsOpenInfo));

        var globalSessionInfoElement = $('#developer-global-session-info:hidden');
        if (globalSessionInfoElement.length) {
            globalSessionInfoElement.text('Developer session has been opened by ' + developerMode.develSessionDeveloper);
            globalSessionInfoElement.show();
        }
    } else if (!developerMode.badConfiguration) {
        sessionInfo = 'regular test execution';
        if (developerMode.isAccessible && !developerMode.panelExpanded) {
            sessionInfo += ' - click to expand';
        }
        sessionInfoElement.text(sessionInfo);
    }

    // update form elements
    // -> skip if the test hasn't been locked by anybody so far and we're just showing the form initially
    if (!developerMode.ownSession && !developerMode.develSessionDeveloper && developerMode.panelExpanded) {
        return;
    }
    // -> update module to pause at
    if (moduleToPauseAtSelect.length) {
        // update module to pause at and ensure handler is registered (element might be replaced in updateTestStatus())
        var selectElement = moduleToPauseAtSelect[0];
        selectElement.selectedIndex = toPauseAtIndex;
        if (!selectElement.handlerRegistered) {
            selectElement.onchange = handleModuleToPauseAtSelected;
            selectElement.handlerRegistered = true;
        }
    }
    // -> update whether the test will pause on assert screen timeout
    var pauseOnMismatchSelect = document.getElementById('developer-pause-on-mismatch');
    if (developerMode.pauseOnScreenMismatch === 'assert_screen') {
        pauseOnMismatchSelect.selectedIndex = 1; // "assert_screen timeout" option
    } else if (developerMode.pauseOnScreenMismatch === 'check_screen') {
        pauseOnMismatchSelect.selectedIndex = 2; // "assert_screen and check_screen timeout" option
    } else if (developerMode.pauseOnScreenMismatch === false) {
        pauseOnMismatchSelect.selectedIndex = 0; // "Fail on mismatch as usual" option
    }
    // -> update whether to pause at the next command
    if (developerMode.pauseOnNextCommand !== undefined) {
        $('#developer-pause-on-next-command').prop('checked', developerMode.pauseOnNextCommand);
    }

}

// submits the selected module to pause at if it has changed
function handleModuleToPauseAtSelected() {
    // skip if not owning development session or moduleToPauseAt is unknown
    if (!developerMode.ownSession || developerMode.moduleToPauseAt === undefined) {
        return;
    }

    // determine the selected module including the category, eg. "installation-welcome"
    var selectedModuleOption = $('#developer-pause-at-module').find('option:selected');
    var category = selectedModuleOption.parent('optgroup').attr('label');
    var selectedModuleName = null;
    if (category) {
        selectedModuleName = category + '-' + selectedModuleOption.text();
    }
    if (selectedModuleName !== developerMode.moduleToPauseAt) {
        sendWsCommand({
            cmd: 'set_pause_at_test',
            name: selectedModuleName,
        });
    }
}

function handlePauseOnMismatchSelected() {
    // skip if not owning development session or pauseOnScreenMismatch is unknown
    if (!developerMode.ownSession || developerMode.pauseOnScreenMismatch === undefined) {
        return;
    }

    var selectedValue = $('#developer-pause-on-mismatch').val();
    var pauseOn;
    switch(selectedValue) {
        case "fail":
            pauseOn = null;
            break;
        case "check_screen":
        case "assert_screen":
            pauseOn = selectedValue;
            break;
    }
    sendWsCommand({
        cmd: 'set_pause_on_screen_mismatch',
        pause_on: pauseOn,
    });
}

function handlePauseOnNextCommandToggled() {
    // skip if not owning development session or pauseOnNextCommand is unknown
    if (!developerMode.ownSession || developerMode.pauseOnNextCommand === undefined) {
        return;
    }
    sendWsCommand({
        cmd: 'set_pause_on_next_command',
        flag: $('#developer-pause-on-next-command').prop('checked'),
    });
}

// submits the selected values which differ from the server's state
function submitCurrentSelection() {
    handleModuleToPauseAtSelected();
    handlePauseOnMismatchSelected();
}

// ensures the websocket connection is closed
function closeWebsocketConnection() {
    if (developerMode.wsConnection) {
        developerMode.wsConnection.close();
        developerMode.wsConnection = undefined;
    }
    developerMode.isConnected = false;
}

function clearLivehandlerFlashMessages() {
    if (!window.uniqueFlashMessages) {
        return;
    }

    for (var id in window.uniqueFlashMessages) {
        if (id === 'unable_to_pare_livehandler_reply' ||
            id.indexOf('ws_proxy_error-') === 0) {
            window.uniqueFlashMessages[id].remove();
            delete window.uniqueFlashMessages[id];
        }
    }
}

function handleWebsocketConnectionOpened(wsConnection) {
    if (wsConnection !== developerMode.wsConnection) {
        return;
    }

    // update state
    developerMode.isConnected = true;
    developerMode.ownSession = developerMode.useDeveloperWsRoute;

    // sync the current selection if the test is running and it is our session
    // note: the check for testStatus.running is important - otherwise we might override existing
    //       configuration with the form defaults
    if (testStatus.running && developerMode.ownSession) {
        submitCurrentSelection();
    }

    clearLivehandlerFlashMessages();

    updateDeveloperPanel();
}

function handleWebsocketConnectionClosed(wsConnection) {
    if (wsConnection !== developerMode.wsConnection) {
        return;
    }
    console.log("Connection to livehandler lost");

    // update state
    developerMode.wsConnection = undefined;
    developerMode.isConnected = false;
    developerMode.panelExpanded = false;
    developerMode.useDeveloperWsRoute = false;
    developerMode.ownSession = false;
    updateDeveloperPanel();

    // skip reconnect if test is just not running (anymore)
    if (!testStatus.running || developerMode.stoppingTestExecution) {
        return;
    }

    // reconnect instantly in first connection error
    if (developerMode.reconnectAttempts === 0) {
        setupWebsocketConnection();
    } else {
        // otherwise try to reconnect every 2 seconds
        setTimeout(function() {
            setupWebsocketConnection();
        }, 2000);
    }
}

function addLivehandlerFlash(status, id, text) {
    addUniqueFlash(status, id, text, $('#developer-flash-messages'));
}

function handleMessageFromWebsocketConnection(wsConnection, msg) {
    if (wsConnection !== developerMode.wsConnection) {
        return;
    }

    // parse the message JSON
    if (!msg.data) {
        return;
    }
    console.log("Received message via ws proxy: " + msg.data);
    var dataObj;
    try {
        dataObj = JSON.parse(msg.data);
    } catch (ex) {
        console.log("Unable to parse JSON from ws proxy: " + msg.data);
        addLivehandlerFlash('danger', 'unable_to_pare_livehandler_reply',
                            '<strong>Unable to parse reply from livehandler daemon.</strong>');
        return;
    }

    processWsCommand(dataObj);
}

function setupWebsocketConnection() {
    // ensure previously opened connections are closed
    closeWebsocketConnection();

    // give up re-connecting if there's a configuration issue we can not recover from
    if (developerMode.badConfiguration) {
        return;
    }

    var url;
    // determine ws URL
    if ((developerMode.isAccessible && developerMode.useDeveloperWsRoute)) {
        // use route for developer (establishing a developer session)
        developerMode.useDeveloperWsRoute = true;
        url = developerMode.develWsUrl;
    } else {
        // use route for regular user (receiving only status information)
        developerMode.useDeveloperWsRoute = false;
        url = developerMode.statusOnlyWsUrl;
    }
    url = makeWsUrlAbsolute(url);

    // establish ws connection
    console.log("Establishing ws connection to " + url);
    developerMode.reconnectAttempts += 1;
    var wsConnection = new WebSocket(url);
    wsConnection.onopen = function() {
        handleWebsocketConnectionOpened(wsConnection);
    };
    wsConnection.onerror = function(error) {
        if (wsConnection !== developerMode.wsConnection) {
            return;
        }

        // set the error flag
        developerMode.hasWsError = true;
    };
    wsConnection.onclose = function() {
        handleWebsocketConnectionClosed(wsConnection);
    };
    wsConnection.onmessage = function(msg) {
        handleMessageFromWebsocketConnection(wsConnection, msg);
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
        action: function(value, wholeMessage) {
            developerMode.isPaused = wholeMessage.reason ? wholeMessage.reason : 'unknown';
        },
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
        msg: 'pause_on_screen_mismatch',
        statusVar: 'pauseOnScreenMismatch',
    },
    {
        msg: 'set_pause_on_screen_mismatch',
        statusVar: 'pauseOnScreenMismatch',
    },
    {
        msg: 'pause_on_next_command',
        statusVar: 'pauseOnNextCommand',
    },
    {
        msg: 'set_pause_on_next_command',
        statusVar: 'pauseOnNextCommand',
    },
    {
        msg: 'current_test_full_name',
        statusVar: 'currentModule',
    },
    {
        msg: 'developer_id',
        action: function(value) {
            developerMode.ownSession = (developerMode.ownUserId && developerMode.ownUserId == value);
        },
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
        msg: 'developer_session_is_yours',
        statusVar: 'ownSession',
    },
    {
        msg: 'resume_test_execution',
        action: function() {
            developerMode.isPaused = false;
        },
    },
    {
        msg: 'outstanding_images',
        statusVar: 'outstandingImagesToUpload',
    },
    {
        msg: 'outstanding_files',
        statusVar: 'outstandingFilesToUpload',
    },
    {
        msg: 'upload_up_to_current_module',
        statusVar: 'uploadingUpToCurrentModule',
    },
    {
        msg: 'current_api_function',
        statusVar: 'currentApiFunction',
    },
    {
        msg: 'stopping_test_execution',
        statusVar: 'stoppingTestExecution',
    },
];

// handles messages received via web socket connection
function processWsCommand(obj) {
    var somethingChanged = false;
    var what = obj.what;
    var data = obj.data;
    var category;
    if (data) {
        category = data.category;
    }

    switch(obj.type) {
    case "error":
        // handle errors

        // ignore connection errors if there's no running module according to OpenQA::WebAPI::Controller::Running::status
        // or the test execution is stopped
        if ((!testStatus.running || developerMode.stoppingTestExecution) && category === 'cmdsrv-connection') {
            console.log('ignoring error from ws proxy: ' + what);
            break;
        }
        if (category === 'bad-configuration') {
            developerMode.badConfiguration = true;
            somethingChanged = true;
        }

        console.log("Error from ws proxy: " + what);
        addLivehandlerFlash('danger', 'ws_proxy_error-' + what, '<p>' + what + '</p>');
        break;
    case "info":
        // map info message to internal status variables
        switch (what) {
        case "cmdsrvmsg":
        case "upload progress":
            // reset error state
            developerMode.reconnectAttempts = 0;
            developerMode.hasWsError = false;

            // handle messages from os-autoinst command server
            $.each(messageToStatusVariable, function(index, msgToStatusValue) {
                var msg = msgToStatusValue.msg;
                if (!(msg in data)) {
                    return;
                }
                var statusVar = msgToStatusValue.statusVar;
                var value = data[msg];
                if (statusVar) {
                    developerMode[statusVar] = value;
                }
                var action = msgToStatusValue.action;
                if (action) {
                    action(value, data);
                }
                somethingChanged = true;
            });

            break;
        }

        // handle specific info messages
        switch (what) {
        case "upload progress":
            if (developerMode.uploadingUpToCurrentModule &&
                    developerMode.outstandingImagesToUpload === 0 &&
                    developerMode.outstandingFilesToUpload === 0) {
                // receiving an upload progress event with these values means the upload
                // has been concluded
                // -> set flag so the next updateTestStatus() will request these details
                developerMode.detailsForCurrentModuleUploaded = true;
            }
            break;
        }
        break;
    }

    if (somethingChanged) {
        // check whether the development session is ours to change to the proxy with write-access
        if (!developerMode.useDeveloperWsRoute && developerMode.ownSession) {
            developerMode.useDeveloperWsRoute = true;
            setupWebsocketConnection();
        }
        updateDeveloperPanel();
    }
}

// sends a command via web sockets to the web UI which will pass it to os-autoinst
function sendWsCommand(obj) {
    if (!developerMode.wsConnection) {
        console.log("Attempt to send something via ws proxy but not connected.");
        addLivehandlerFlash('danger', 'try_to_send_but_not_connected',
                            '<strong>Internal error:</strong><p>Attempt to send something via web socket proxy but not connected.</p>');
        return;
    }
    var objAsString = JSON.stringify(obj);
    console.log("Sending message via ws proxy: " + objAsString);
    developerMode.wsConnection.send(objAsString);
}

// resumes the test execution (if currently paused)
function resumeTestExecution() {
    sendWsCommand({ cmd: "resume_test_execution" });
}

// sets the timeout of the currently ongoing assert/check_screen to zero
function skipTimeout() {
    sendWsCommand({
        cmd: "set_assert_screen_timeout",
        timeout: 0,
    });
}

// starts the developer session (if not already done yet)
function startDeveloperSession() {
    if (!developerMode.useDeveloperWsRoute) {
        developerMode.useDeveloperWsRoute = true;
        setupWebsocketConnection();
    }
}

// quits the developer session (will cancel the job)
function quitDeveloperSession() {
    if (!developerMode.useDeveloperWsRoute) {
        return;
    }
    developerMode.useDeveloperWsRoute = undefined;
    developerMode.panelExplicitelyCollapsed = true;
    developerMode.panelExpanded = false;
    updateDeveloperPanel();
    sendWsCommand({ cmd: "quit_development_session" });
}

// vim: set sw=4 et:
