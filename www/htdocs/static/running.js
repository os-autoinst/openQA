var scrolldownc = 1;
var livelog = 0;
var testStatus = {
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
	if (window.testStatus.running != newStatus.running) {
		window.testStatus.running = newStatus.running;
		new Ajax.Request("/livelog/" + window.testStatus.testname + "?log=modlist", {
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

function updateInteractiveIndicator() {
	var indicator = $("interactive_indicator");
	if (window.testStatus.interactive == null) {
		indicator.innerHTML = "Unknown";
		indicator.dataset.nextStatus = "";
		$("interactive_button").hide();
	} else if (window.testStatus.interactive == 1) {
		indicator.innerHTML = "Yes";
		indicator.dataset.nextStatus = 0;
		$("interactive_button").show();
		if (!window.testStatus.needinput) {
			$("stop_button").show();
		}
	} else {
		indicator.innerHTML = "No";
		indicator.dataset.nextStatus = 1;
		$("interactive_button").show();
	}
	indicator.highlight();
}

function updateNeedinputIndicator() {
	var indicator = $("needinput_indicator");
	if (window.testStatus.interactive != 1 || window.testStatus.needinput == null) {
		indicator.innerHTML = "N/A";
		$("crop_button").hide();
		$("continue_button").hide();
		$("retry_button").hide();
	} else if (window.testStatus.needinput == 1) {
		indicator.innerHTML = "Yes";
		$("crop_button").show();
		$("continue_button").show();
		$("retry_button").show();
		$("stop_button").hide();
	} else {
		indicator.innerHTML = "No";
		$("crop_button").hide();
		$("continue_button").hide();
		$("retry_button").hide();
		if (window.testStatus.interactive) {
			$("stop_button").show();
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
	if (window.testStatus.workerid == null) return false;
	new Ajax.Request("/rpc", {
		method: "post",
		parameters: { 	url: "http://" + window.location.hostname + "/jsonrpc",
				method: "command_enqueue",
				params: [window.testStatus.workerid, command].toJSON() }});
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
		document.getElementById("livelog").src="/livelog/" + window.testStatus.testname + "?text=1";
		scrolldown();
	}
}

function updateStatus() {
	new Ajax.Request("/livelog/" + window.testStatus.testname + "?log=status", {
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
