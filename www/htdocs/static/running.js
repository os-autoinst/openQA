var scrolldownc = 1;
var livelog = 0;
var testStatus = {
		testname: null,
		jsonrpc: null,
		running: null,
		interactive: null,
		needinput: null };

// Update global variable testStatus
function updateTestStatus(newStatus) {
	if (window.testStatus.jsonrpc == null) {
		// Always is the same host at the moment
		window.testStatus.jsonrpc = "http://" + window.location.hostname + ":" + newStatus.jsonrpc + "/jsonrpc/API"
	}
	if (window.testStatus.interactive == null) {
		window.testStatus.interactive = newStatus.interactive;
	}
	window.testStatus.running = newStatus.running;
	window.testStatus.needinput = newStatus.needinput;
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
		$("continue_button").hide();
		$("crop_button").hide();
		$("stop_waitforneedle_button").hide();
	} else if (window.testStatus.needinput == 1) {
		indicator.innerHTML = "Yes";
		$("continue_button").show();
		$("crop_button").show();
		$("stop_waitforneedle_button").hide();
	} else {
		indicator.innerHTML = "No";
		$("continue_button").hide();
		$("crop_button").hide();
		$("stop_waitforneedle_button").show();
	}
	indicator.highlight();
}

function toggleInteractive() {
	var status = $("interactive_indicator").dataset.nextStatus;
	if (status == "") {
		return;
	}
	new Ajax.Request("/rpc", {
		method: "post",
		parameters: { 	url: window.testStatus.jsonrpc,
				method: "set_interactive",
				params: [status].toJSON() },
		onSuccess: function(response) {
			window.testStatus.interactive = status;
			updateInteractiveIndicator();
			updateNeedinputIndicator();
		}
	});
}

function continue() {
	new Ajax.Request("/rpc", {
		method: "post",
		parameters: { 	url: window.testStatus.jsonrpc,
				method: "continue" }
	});
}

function stopWaitforneedle() {
	new Ajax.Request("/rpc", {
		method: "post",
		parameters: { 	url: window.testStatus.jsonrpc,
				method: "stop_waitforneedle" }
	});
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
		onSuccess: function(response) {
			// Copy old values for later comparison
			var oldStatus = [];
			for (var key in window.testStatus) {
				oldStatus[key] = window.testStatus[key];
			}
			// Update global variable testStatus
			window.updateTestStatus(response.responseJSON);
			// If a new module have been started, redraw module list
			if (window.testStatus.running != oldStatus.running) {
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
			// If interactive mode have changed
			if (window.testStatus.interactive != oldStatus.interactive) {
				window.updateInteractiveIndicator();
			}
			// If interactive mode or needinput have changed
			if (window.testStatus.interactive != oldStatus.interactive ||
					window.testStatus.needinput != oldStatus.needinput) {
				window.updateNeedinputIndicator();
			}
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
