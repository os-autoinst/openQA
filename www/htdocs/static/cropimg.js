function loadBackground(tag) {
	window.nEditor.LoadBackground(tag.dataset.url);
	document.getElementById("needleeditor_image").setAttribute("value", tag.dataset.path);
}

function loadTags(html) {
	var tags = JSON.parse(html.dataset.tags);
	var checkboxes = document.getElementById("needleeditor_tags").getElementsByTagName('input');
	for (var i = 0; i < checkboxes.length; i++) {
		// If we need to switch
		if ( (checkboxes[i].checked && tags.indexOf(checkboxes[i].value) == -1) ||
		     (!checkboxes[i].checked && tags.indexOf(checkboxes[i].value) != -1)) {
			checkboxes[i].click();
		}
	}
}

function addTag() {
	var input = document.getElementById('newtag');
	var checkbox = window.nEditor.AddTag(input.value, false);
	input.value = '';
	checkbox.click();
	return false;
}

function save_needle() {
	var url = "http://" + window.location.hostname + ":" + window.jsonrpcport + "/jsonrpc/API";
	var needle = JSON.parse(document.getElementById('needleeditor_textarea').value);
	var name = document.getElementById('needleeditor_name').value;
	new Ajax.Request("/rpc", {
		method: "post",
	    	parameters: { 	url: url,
				method: "save_needle",
	    			params: JSON.stringify([name, needle]) },
	    	onSuccess: function(response) {
			window.location = "/running/"+window.testname;
		}
	});
}
