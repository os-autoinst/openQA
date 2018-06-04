
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
    if (newStatus.state != 'running' && newStatus.state != 'waiting') {
        setTimeout(function() {location.reload();}, 2000);
        return;
    }
    testStatus.workerid = newStatus.workerid;
    $('#running_module').text(newStatus.running);

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

// vim: set sw=4 et:
