var scrolldownc = 1;
var livelog = 0;
var testname = "";
var running_state = 1;

function scrolldown() {
	if(window.scrolldownc) {
		document.getElementById("livelog").contentWindow.scrollTo(0, 99999999);
	}
	window.setTimeout("scrolldown()", 50);
}

function start_livelog() {
	if(!window.livelog) {
		window.livelog = 1;
		document.getElementById("livelog").src="/livelog/" + window.testname + "?text=1";
		scrolldown();
	}
}

function set_stopcont_button(running) {
	running = running?1:0;
	if(running == window.running_state) {
		return;
	}
	else {
		window.running_state = running;
		if(running) {
			// Display the button to trigger stop
			document.getElementById("stopcont").classList.remove('play');
			document.getElementById("stopcont").classList.add('pause');
			document.getElementById("stopcont").title = "pause testrun";
		}
		else {
			// Display the button to trigger cont
			document.getElementById("stopcont").classList.remove('pause');
			document.getElementById("stopcont").classList.add('play');
			document.getElementById("stopcont").title = "continue testrun";
		}
	}
}

function stopcont() {
	var action = running_state?'stop':'cont';
	new Ajax.Request("/stopcont?testname=" + window.testname + "&action=" + action, {
		method: "get",
		onSuccess: function(response) {
			newstate = response.responseText;
			if(newstate == "0" || newstate == "1") {
				newstate = (newstate == "0")?0:1;
				// Set Button
				set_stopcont_button(newstate);
			}
		}
	});
}


function updatemodule() {
	new Ajax.Request("/livelog/" + window.testname + "?log=modlist", {
		method: "get",
	    	dataType: 'json',
		onSuccess: function(response) {
			var json = response.responseJSON;
			// Set Module
			document.getElementById("modcontent").innerHTML = json.modlist;
			set_stopcont_button(json.running_state);
			window.setTimeout("updatemodule()", 1000);
		}
	});
}

function init_running(tname) {
	window.testname = tname;
	if (window.opera) {
		start_livelog();
	}
	else {
		window.onload=start_livelog;
		window.setTimeout("start_livelog()", 3000);
	}
	updatemodule();
}
