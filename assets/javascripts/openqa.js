function updateModuleslist(modlist, jobid, testmodule) {
    var container = $('<div id="modlist_content"/>');

    $.each(modlist, function(index, category) {
	var title = $('<h2 class="box-subheader modcategory">' + category.category + "</h2>");
	container.append(title);

	var ul = $('<ul class="navigation modcategory"></ul>');
	$.each(category.modules, function(index, module) {
	    var li = $('<li/>');
	    li.addClass("mod-"+module.state);
	    li.addClass("result"+module.result);
	    if (testmodule == module.name) { li.addClass("selected"); }
	    var link = $('<a>' + module.name + '</a>');
	    li.html(link);
	    link.attr('href', "/tests/"+jobid+"/modules/"+module.name+"/steps/1");
	    ul.append(li);
	});
	
	container.append(ul);
    });
    $("#modlist_content").replaceWith(container);
}

function scrollModuleThumbnails() {
    var area = $("#module-thumbnails");
    var current = $('#module-thumbnails .current');

    if (!current || !area.offset())
	return;
    var offset = current.offset().left - area.offset().left;
    area.scrollLeft(40 + offset - area.width()/2);
}

function setCookie(cname, cvalue, exdays) {
    var d = new Date();
    d.setTime(d.getTime()+(exdays*24*60*60*1000));
    var expires = "expires="+d.toGMTString();
    document.cookie = cname + "=" + cvalue + "; " + expires;
}

function getCookie(cname) {
    var name = cname + "=";
    var ca = document.cookie.split(';');
    for(var i=0; i<ca.length; i++) {
        var c = ca[i].trim();
        if (c.indexOf(name)==0) return c.substring(name.length,c.length);
    }
    return false;
}

function setupForAll() {
    $('[data-toggle="tooltip"]').tooltip({html: true});

    $.ajaxSetup({
        headers:
        { 'X-CSRF-TOKEN': $('meta[name="csrf-token"]').attr('content') }
    });
}

function addFlash(status, text) {
    // keep design in line with the static in layouts/info
    var flash = $('#flash-messages');
    var div = $('<div class="alert fade in"><button class="close" data-dismiss="alert">x</button></div>');
    div.append($("<span>" + text + "</span>"));
    div.addClass('alert-' + status);
    flash.append(div);
}
