
var testStatus = {
    modlist_initialized: 0,
    jobid: null,
    running: null,
    workerid: null,
    interactive: null,
    needinput: null,
    stop_waitforneedle_requested: null,
    status_url: null,
    details_url: null,
    img_reload_time: 0
};

// Update global variable testStatus
function updateTestStatus(newStatus) {
    if (newStatus.state != 'running' && newStatus.state != 'waiting') {
        setTimeout(function() {location.reload();}, 2000);
        return;
    }
    testStatus.workerid = newStatus.workerid;
    testStatus.interactive = newStatus.interactive == true;
    testStatus.needinput = newStatus.needinput == true;
    testStatus.stop_waitforneedle_requested = newStatus.stop_waitforneedle_requested == true;
    updateInteractiveIndicator();
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

function updateInteractiveIndicator() {
    var indicator = $("#interactive_indicator");
    if (testStatus.interactive == null) {
        indicator.html("Unknown");
        $("#interactive_spinner").hide();
        $("#interactive_enabled_button").hide();
        $("#interactive_disabled_button").hide();
    }
    else if (testStatus.interactive == 1) {
        indicator.text("Yes");
        $("#interactive_enabled_button").hide();
        $("#interactive_disabled_button").show();
    }
    else {
        indicator.text("No");
        $("#interactive_enabled_button").show();
        $("#interactive_disabled_button").hide();
    }
    updateNeedinputIndicator();
}

function updateNeedinputIndicator() {
    var indicator = $("#needinput_indicator");
    if (testStatus.needinput) {
        indicator.text("Yes");
        $("#stop_waitforneedle_spinner").hide();
        $("#crop_button").show();
        $("#continue_button").show();
        $("#retry_button").show();
        $("#stop_button").hide();
    }
    else {
        indicator.text("No");
        if (testStatus.stop_waitforneedle_requested == 1) {
            $("#stop_waitforneedle_spinner").show();
            $("#crop_button").hide();
            $("#continue_button").hide();
            $("#retry_button").hide();
            $("#stop_button").hide();
        }
        else {
            $("#stop_waitforneedle_spinner").hide();
            $("#crop_button").hide();
            $("#continue_button").hide();
            $("#retry_button").hide();
            if (testStatus.interactive) {
                $("#stop_button").show();
            }
            else {
                $("#stop_button").hide();
            }
        }
    }
    //indicator.highlight();
}

function enableInteractive(e) {
  e.preventDefault();
  sendCommand("enable_interactive_mode");
}

function disableInteractive(e) {
  e.preventDefault();
  $("#stop_button").hide();
  sendCommand("disable_interactive_mode");
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
            setTimeout("updateStatus()", 1000);
        }).fail(function() {
            setTimeout(function() {location.reload();}, 1000);
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
function setScrolldown(newval) {
    scrolldown = $(this).prop('checked');
    if (scrolldown) {
        var livelog = $('#livelog')[0];
        $('#livelog').scrollTop = livelog.scrollHeight;
    }
}

function setDataListener(elem, callback) {
    var events = new EventSource(elem.data('url'));
    events.addEventListener('message', function(event) {
        elem[0].innerHTML += JSON.parse(event.data)[0];
	if (callback) callback();
    }, false);
}

function initLivelog() {
    scrolldown = true;
    $('#scrolldown').attr('checked', true);
    
    // start stream
    var livelog = $('#livelog');
    setDataListener(livelog, function() {
        if (scrolldown) livelog[0].scrollTop = livelog[0].scrollHeight;
    });
}

function initLiveterminal() {
    setDataListener($('#liveterminal'));
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
    // start stream
    var livestream = $('#livestream');
    var events = new EventSource(livestream.data('url'));
    events.addEventListener('message', function(event) {
        loadCanvas(livestream, event.data);
        last_event = event;
    }, false);
}

/********* LIVE STREAM END *********/

function setupRunning(jobid, status_url, details_url) {
  initLivelog();
  initLiveterminal();
  initLivestream();
  initStatus(jobid, status_url, details_url);
  
  $('#interactive_enabled_button').click(enableInteractive);
  $('#interactive_disabled_button').click(disableInteractive);
  
  $('#continue_button').click(function(e) {
    e.preventDefault();
    sendCommand('continue_waitforneedle');
  });
  $('#retry_button').click(function(e) {
    e.preventDefault();
    sendCommand('reload_needles_and_retry');
  });
  $('#stop_button').click(function(e) {
    e.preventDefault();
    sendCommand('stop_waitforneedle');
  });
  
  $('#scrolldown').change(setScrolldown);
}

// vim: set sw=4 et:
