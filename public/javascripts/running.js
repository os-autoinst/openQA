
var testStatus = {
    modlist_initialized: 0,
    testname: null,
    running: null,
    workerid: null,
    interactive: null,
    needinput: null,
    interactive_requested: null,
    stop_waitforneedle_requested: null,
};

// Update global variable testStatus
function updateTestStatus(newStatus) {
    testStatus.workerid = newStatus.workerid;
    if (testStatus.interactive != newStatus.interactive
        || testStatus.interactive_requested != newStatus.interactive_requested) {
        testStatus.interactive = newStatus.interactive;
        testStatus.interactive_requested = newStatus.interactive_requested;
        updateInteractiveIndicator();
    }
    if (testStatus.needinput != newStatus.needinput
        || testStatus.stop_waitforneedle_requested != newStatus.stop_waitforneedle_requested) {
        testStatus.needinput = newStatus.needinput;
        testStatus.stop_waitforneedle_requested = newStatus.stop_waitforneedle_requested;
        updateNeedinputIndicator();
    }
    if (newStatus.state != 'running' && newStatus.state != 'waiting') {
          setTimeout(function() {location.reload();}, 2000);
          return;
    }
    // If a new module have been started, redraw module list
    if (testStatus.modlist_initialized == 0 || testStatus.running != newStatus.running) {
        testStatus.running = newStatus.running;
        $.ajax("/tests/" + testStatus.testname + "/modlist").
            done(function(modlist) {
                if (modlist.length > 0) {
                    updateModuleslist(modlist, testStatus.testname, testStatus.running);
                    testStatus.modlist_initialized = 1;
                }
            });
    }
}

function updateInteractiveIndicator() {
    var indicator = $("interactive_indicator");
    //console.log("i r "+testStatus.interactive+" "+testStatus.interactive_requested);
    if (testStatus.interactive == null) {
        indicator.html("Unknown");
        $("#interactive_spinner").hide();
        $("#interactive0_button").hide();
        $("#interactive1_button").hide();
    }
    else if (testStatus.interactive == 1) {
        indicator.text("Yes");
        if (testStatus.interactive_requested == 0) {
            $("#interactive_spinner").show();
            $("#interactive0_button").hide();
            $("#interactive1_button").hide();
        }
        else {
            $("#interactive_spinner").hide();
            $("#interactive0_button").hide();
            $("#interactive1_button").show();
            if (!testStatus.needinput && !testStatus.stop_waitforneedle_requested) {
                //  $("#stop_button").show();
            }
        }
    }
    else {
        indicator.text("No");
        if (testStatus.interactive_requested == 1) {
            $("#interactive_spinner").show();
            $("#interactive0_button").hide();
            $("#interactive1_button").hide();
        }
        else {
            $("#interactive_spinner").hide();
            $("#interactive0_button").show();
            $("#interactive1_button").hide();
            // $("#stop_button").hide();
        }
    }
    //indicator.highlight();
    updateNeedinputIndicator();
}

function updateNeedinputIndicator() {
    console.log("n r "+testStatus.needinput+" "+testStatus.stop_waitforneedle_requested);
    var indicator = $("needinput_indicator");
    if (testStatus.interactive != 1 || testStatus.needinput == null) {
        indicator.text("N/A");
        $("#crop_button").hide();
        $("#continue_button").hide();
        $("#retry_button").hide();
        $("#stop_button").hide();
        if (testStatus.needinput == null) {
            $("#stop_waitforneedle_spinner").show();
        }
        else {
            $("#stop_waitforneedle_spinner").hide();
        }
    }
    else if (testStatus.needinput == 1) {
        indicator.text("Yes");
        if (testStatus.stop_waitforneedle_requested == 0) {
            $("#stop_waitforneedle_spinner").show();
            $("#crop_button").hide();
            $("#continue_button").hide();
            $("#retry_button").hide();
            $("#stop_button").hide();
        }
        else {
            $("#stop_waitforneedle_spinner").hide();
            $("#crop_button").show();
            $("#continue_button").show();
            $("#retry_button").show();
            $("#stop_button").hide();
        }
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
            if (testStatus.interactive && testStatus.interactive == testStatus.interactive_requested) {
                $("#stop_button").show();
            }
            else {
                $("#stop_button").hide();
            }
        }
    }
    //indicator.highlight();
}

function enableInteractive() {
    sendCommand("enable_interactive_mode");
}

function disableInteractive() {
    $("#stop_button").hide();
    sendCommand("disable_interactive_mode");
}

function sendCommand(command) {
    var wid = testStatus.workerid;
    if (wid == null) return false;
    var url = $('#actions_box').data('url').replace('WORKERID', wid);
    $.ajax({url: url,
            type: 'POST',
            data: { command: command },
            success: function(resp) {
                setTimeout("updateStatus()", 0);
            }});
}

function updateStatus() {
    $.ajax("/tests/" + testStatus.testname + "/status").
        done(function(status) {
            updateTestStatus(status);
            setTimeout("updateStatus()", 3000);
        }).fail(function() {
            setTimeout(function() {location.reload();}, 1000);
        });
}

function initStatus(tname) {
    testStatus.testname = tname;
    updateStatus();
}

/********* LIVE LOG *********/

// global vars for livelog
var scrolldown;

// checkbox callback
function setScrolldown(newval) {
    scrolldown = newval;
    if (scrolldown) {
        var livelog = $('#livelog')[0];
        $('#livelog').scrollTop = livelog.scrollHeight;
    }
}

function initLivelog() {
    scrolldown = true;
    $('#scrolldown').attr('checked', true);
    
    // start stream
    var livelog = $('#livelog');
    var events = new EventSource(livelog.data('url'));
    events.addEventListener('message', function(event) {
        livelog[0].innerHTML += JSON.parse(event.data)[0];
        if (scrolldown) {
            livelog[0].scrollTop = livelog[0].scrollHeight;
        }
    }, false);
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
        context.drawImage(this, 0, 0, width=canvas.width(), height=canvas.height());
        $('#image_size_x').text(canvas.width());
        $('#image_size_y').text(canvas.height());
    };
    scrn.src = dataURL;
}

// canvas size
function resizeLivestream(arg) {
    var livestream = $('#livestream');
    livestream.attr('width', arg.split("x")[0]);
    livestream.attr('height', arg.split("x")[1]);
    if (last_event) {
        loadCanvas(livestream, last_event.data);
    }
}

// select callback
function setResolution(arg) {
    if (arg == "auto") {
        setCookie("livestream_size", arg, -5);
        if ($('#canholder').innerWidth() >= 1024) {
            resizeLivestream("1024x768");
        }
        else {
            resizeLivestream("800x600");
        }
    }
    else {
        setCookie("livestream_size", arg, 365);
        resizeLivestream(arg);
    }
}

function initLivestream() {
    var sel_resolution = $('#sel_resolution');
    
    // initially set canvas size
    var livestream_size = getCookie("livestream_size");
    if (! livestream_size) {
        livestream_size = "auto";
    }
    setResolution(livestream_size);
    sel_resolution.value = livestream_size;
    
    // start stream
    var livestream = $('#livestream');
    var events = new EventSource(livestream.data('url'));
    events.addEventListener('message', function(event) {
        loadCanvas(livestream, event.data);
        last_event = event;
    }, false);
}

/********* LIVE STREAM END *********/

function setupRunning() {
    initLivelog();
    initLivestream();
    
    $('#interactive0_button').click(enableInteractive);
    $('#interactive1_button').click(disableInteractive);

    $('#continue_button').click(function() {
        sendCommand('continue_waitforneedle');
    });
    $('#retry_button').click(function() {
        sendCommand('reload_needles_and_retry');
    });
    $('#stop_button').click(function() {
        sendCommand('stop_waitforneedle');
    });

    $('#sel_resolution').change(function() {
        setResolution($(this).val());
    });
    $('#scrolldown').change(function() {
        setScrolldown($(this).attr('checked') ? true : false);
    });
}

// vim: set sw=4 et:
