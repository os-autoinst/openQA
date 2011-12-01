var scrolldownc = 1;
var livelog = 0;
var testname = "";

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

function updatemodule() {
	new Ajax.Request("/livelog/" + window.testname + "?log=modlist", {
		method: "get",
		onSuccess: function(response) {
			// Set Module
			document.getElementById("modcontent").innerHTML = response.responseText;
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
