var scrolldownc = 1;
var livelog = 0;
var testStatus = {
		initialized: 0,
		testname: null,
		running: null,
		workerid: null,
		interactive: null,
		needinput: null };

// Update global variable testStatus
function updateTestStatus(newStatus) {
	window.testStatus.workerid = newStatus.workerid;
	if (window.testStatus.interactive == null) {
		window.testStatus.interactive = newStatus.interactive;
		window.updateInteractiveIndicator();
	}
	if (window.testStatus.needinput != newStatus.needinput) {
		window.testStatus.needinput = newStatus.needinput;
		window.updateNeedinputIndicator();
	}
	// If a new module have been started, redraw module list
	if (window.testStatus.initialized == 0 || window.testStatus.running != newStatus.running) {
		window.testStatus.initialized = 1;
		window.testStatus.running = newStatus.running;
		new Ajax.Request("/tests/" + window.testStatus.testname + "/modlist", {
			method: "get",
			dataType: 'json',
			onSuccess: function(resp) {
				var modlist = resp.responseJSON;
				if (modlist.length > 0) {
					window.updateModuleslist(modlist, window.testStatus.testname, window.testStatus.running);
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
	if (window.testStatus.interactive == null) {
		indicator.innerHTML = "Unknown";
		indicator.dataset.nextStatus = "";
		window.hide("interactive_button");
	} else if (window.testStatus.interactive == 1) {
		indicator.innerHTML = "Yes";
		indicator.dataset.nextStatus = 0;
		window.show("interactive_button");
		if (!window.testStatus.needinput) {
			window.show("stop_button");
		}
	} else {
		indicator.innerHTML = "No";
		indicator.dataset.nextStatus = 1;
		window.show("interactive_button");
	}
	indicator.highlight();
}

function updateNeedinputIndicator() {
	var indicator = $("needinput_indicator");
	if (window.testStatus.interactive != 1 || window.testStatus.needinput == null) {
		indicator.innerHTML = "N/A";
		window.hide("crop_button");
		window.hide("continue_button");
		window.hide("retry_button");
	} else if (window.testStatus.needinput == 1) {
		indicator.innerHTML = "Yes";
		window.show("crop_button");
		window.show("continue_button");
		window.show("retry_button");
		window.hide("stop_button");
	} else {
		indicator.innerHTML = "No";
		window.hide("crop_button");
		window.hide("continue_button");
		window.hide("retry_button");
		if (window.testStatus.interactive) {
			window.show("stop_button");
		}
	}
	indicator.highlight();
}

function toggleInteractive() {
	var status = $("interactive_indicator").dataset.nextStatus;
	if (status == "") {
		return;
	}
	window.testStatus.interactive = status;
	window.updateInteractiveIndicator();
	window.updateNeedinputIndicator();
	if (status == 1) {
		sendCommand("enable_interactive_mode");
	} else {
		sendCommand("disable_interactive_mode");
	}
}

function sendCommand(command) {
	var wid = window.testStatus.workerid;
	if (wid == null) return false;
	new Ajax.Request("/api/v1/workers/" + wid + "/commands", {
		method: "post",
		parameters: { command: command }});
}

function scrolldown() {
	if(window.scrolldownc) {
		document.getElementById("livelog").contentWindow.scrollTo(0, 999999);
	}
	window.setTimeout("scrolldown()", 50);
}

function start_livelog() {
	if(!window.livelog) {
		window.livelog = 1;
		document.getElementById("livelog").src="/tests/" + window.testStatus.testname + "/livelog.txt";
		scrolldown();
	}
}

function updateStatus() {
	new Ajax.Request("/tests/" + window.testStatus.testname + "/status", {
		method: "get",
		dataType: 'json',
		onSuccess: function(resp) {
			var status = resp.responseJSON;
			window.updateTestStatus(status);
			window.setTimeout("updateStatus()", 3000);
		}
	});
}

function init_running(tname) {
	window.testStatus.testname = tname;
	if (window.opera) {
		start_livelog();
	}
	else {
		window.onload=start_livelog;
		window.setTimeout("start_livelog()", 3000);
	}
	updateStatus();
}
