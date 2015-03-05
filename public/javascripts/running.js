
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
    window.testStatus.workerid = newStatus.workerid;
    if (window.testStatus.interactive != newStatus.interactive
        || window.testStatus.interactive_requested != newStatus.interactive_requested) {
        window.testStatus.interactive = newStatus.interactive;
        window.testStatus.interactive_requested = newStatus.interactive_requested;
        window.updateInteractiveIndicator();
    }
    if (window.testStatus.needinput != newStatus.needinput
        || window.testStatus.stop_waitforneedle_requested != newStatus.stop_waitforneedle_requested) {
        window.testStatus.needinput = newStatus.needinput;
        window.testStatus.stop_waitforneedle_requested = newStatus.stop_waitforneedle_requested;
        window.updateNeedinputIndicator();
    }
    if (newStatus.state != 'running' && newStatus.state != 'waiting') {
          setTimeout(function() {location.reload();}, 2000);
          return;
    }
    // If a new module have been started, redraw module list
    if (window.testStatus.modlist_initialized == 0 || window.testStatus.running != newStatus.running) {
        window.testStatus.running = newStatus.running;
        new Ajax.Request("/tests/" + window.testStatus.testname + "/modlist", {
            method: "get",
            dataType: 'json',
            onSuccess: function(resp) {
                var modlist = resp.responseJSON;
                if (modlist.length > 0) {
                    window.prototype_updateModuleslist(modlist, window.testStatus.testname, window.testStatus.running);
                    window.testStatus.modlist_initialized = 1;
                }
            }
        });
    }
}

// Helper functions to show/hide elements

function hide(id) {
    if ($(id)) {
        $(id).hide();
    }
    return true;
}

function show(id) {
    if ($(id)) {
        $(id).show();
    }
    return true;
}

function updateInteractiveIndicator() {
    var indicator = $("interactive_indicator");
    console.log("i r "+window.testStatus.interactive+" "+window.testStatus.interactive_requested);
    if (window.testStatus.interactive == null) {
        indicator.innerHTML = "Unknown";
        window.hide("interactive_spinner");
        window.hide("interactive0_button");
        window.hide("interactive1_button");
    }
    else if (window.testStatus.interactive == 1) {
        indicator.innerHTML = "Yes";
        if (window.testStatus.interactive_requested == 0) {
            window.show("interactive_spinner");
            window.hide("interactive0_button");
            window.hide("interactive1_button");
        }
        else {
            window.hide("interactive_spinner");
            window.hide("interactive0_button");
            window.show("interactive1_button");
            if (!window.testStatus.needinput && !window.testStatus.stop_waitforneedle_requested) {
 //               window.show("stop_button");
            }
        }
    }
    else {
        indicator.innerHTML = "No";
        if (window.testStatus.interactive_requested == 1) {
            window.show("interactive_spinner");
            window.hide("interactive0_button");
            window.hide("interactive1_button");
        }
        else {
            window.hide("interactive_spinner");
            window.show("interactive0_button");
            window.hide("interactive1_button");
//            window.hide("stop_button");
        }
    }
    indicator.highlight();
    updateNeedinputIndicator();
}

function updateNeedinputIndicator() {
    console.log("n r "+window.testStatus.needinput+" "+window.testStatus.stop_waitforneedle_requested);
    var indicator = $("needinput_indicator");
    if (window.testStatus.interactive != 1 || window.testStatus.needinput == null) {
        indicator.innerHTML = "N/A";
        window.hide("crop_button");
        window.hide("continue_button");
        window.hide("retry_button");
        window.hide("stop_button");
        if (window.testStatus.needinput == null) {
            window.show("stop_waitforneedle_spinner");
        }
        else {
            window.hide("stop_waitforneedle_spinner");
        }
    }
    else if (window.testStatus.needinput == 1) {
        indicator.innerHTML = "Yes";
        if (window.testStatus.stop_waitforneedle_requested == 0) {
            window.show("stop_waitforneedle_spinner");
            window.hide("crop_button");
            window.hide("continue_button");
            window.hide("retry_button");
            window.hide("stop_button");
        }
        else {
            window.hide("stop_waitforneedle_spinner");
            window.show("crop_button");
            window.show("continue_button");
            window.show("retry_button");
            window.hide("stop_button");
        }
    }
    else {
        indicator.innerHTML = "No";
        if (window.testStatus.stop_waitforneedle_requested == 1) {
            window.show("stop_waitforneedle_spinner");
            window.hide("crop_button");
            window.hide("continue_button");
            window.hide("retry_button");
            window.hide("stop_button");
        }
        else {
            window.hide("stop_waitforneedle_spinner");
            window.hide("crop_button");
            window.hide("continue_button");
            window.hide("retry_button");
            if (window.testStatus.interactive && window.testStatus.interactive == window.testStatus.interactive_requested) {
                window.show("stop_button");
            }
            else {
                window.hide("stop_button");
            }
        }
    }
    indicator.highlight();
}

function enableInteractive() {
    sendCommand("enable_interactive_mode");
}

function disableInteractive() {
    window.hide("stop_button");
    sendCommand("disable_interactive_mode");
}

function sendCommand(command) {
    var wid = window.testStatus.workerid;
    if (wid == null) return false;
    new Ajax.Request("/api/v1/workers/" + wid + "/commands", {
        method: "post",
        parameters: { command: command },
        onSuccess: function(resp) {
            window.setTimeout("updateStatus()", 0);
        }});
}

function updateStatus() {
    new Ajax.Request("/tests/" + window.testStatus.testname + "/status", {
        method: "get",
        dataType: 'json',
        onSuccess: function(resp) {
            var status = resp.responseJSON;
            window.updateTestStatus(status);
            window.setTimeout("updateStatus()", 3000);
        },
        on404: function(resp) { // no status? probably not running anymore
          window.setTimeout(function() {location.reload();}, 1000);
        }
    });
}

function init_status(tname) {
    window.testStatus.testname = tname;
    updateStatus();
}

/********* LIVE LOG *********/

// global vars for livelog
var livelog, scrolldown;

// checkbox callback
function set_scrolldown(newval) {
    window.scrolldown = newval;
    if (window.scrolldown) {
        window.livelog.scrollTop = window.livelog.scrollHeight;
    }
}

function init_livelog(url) {
    window.scrolldown = true;
    window.livelog = document.getElementById('livelog');
    document.getElementById('scrolldown').checked = true;

    // start stream
    var events = new EventSource(url);
    events.addEventListener('message', function(event) {
        window.livelog.innerHTML += JSON.parse(event.data)[0];
        if (window.scrolldown) {
            window.livelog.scrollTop = window.livelog.scrollHeight;
        }
    }, false);
}

/********* LIVE LOG END *********/


/********* LIVE STREAM *********/

// global vars for livestream
var livestream, last_event, image_size_x, image_size_y;

// loads a data-url img into a canvas
function load_canvas(canvas, dataURL) {
    var context = canvas.getContext('2d');

    // load image from data url
    var scrn = new Image();
    scrn.onload = function() {
        context.clearRect(0, 0, canvas.width, canvas.height);
        context.drawImage(this, 0, 0, width=canvas.width, height=canvas.height);
        window.image_size_x.innerHTML = scrn.width;
        window.image_size_y.innerHTML = scrn.height;
    };
    scrn.src = dataURL;
}

// canvas size
function resize_livestream(arg) {
    window.livestream.width  = arg.split("x")[0];
    window.livestream.height = arg.split("x")[1];
    if (last_event) {
        load_canvas(window.livestream, window.last_event.data);
    }
}

// select callback
function set_resolution(arg) {
    if (arg == "auto") {
        set_cookie("livestream_size", arg, -5);
        if (document.getElementById('canholder').clientWidth >= 1024) {
            resize_livestream("1024x768");
        }
        else {
            resize_livestream("800x600");
        }
    }
    else {
        set_cookie("livestream_size", arg, 365);
        resize_livestream(arg);
    }
}

function init_livestream(url) {
    window.livestream = document.getElementById('livestream');
    window.image_size_x = document.getElementById('image_size_x');
    window.image_size_y = document.getElementById('image_size_y');
    var sel_resolution = document.getElementById('sel_resolution');

    // initially set canvas size
    var livestream_size = get_cookie("window.livestream_size");
    if (! livestream_size) {
        livestream_size = "auto";
    }
    set_resolution(livestream_size);
    sel_resolution.value = livestream_size;

    // start stream
    var events = new EventSource(url);
    events.addEventListener('message', function(event) {
        load_canvas(window.livestream, event.data);
        last_event = event;
    }, false);
}

/********* LIVE STREAM END *********/


// vim: set sw=4 et:
